import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import Darwin
import LeBlabCore

/// Black-box dictation benchmark (`--bench <config.json>`), protocol v3 "quick" profile.
///
/// Per trial: clear a throwaway TextEdit document, hold the tool's shortcut, play an identical
/// speech clip through the speakers (acoustic loopback into the built-in mic), release, then watch
/// the document via Accessibility until the text has been stable for `stabilityMs` (+ a late-change
/// watch). The same measurement applies to every tool; nothing inside a tool is instrumented.
///
/// Safety: runs as a separate Le Blab process with no hotkeys; every synthetic event is tagged; a
/// listen-only tap detects real user input; every synthetic press is gated on TextEdit + the bench
/// document being focused, no held modifiers, no secure input and a quiet user; key-ups are never
/// skipped and all modifiers are force-released on every exit path.
struct BenchConfig: Decodable {
    struct Tool: Decodable {
        let name: String
        /// "ctrl-shift" | "fn" (synthetic hold) | "human-fn" (you hold Fn; times come from the tap)
        let trigger: String
        /// Le Blab variants: "raw" | "smart" (via a main instance launched with --bench-control).
        let leblabFormatting: String?
        /// Older Le Blab builds don't ACK the switch; then the harness just waits 1 s.
        let requireAck: Bool?
    }
    struct Phrase: Decodable {
        let id: String
        let lang: String
        /// Spoken words, verbatim.
        let text: String
        /// Cleaned-up target (self-corrections applied).
        let intended: String?
        /// Other accepted renderings.
        let variants: [String]?
        let audio: String
        /// "latency" (default, counts toward headline WER) | "fix" (self-correction) | "vocab"
        let kind: String?
        /// For "fix": words that must appear / must not appear when the correction was applied.
        let mustContain: [String]?
        let mustNotContain: [String]?
        /// For "vocab": exact-casing terms to look for.
        let vocab: [String]?
    }

    var tools: [Tool]
    var phrases: [Phrase]
    var repetitions = 3
    var warmupPerTool = 1
    var preRollMs = 600
    var tailMs = 300
    var stabilityMs = 3000
    var lateWatchMs = 1000
    var noTextTimeoutMs = 15000
    var unstableTimeoutMs = 25000
    var cooldownMs = 1500
    var cooldownJitterMs = 1000
    var pollMs = 5
    var userIdleMs = 3000
    var seed: UInt64 = 42
    var document: String
    var output: String
    var probeOnly = false
    var allowBattery = false

    enum CodingKeys: String, CodingKey {
        case tools, phrases, repetitions, warmupPerTool, preRollMs, tailMs, stabilityMs, lateWatchMs, noTextTimeoutMs,
             unstableTimeoutMs, cooldownMs, cooldownJitterMs, pollMs, userIdleMs, seed, document, output, probeOnly, allowBattery
    }

    // Every tuning key is optional in the JSON (synthesized Decodable would reject missing keys).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tools = try c.decode([Tool].self, forKey: .tools)
        phrases = try c.decode([Phrase].self, forKey: .phrases)
        document = try c.decode(String.self, forKey: .document)
        output = try c.decode(String.self, forKey: .output)
        func opt<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try c.decodeIfPresent(T.self, forKey: key) ?? fallback }
        repetitions = try opt(.repetitions, repetitions)
        warmupPerTool = try opt(.warmupPerTool, warmupPerTool)
        preRollMs = try opt(.preRollMs, preRollMs)
        tailMs = try opt(.tailMs, tailMs)
        stabilityMs = try opt(.stabilityMs, stabilityMs)
        lateWatchMs = try opt(.lateWatchMs, lateWatchMs)
        noTextTimeoutMs = try opt(.noTextTimeoutMs, noTextTimeoutMs)
        unstableTimeoutMs = try opt(.unstableTimeoutMs, unstableTimeoutMs)
        cooldownMs = try opt(.cooldownMs, cooldownMs)
        cooldownJitterMs = try opt(.cooldownJitterMs, cooldownJitterMs)
        pollMs = try opt(.pollMs, pollMs)
        userIdleMs = try opt(.userIdleMs, userIdleMs)
        seed = try opt(.seed, seed)
        probeOnly = try opt(.probeOnly, probeOnly)
        allowBattery = try opt(.allowBattery, allowBattery)
    }
}

struct PlanEntry: Codable {
    let index: Int
    let tool: String
    let phrase: String
    let round: Int      // -1 = warm-up
    let block: Int      // (round, phrase) block; tools within a block are paired
}

struct TrialResult: Codable {
    var index: Int
    var tool: String
    var phrase: String
    var kind: String
    var lang: String
    var round: Int
    var block: Int
    var warmup: Bool
    var attempt: Int
    /// Tool outcomes: ok | no-text | unstable | double-insert | wrong-language.
    /// Invalid environment (re-queued once): focus-lost | user-input | config-failed | clear-failed | ax-stall | gate-timeout | audio-missing
    var status: String
    var audioSeconds: Double
    var tPress: Double
    var tSpeechEnd: Double
    var tRelease: Double
    /// M1: release → last change of the final text (signed).
    var releaseToFinal: Double?
    /// M1_350: release → first moment the text was quiet for 350 ms (talkify-comparable).
    var releaseToFinal350: Double?
    /// M2: release → first visible text (signed; negative = text appeared while still holding).
    var releaseToFirstText: Double?
    /// M3: predicted speech end at the mic → final text.
    var speechEndToFinal: Double?
    /// M6: release → the tool's Cmd+V (paste-based tools only).
    var releaseToPaste: Double?
    var changes: Int
    var lateRevision: Bool
    var werErrors: Int?
    var werRefWords: Int?
    var wer: Double?
    var correctionApplied: Bool?
    var vocabHits: Int?
    var vocabTotal: Int?
    /// Le Blab only: harness M1 minus Le Blab's internal (inserted − released).
    var internalReleaseToInsert: Double?
    var thermal: String
    var text: String
}

@MainActor
enum BenchHarness {
    static let formattingNotification = Notification.Name("local.leblab.LeBlab.bench.formatting")
    static let ackNotification = Notification.Name("local.leblab.LeBlab.bench.ack")
    static let timelineNotification = Notification.Name("local.leblab.LeBlab.bench.timeline")
    static let eventTag: Int64 = 0x4C42_4E43   // "LBNC"

    private static var lastAck: String?
    private static var timelines: [(received: Double, releaseToInsert: Double)] = []

    static func run(configPath: String) async -> Int32 {
        guard let data = FileManager.default.contents(atPath: configPath) else { log("BENCH FAIL: can't read \(configPath)"); return 2 }
        let config: BenchConfig
        do { config = try JSONDecoder().decode(BenchConfig.self, from: data) } catch {
            log("BENCH FAIL: bad config: \(error)"); return 2
        }
        guard AXIsProcessTrusted() else { log("BENCH FAIL: Le Blab needs Accessibility"); return 2 }
        let out = URL(fileURLWithPath: config.output)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        KeyInjector.releaseAll()
        defer { KeyInjector.releaseAll() }
        InputMonitor.shared.start()
        observeLeBlab()

        // P0 preflight (read-only).
        let env = Preflight.collect()
        write(json: env, to: out.appendingPathComponent("env.json"))
        if let problem = Preflight.problem(env, allowBattery: config.allowBattery) {
            log("BENCH FAIL: preflight — \(problem)"); return 3
        }

        guard let field = await openDocument(config.document) else { log("BENCH FAIL: TextEdit document not focusable"); return 2 }

        // Audio players are created once and reused (prepared before each trial).
        var players: [String: AVAudioPlayer] = [:]
        for phrase in config.phrases {
            guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: phrase.audio)) else {
                log("BENCH FAIL: audio missing for \(phrase.id)"); return 2
            }
            players[phrase.id] = player
        }

        let plan = makePlan(config)
        write(json: plan, to: out.appendingPathComponent("plan.json"))
        let jsonl = out.appendingPathComponent("trials.jsonl")
        FileManager.default.createFile(atPath: jsonl.path, contents: nil)
        log("BENCH START: \(plan.count) planned trials · tools: \(config.tools.map(\.name).joined(separator: ", ")) · \(env["power"] ?? "")")

        var rng = SplitMix64(seed: config.seed &+ 7)
        var results: [TrialResult] = []
        var invalidStreak = 0
        let byName = Dictionary(uniqueKeysWithValues: config.tools.map { ($0.name, $0) })
        let phraseByID = Dictionary(uniqueKeysWithValues: config.phrases.map { ($0.id, $0) })

        // Run the plan round by round; invalid-environment trials are re-queued once at the end of their round.
        let rounds = Dictionary(grouping: plan, by: \.round).sorted { $0.key < $1.key }
        roundLoop: for (_, entries) in rounds {
            var queue = entries.map { ($0, 1) }
            var i = 0
            while i < queue.count {
                let (entry, attempt) = queue[i]
                i += 1
                guard let tool = byName[entry.tool], let phrase = phraseByID[entry.phrase], let player = players[phrase.id] else { continue }
                let result = await trial(entry: entry, attempt: attempt, tool: tool, phrase: phrase, player: player,
                                         field: field, config: config)
                results.append(result)
                append(result, to: jsonl)
                log(String(format: "[%d/%d] %@ · %@%@ · %@ · M1 %@ · M2 %@ · WER %@", results.count, plan.count, tool.name, phrase.id,
                           entry.round < 0 ? " (warm-up)" : "", result.status, fmt(result.releaseToFinal), fmt(result.releaseToFirstText),
                           result.wer.map { String(format: "%.0f%%", $0 * 100) } ?? "-"))
                if Self.invalidStatuses.contains(result.status) {
                    invalidStreak += 1
                    if attempt == 1 { queue.append((entry, 2)) }
                    if invalidStreak >= 3 { log("BENCH ABORT: 3 invalid trials in a row (last: \(result.status))"); break roundLoop }
                } else {
                    invalidStreak = 0
                }
                let jitter = Int(rng.next() % UInt64(max(1, config.cooldownJitterMs)))
                try? await Task.sleep(nanoseconds: UInt64(config.cooldownMs + jitter) * 1_000_000)
            }
        }
        setLeBlabFormatting("restore")
        InputMonitor.shared.stop()

        let report = Report.make(results: results, config: config, env: env)
        try? report.markdown.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        write(json: report.json, to: out.appendingPathComponent("summary.json"))
        log("BENCH DONE\n" + report.markdown)
        return 0
    }

    static let invalidStatuses: Set<String> = ["focus-lost", "user-input", "config-failed", "clear-failed", "ax-stall", "gate-timeout"]

    // MARK: - Plan

    /// Warm-ups first; then per round a seeded phrase order, and per (round, phrase) block every tool
    /// once. With 3 tools the 6 orderings are cycled in a sequence where no block starts with the
    /// previous block's last tool.
    static func makePlan(_ config: BenchConfig) -> [PlanEntry] {
        var rng = SplitMix64(seed: config.seed)
        var plan: [PlanEntry] = []
        var block = 0
        let names = config.tools.map(\.name)
        for tool in names {
            for w in 0..<config.warmupPerTool {
                plan.append(PlanEntry(index: plan.count, tool: tool, phrase: config.phrases[w % config.phrases.count].id, round: -1, block: -1))
            }
        }
        if config.probeOnly { return plan }
        let orderings: [[Int]] = names.count == 3
            ? [[0, 1, 2], [1, 2, 0], [2, 0, 1], [0, 2, 1], [2, 1, 0], [1, 0, 2]]
            : (0..<names.count).map { r in (0..<names.count).map { (r + $0) % names.count } }
        for round in 0..<config.repetitions {
            for phrase in config.phrases.shuffled(using: &rng) {
                for t in orderings[block % orderings.count] {
                    plan.append(PlanEntry(index: plan.count, tool: names[t], phrase: phrase.id, round: round, block: block))
                }
                block += 1
            }
        }
        return plan
    }

    // MARK: - One trial

    static func trial(entry: PlanEntry, attempt: Int, tool: BenchConfig.Tool, phrase: BenchConfig.Phrase, player: AVAudioPlayer,
                      field: AXUIElement, config: BenchConfig) async -> TrialResult {
        var r = TrialResult(index: entry.index, tool: tool.name, phrase: phrase.id, kind: phrase.kind ?? "latency", lang: phrase.lang,
                            round: entry.round, block: entry.block, warmup: entry.round < 0, attempt: attempt, status: "ok",
                            audioSeconds: player.duration, tPress: 0, tSpeechEnd: 0, tRelease: 0, changes: 0, lateRevision: false,
                            thermal: Preflight.thermal(), text: "")
        defer { KeyInjector.releaseAll() }

        // Configure Le Blab (ACK required), at least 1 s before the press.
        if let formatting = tool.leblabFormatting {
            lastAck = nil
            setLeBlabFormatting(formatting)
            if tool.requireAck ?? true {
                let deadline = now() + 1.5
                while lastAck != formatting && now() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
                guard lastAck == formatting else { r.status = "config-failed"; return r }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Clear without keystrokes, then let the clipboard settle (paste tools restore it ~0.5 s later).
        if let problem = await waitForGate(field: field, config: config) { r.status = problem; return r }
        guard clear(field) else { r.status = "clear-failed"; return r }
        await waitForClipboardSettle()
        try? await Task.sleep(nanoseconds: 250_000_000)

        let watcher = FieldWatcher(element: field, pollInterval: Double(config.pollMs) / 1000)
        if let problem = await waitForGate(field: field, config: config) { r.status = problem; return r }
        watcher.start()
        let human = tool.trigger.hasPrefix("human")
        InputMonitor.shared.beginTrial(allowUserKeys: human)

        // Press.
        if human {
            HumanPrompt.shared.show("Hold Fn now — keep holding until told to release")
            guard let down = await InputMonitor.shared.waitForFn(down: true, timeout: 30) else {
                HumanPrompt.shared.hide(); watcher.stop(); r.status = "gate-timeout"; return r
            }
            r.tPress = down
            HumanPrompt.shared.show("Keep holding Fn…")
        } else {
            r.tPress = now()
            KeyInjector.press(tool.trigger, down: true)
        }

        // Schedule audio on the device clock so speech starts exactly when the pre-roll ends.
        player.currentTime = 0
        player.prepareToPlay()
        let preRoll = Double(config.preRollMs) / 1000
        let scheduledAt = now()
        player.play(atTime: player.deviceCurrentTime + max(0.02, preRoll - (scheduledAt - r.tPress)))
        r.tSpeechEnd = r.tPress + preRoll + player.duration
        let releaseTarget = r.tSpeechEnd + Double(config.tailMs) / 1000

        // Hold, watching for interruptions.
        var interrupted: String?
        while now() < releaseTarget {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if !frontmostIsTextEdit() || !focusIsField(field) { interrupted = "focus-lost"; break }
            if !human, InputMonitor.shared.userInputDuringTrial { interrupted = "user-input"; break }
        }
        if let interrupted {
            player.stop()
            // Make sure a paste-on-release tool lands in the bench document, not the user's app.
            if !frontmostIsTextEdit() { _ = await refocus() }
            releaseNow(human: human, tool: tool, result: &r)
            HumanPrompt.shared.hide()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            watcher.stop()
            r.status = interrupted
            return r
        }

        // Release.
        if human {
            HumanPrompt.shared.show("Release Fn now")
            r.tRelease = await InputMonitor.shared.waitForFn(down: false, timeout: 10) ?? now()
            HumanPrompt.shared.hide()
        } else {
            releaseNow(human: false, tool: tool, result: &r)
        }

        // Wait for stable text, then a late-change watch.
        let stability = Double(config.stabilityMs) / 1000, late = Double(config.lateWatchMs) / 1000
        let noTextDeadline = r.tRelease + Double(config.noTextTimeoutMs) / 1000
        let unstableDeadline = r.tRelease + Double(config.unstableTimeoutMs) / 1000
        var stableSince: Double?
        while true {
            try? await Task.sleep(nanoseconds: 25_000_000)
            let t = now()
            if watcher.stalled { r.status = "ax-stall"; break }
            if !frontmostIsTextEdit() { r.status = "focus-lost"; break }
            let value = watcher.value
            if value.isEmpty {
                if t > noTextDeadline { r.status = "no-text"; break }
                continue
            }
            let quietFrom = max(watcher.lastChange ?? r.tRelease, r.tRelease)
            if t - quietFrom >= stability {
                if stableSince == nil { stableSince = t }
                if t - stableSince! >= late { break }            // stable through the late watch too
            } else if stableSince != nil {
                r.lateRevision = true                              // changed during the late watch
                stableSince = nil
            }
            if t > unstableDeadline { r.status = "unstable"; break }
        }
        watcher.stop()
        let monitor = InputMonitor.shared.endTrial()
        if monitor.userInput && !human && r.status == "ok" { r.status = "user-input" }

        // Metrics.
        let changes = watcher.changes
        r.changes = changes.count
        r.text = watcher.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = changes.first(where: { $0.length > 0 }) { r.releaseToFirstText = first.time - r.tRelease }
        if let last = changes.last, !r.text.isEmpty {
            r.releaseToFinal = last.time - r.tRelease
            r.speechEndToFinal = last.time - r.tSpeechEnd
            r.releaseToFinal350 = settled(changes, quiet: 0.35).map { $0 - r.tRelease }
        }
        if let paste = monitor.pasteTimes.first(where: { $0 >= r.tRelease - 0.05 }) { r.releaseToPaste = paste - r.tRelease }
        if tool.leblabFormatting != nil, let tl = timelines.last(where: { $0.received >= r.tRelease }) {
            r.internalReleaseToInsert = tl.releaseToInsert
        }
        score(&r, phrase: phrase)
        return r
    }

    static func releaseNow(human: Bool, tool: BenchConfig.Tool, result r: inout TrialResult) {
        r.tRelease = now()
        if !human { KeyInjector.press(tool.trigger, down: false) }
    }

    /// First change after which the field stayed unchanged for `quiet` seconds.
    static func settled(_ changes: [FieldWatcher.Change], quiet: Double) -> Double? {
        for (i, c) in changes.enumerated() where c.length > 0 {
            if i + 1 >= changes.count || changes[i + 1].time - c.time >= quiet { return c.time }
        }
        return nil
    }

    static func score(_ r: inout TrialResult, phrase: BenchConfig.Phrase) {
        guard r.status == "ok", !r.text.isEmpty else { return }
        let references = [phrase.text] + [phrase.intended].compactMap { $0 } + (phrase.variants ?? [])
        let longest = references.map(\.count).max() ?? 0
        if r.text.count > Int(Double(longest) * 1.6) + 10 || hasRepeatedSentence(r.text) { r.status = "double-insert" }
        if phrase.lang.hasPrefix("de") && englishShare(r.text) > 0.3 { r.status = "wrong-language" }
        let best = WordErrorRate.best(references: references, hypothesis: r.text, language: phrase.lang)
        r.wer = best.wer
        r.werErrors = best.errors
        r.werRefWords = best.referenceWords
        if phrase.kind == "fix" {
            let words = Set(WordErrorRate.normalize(r.text, language: phrase.lang))
            let has = (phrase.mustContain ?? []).allSatisfy { words.contains(WordErrorRate.normalize($0, language: phrase.lang).first ?? $0) }
            let hasNot = (phrase.mustNotContain ?? []).allSatisfy { !words.contains(WordErrorRate.normalize($0, language: phrase.lang).first ?? $0) }
            r.correctionApplied = has && hasNot
        }
        if let vocab = phrase.vocab {
            r.vocabTotal = vocab.count
            r.vocabHits = vocab.filter { r.text.contains($0) }.count
        }
    }

    static func hasRepeatedSentence(_ text: String) -> Bool {
        let sentences = text.split(whereSeparator: { ".!?".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.split(separator: " ").count >= 4 }
        return Set(sentences).count < sentences.count
    }

    static let englishStopwords: Set<String> = ["the", "and", "is", "to", "of", "we", "you", "that", "it", "in", "for", "on", "with",
                                                "can", "if", "just", "wanted", "ask", "because", "team", "need", "some", "time"]
    static func englishShare(_ text: String) -> Double {
        let tokens = WordErrorRate.normalize(text, language: "de")
        guard !tokens.isEmpty else { return 0 }
        return Double(tokens.filter { englishStopwords.contains($0) }.count) / Double(tokens.count)
    }

    // MARK: - Safety gate

    /// Returns nil when it's safe to touch the bench document; otherwise the invalid status after waiting.
    static func waitForGate(field: AXUIElement, config: BenchConfig) async -> String? {
        let deadline = now() + 30
        var refocused = false
        while now() < deadline {
            if !frontmostIsTextEdit() || !focusIsField(field) {
                if refocused { return "focus-lost" }
                refocused = true
                _ = await refocus()
                continue
            }
            let idle = now() - InputMonitor.shared.lastUserInput
            let modifiers = CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn])
            if idle >= Double(config.userIdleMs) / 1000, modifiers.isEmpty, !IsSecureEventInputEnabled() { return nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return "gate-timeout"
    }

    static func clear(_ field: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString)
        if readValue(field) == "" { return true }
        var range = CFRange(location: 0, length: (readValue(field) ?? "").utf16.count)
        if let axRange = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, axRange)
            AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, "" as CFString)
        }
        return readValue(field) == ""
    }

    static func waitForClipboardSettle() async {
        var last = NSPasteboard.general.changeCount
        var stableSince = now()
        let deadline = now() + 3
        while now() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let c = NSPasteboard.general.changeCount
            if c != last { last = c; stableSince = now() }
            if now() - stableSince >= 0.5 { return }
        }
    }

    static func readValue(_ field: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Environment

    static func openDocument(_ path: String) async -> AXUIElement? {
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: Data()) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else { return nil }
        _ = try? await NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: textEdit, configuration: config)
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let field = focusedTextEditField() { return field }
        }
        return nil
    }

    static func focusedTextEditField() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first,
              frontmostIsTextEdit() else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return (role as? String) == "AXTextArea" ? element : nil
    }

    static func focusIsField(_ field: AXUIElement) -> Bool {
        guard let current = focusedTextEditField() else { return false }
        return CFEqual(current, field)
    }

    static func refocus() async -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?.activate()
        try? await Task.sleep(nanoseconds: 800_000_000)
        return frontmostIsTextEdit()
    }

    static func frontmostIsTextEdit() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit"
    }

    // MARK: - Le Blab bench control

    static func setLeBlabFormatting(_ mode: String) {
        DistributedNotificationCenter.default().postNotificationName(formattingNotification, object: mode, userInfo: nil,
                                                                     deliverImmediately: true)
    }

    static func observeLeBlab() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: ackNotification, object: nil, queue: .main) { note in
            let mode = note.object as? String
            MainActor.assumeIsolated { lastAck = mode }
        }
        center.addObserver(forName: timelineNotification, object: nil, queue: .main) { note in
            guard let s = note.object as? String, let d = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Double],
                  let span = obj["releaseToInsert"], span >= 0 else { return }
            MainActor.assumeIsolated { timelines.append((now(), span)) }
        }
    }

    // MARK: - Output

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    static func append(_ result: TrialResult, to url: URL) {
        guard let data = try? JSONEncoder().encode(result), let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data("\n".utf8))
        try? handle.close()
    }

    static func write<T: Encodable>(json value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(value).write(to: url)
    }

    static func fmt(_ t: Double?) -> String {
        guard let t else { return "—" }
        return String(format: "%.0f ms", t * 1000)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        guard let path = SelfTest.value(after: "--bench-log") else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data((message + "\n").utf8)); try? handle.close()
        } else {
            try? (message + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Field watcher

/// Polls the target field's AX value on a background thread and timestamps every change.
final class FieldWatcher: @unchecked Sendable {
    struct Change { let time: Double; let length: Int }
    private let element: AXUIElement
    private let pollInterval: Double
    private let lock = NSLock()
    private var _changes: [Change] = []
    private var _value = ""
    private var _stalled = false
    private var running = false

    init(element: AXUIElement, pollInterval: Double) {
        self.element = element
        self.pollInterval = pollInterval
        AXUIElementSetMessagingTimeout(element, 0.25)
    }

    var changes: [Change] { lock.withLock { _changes } }
    var value: String { lock.withLock { _value } }
    var lastChange: Double? { lock.withLock { _changes.last?.time } }
    /// An AX read took >100 ms: timings in this trial are unreliable.
    var stalled: Bool { lock.withLock { _stalled } }

    func start() {
        let initial = read() ?? ""
        lock.withLock { _value = initial; running = true }
        let thread = Thread { [weak self] in
            while let self, self.lock.withLock({ self.running }) {
                let before = ProcessInfo.processInfo.systemUptime
                let v = self.read()
                let t = ProcessInfo.processInfo.systemUptime
                self.lock.withLock {
                    if t - before > 0.1 { self._stalled = true }
                    if let v, v != self._value {
                        self._value = v
                        self._changes.append(Change(time: t, length: v.count))
                    }
                }
                Thread.sleep(forTimeInterval: self.pollInterval)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { lock.withLock { running = false } }

    private func read() -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

// MARK: - Synthetic keys

/// Shortcut holds with hardware-like flags, posted at the HID level and tagged so the harness's own
/// input monitor can tell them from the user's keystrokes.
enum KeyInjector {
    private static let source = CGEventSource(stateID: .hidSystemState)
    private static let nonCoalesced: UInt64 = 0x100

    static func press(_ trigger: String, down: Bool) {
        switch trigger {
        case "ctrl-shift":
            if down {
                modifier(UInt16(kVK_Control), down: true, flags: 0x40101)
                modifier(UInt16(kVK_Shift), down: true, flags: 0x60103)
            } else {
                modifier(UInt16(kVK_Shift), down: false, flags: 0x40101)
                modifier(UInt16(kVK_Control), down: false, flags: nonCoalesced)
            }
        case "fn":
            modifier(UInt16(kVK_Function), down: down, flags: down ? 0x800100 : nonCoalesced)
        default:
            break
        }
    }

    /// Never leave a modifier stuck: posted at start, after every trial and on exit.
    static func releaseAll() {
        let held = CGEventSource.flagsState(.hidSystemState)
        if held.contains(.maskShift) { modifier(UInt16(kVK_Shift), down: false, flags: nonCoalesced) }
        if held.contains(.maskControl) { modifier(UInt16(kVK_Control), down: false, flags: nonCoalesced) }
        if held.contains(.maskSecondaryFn) { modifier(UInt16(kVK_Function), down: false, flags: nonCoalesced) }
    }

    private static func modifier(_ keyCode: UInt16, down: Bool, flags: UInt64) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: flags)
        event.setIntegerValueField(.eventSourceUserData, value: BenchHarness.eventTag)
        event.post(tap: .cghidEventTap)
    }
}

// MARK: - Input monitor

/// Listen-only session tap: distinguishes real user input from tool-generated events (by source
/// process), records tools' ⌘V pastes, and times real Fn presses for human-triggered trials.
final class InputMonitor: @unchecked Sendable {
    static let shared = InputMonitor()
    private let lock = NSLock()
    private var port: CFMachPort?
    private var _lastUserInput: Double = 0
    private var _trialUserInput = false
    private var _pasteTimes: [Double] = []
    private var allowUserKeys = false
    private var fnWaiter: (down: Bool, continuation: CheckedContinuation<Double?, Never>)?

    var lastUserInput: Double { lock.withLock { _lastUserInput } }
    var userInputDuringTrial: Bool { lock.withLock { _trialUserInput } }

    func start() {
        guard port == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                                 callback: { _, type, event, info in
                                     if let info { Unmanaged<InputMonitor>.fromOpaque(info).takeUnretainedValue().observe(type, event) }
                                     return Unmanaged.passUnretained(event)
                                 }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let port {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        port = nil
    }

    func beginTrial(allowUserKeys: Bool) {
        lock.withLock { _trialUserInput = false; _pasteTimes = []; self.allowUserKeys = allowUserKeys }
    }

    func endTrial() -> (userInput: Bool, pasteTimes: [Double]) {
        lock.withLock { (_trialUserInput, _pasteTimes) }
    }

    @MainActor
    func waitForFn(down: Bool, timeout: Double) async -> Double? {
        await withCheckedContinuation { c in
            lock.withLock { fnWaiter = (down, c) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.resolveFn(nil) }
        }
    }

    private func resolveFn(_ t: Double?) {
        let waiter: CheckedContinuation<Double?, Never>? = lock.withLock { defer { fnWaiter = nil }; return fnWaiter?.continuation }
        waiter?.resume(returning: t)
    }

    private func observe(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == BenchHarness.eventTag { return }   // ours
        let t = ProcessInfo.processInfo.systemUptime
        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        if Self.isToolProcess(pid) {
            // A dictation tool's own synthetic event — e.g. its ⌘V paste.
            if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_V), event.flags.contains(.maskCommand) {
                lock.withLock { _pasteTimes.append(t) }
            }
            return
        }
        // Real (or unknown-source) input.
        if type == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Function) {
            let isDown = event.flags.contains(.maskSecondaryFn)
            if lock.withLock({ fnWaiter?.down == isDown }) { resolveFn(t); return }
        }
        lock.withLock {
            _lastUserInput = t
            if !(allowUserKeys && type == .flagsChanged) { _trialUserInput = true }
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var toolCache: [pid_t: Bool] = [:]

    /// Wispr Flow (any of its helpers) or Le Blab, judged by executable path.
    static func isToolProcess(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if let cached = cacheLock.withLock({ toolCache[pid] }) { return cached }
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = n > 0 ? String(cString: buffer) : ""
        let isTool = path.contains("/Wispr Flow.app/") || path.contains("/Le Blab.app/")
        cacheLock.withLock { toolCache[pid] = isTool }
        return isTool
    }
}

// MARK: - Preflight (read-only)

enum Preflight {
    static func collect() -> [String: String] {
        var env: [String: String] = [:]
        env["date"] = ISO8601DateFormatter().string(from: Date())
        env["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
        env["thermal"] = thermal()
        env["lowPowerMode"] = String(ProcessInfo.processInfo.isLowPowerModeEnabled)
        env["power"] = shell("/usr/bin/pmset", ["-g", "batt"]).components(separatedBy: "\n").prefix(2).joined(separator: " ")
        env["defaultInput"] = AudioDevices.defaultInputDevice()?.name ?? "?"
        env["wisprVersion"] = Bundle(path: "/Applications/Wispr Flow.app")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "not installed"
        env["leblabVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return env
    }

    static func problem(_ env: [String: String], allowBattery: Bool) -> String? {
        let power = env["power"] ?? ""
        if !allowBattery, !power.contains("AC Power") {
            if let pct = power.range(of: #"(\d+)%"#, options: .regularExpression).map({ Int(power[$0].dropLast()) ?? 0 }), pct < 30 {
                return "on battery at \(pct)%. Plug in AC power (or set allowBattery)."
            }
        }
        if env["lowPowerMode"] == "true" { return "Low Power Mode is on." }
        if env["defaultInput"]?.contains("MacBook") == false { return "default input is \(env["defaultInput"] ?? "?"), expected the built-in mic." }
        return nil
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

// MARK: - Human prompt

/// Small floating instruction panel for human-triggered trials (never takes focus).
@MainActor
final class HumanPrompt {
    static let shared = HumanPrompt()
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(_ text: String) {
        if panel == nil {
            let p = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 56), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            p.level = .statusBar
            p.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.92)
            p.isOpaque = false
            label.font = .systemFont(ofSize: 16, weight: .semibold)
            label.textColor = NSColor(red: 1, green: 0.51, blue: 0.02, alpha: 1)
            label.alignment = .center
            label.frame = NSRect(x: 10, y: 16, width: 400, height: 24)
            p.contentView?.addSubview(label)
            if let screen = NSScreen.main {
                p.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.maxY - 120))
            }
            panel = p
        }
        label.stringValue = text
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

/// Deterministic RNG so a run can be reproduced from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
