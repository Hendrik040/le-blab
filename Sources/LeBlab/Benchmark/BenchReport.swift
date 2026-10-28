import Foundation
import LeBlabCore

/// Statistics for a benchmark run: per-tool latency distributions (failure-aware), pooled WER,
/// self-correction and vocabulary scores, and paired comparisons within blocks (same round and
/// phrase) using the Hodges–Lehmann estimate with a bootstrap 95% CI and a failure-aware win rate.
enum Report {
    struct ToolSummary: Codable {
        let tool: String
        let trials: Int          // measured, valid environment
        let ok: Int
        let invalid: Int         // excluded (environment problems)
        let failureRate: Double
        let m1Median: Double?
        let m1P25: Double?
        let m1P75: Double?
        let m1P90: Double?
        let m1_350Median: Double?
        let m2Median: Double?
        let m3Median: Double?
        let pasteMedian: Double?
        let pooledWER: Double?
        let pooledWER_en: Double?
        let pooledWER_de: Double?
        let correctionRate: Double?
        let vocabHitRate: Double?
        let lateRevisions: Int
        let harnessMinusInternalMedian: Double?
    }

    struct PairSummary: Codable {
        let a: String
        let b: String
        let metric: String
        let pairs: Int
        /// Hodges–Lehmann estimate of (a − b); negative = a faster.
        let hl: Double?
        let ciLow: Double?
        let ciHigh: Double?
        /// Share of blocks where a beat b (a failure loses; both failing = tie, excluded).
        let winRate: Double?
    }

    struct JSON: Codable {
        let env: [String: String]
        let tools: [ToolSummary]
        let pairs: [PairSummary]
    }

    static func make(results: [TrialResult], config: BenchConfig, env: [String: String]) -> (markdown: String, json: JSON) {
        let measured = results.filter { !$0.warmup }
        // For re-queued trials keep only the last attempt per (tool, block).
        var latest: [String: TrialResult] = [:]
        for r in measured { latest["\(r.tool)#\(r.block)"] = r }
        let final = Array(latest.values)
        let toolNames = config.tools.map(\.name)

        let tools = toolNames.map { summarize(tool: $0, all: final) }
        var pairs: [PairSummary] = []
        for i in 0..<toolNames.count {
            for j in (i + 1)..<toolNames.count {
                for metric in ["M1", "M2"] {
                    pairs.append(pair(toolNames[i], toolNames[j], metric: metric, rows: final, seed: config.seed))
                }
            }
        }
        let json = JSON(env: env, tools: tools, pairs: pairs)
        return (markdown(json, config: config), json)
    }

    static let failureStatuses: Set<String> = ["no-text", "unstable", "double-insert", "wrong-language"]

    static func summarize(tool: String, all: [TrialResult]) -> ToolSummary {
        let rows = all.filter { $0.tool == tool }
        let valid = rows.filter { !BenchHarness.invalidStatuses.contains($0.status) }
        let ok = valid.filter { $0.status == "ok" }
        let m1 = ok.compactMap(\.releaseToFinal)
        let latency = ok.filter { $0.kind == "latency" }
        func pooled(_ subset: [TrialResult]) -> Double? {
            let refs = subset.compactMap(\.werRefWords).reduce(0, +)
            guard refs > 0 else { return nil }
            return Double(subset.compactMap(\.werErrors).reduce(0, +)) / Double(refs)
        }
        let fixes = ok.compactMap(\.correctionApplied)
        let vocabTotal = ok.compactMap(\.vocabTotal).reduce(0, +)
        let deltas = ok.compactMap { r -> Double? in
            guard let m1 = r.releaseToFinal, let inner = r.internalReleaseToInsert else { return nil }
            return m1 - inner
        }
        return ToolSummary(
            tool: tool, trials: valid.count, ok: ok.count, invalid: rows.count - valid.count,
            failureRate: valid.isEmpty ? 0 : Double(valid.count - ok.count) / Double(valid.count),
            m1Median: pct(m1, 0.5), m1P25: pct(m1, 0.25), m1P75: pct(m1, 0.75), m1P90: pct(m1, 0.9),
            m1_350Median: pct(ok.compactMap(\.releaseToFinal350), 0.5),
            m2Median: pct(ok.compactMap(\.releaseToFirstText), 0.5),
            m3Median: pct(ok.compactMap(\.speechEndToFinal), 0.5),
            pasteMedian: pct(ok.compactMap(\.releaseToPaste), 0.5),
            pooledWER: pooled(latency), pooledWER_en: pooled(latency.filter { $0.lang.hasPrefix("en") }),
            pooledWER_de: pooled(latency.filter { $0.lang.hasPrefix("de") }),
            correctionRate: fixes.isEmpty ? nil : Double(fixes.filter { $0 }.count) / Double(fixes.count),
            vocabHitRate: vocabTotal == 0 ? nil : Double(ok.compactMap(\.vocabHits).reduce(0, +)) / Double(vocabTotal),
            lateRevisions: ok.filter(\.lateRevision).count,
            harnessMinusInternalMedian: pct(deltas, 0.5))
    }

    static func pair(_ a: String, _ b: String, metric: String, rows: [TrialResult], seed: UInt64) -> PairSummary {
        let value: (TrialResult) -> Double? = { metric == "M1" ? $0.releaseToFinal : $0.releaseToFirstText }
        let byBlock = Dictionary(grouping: rows.filter { $0.tool == a || $0.tool == b }, by: \.block)
        var diffs: [Double] = []
        var wins = 0, decided = 0
        for (_, group) in byBlock {
            guard let ra = group.first(where: { $0.tool == a }), let rb = group.first(where: { $0.tool == b }),
                  !BenchHarness.invalidStatuses.contains(ra.status), !BenchHarness.invalidStatuses.contains(rb.status) else { continue }
            let va = ra.status == "ok" ? value(ra) : nil, vb = rb.status == "ok" ? value(rb) : nil
            switch (va, vb) {
            case let (x?, y?):
                diffs.append(x - y)
                decided += 1
                if x < y { wins += 1 }
            case (_?, nil): decided += 1; wins += 1
            case (nil, _?): decided += 1
            default: break
            }
        }
        let hl = hodgesLehmann(diffs)
        let ci = bootstrapCI(diffs, seed: seed)
        return PairSummary(a: a, b: b, metric: metric, pairs: diffs.count, hl: hl, ciLow: ci?.0, ciHigh: ci?.1,
                           winRate: decided == 0 ? nil : Double(wins) / Double(decided))
    }

    /// Median of all pairwise (Walsh) averages — robust paired-difference estimate.
    static func hodgesLehmann(_ d: [Double]) -> Double? {
        guard !d.isEmpty else { return nil }
        var walsh: [Double] = []
        walsh.reserveCapacity(d.count * (d.count + 1) / 2)
        for i in 0..<d.count { for j in i..<d.count { walsh.append((d[i] + d[j]) / 2) } }
        return pct(walsh, 0.5)
    }

    static func bootstrapCI(_ d: [Double], seed: UInt64, resamples: Int = 4000) -> (Double, Double)? {
        guard d.count >= 5 else { return nil }
        var rng = SplitMix64(seed: seed &+ 99)
        var estimates: [Double] = []
        estimates.reserveCapacity(resamples)
        for _ in 0..<resamples {
            let sample = (0..<d.count).map { _ in d[Int(rng.next() % UInt64(d.count))] }
            if let e = hodgesLehmann(sample) { estimates.append(e) }
        }
        guard let lo = pct(estimates, 0.025), let hi = pct(estimates, 0.975) else { return nil }
        return (lo, hi)
    }

    static func pct(_ v: [Double], _ p: Double) -> Double? { DiagnosticsService.percentile(v, p) }

    static func ms(_ t: Double?) -> String { t.map { String(format: "%.0f", $0 * 1000) } ?? "—" }
    static func percent(_ x: Double?) -> String { x.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }

    static func markdown(_ r: JSON, config: BenchConfig) -> String {
        var s = "## Latency (ms, from key release; signed)\n\n"
        s += "| Tool | ok / valid (invalid) | **M1 final p50** | IQR | p90 | M1₃₅₀ p50 | M2 first text p50 | M3 speech end→final | ⌘V p50 | late revisions |\n"
        s += "|---|---|---|---|---|---|---|---|---|---|\n"
        for t in r.tools {
            s += "| \(t.tool) | \(t.ok) / \(t.trials) (\(t.invalid)) | **\(ms(t.m1Median))** | \(ms(t.m1P25))–\(ms(t.m1P75)) | \(ms(t.m1P90)) | \(ms(t.m1_350Median)) | \(ms(t.m2Median)) | \(ms(t.m3Median)) | \(ms(t.pasteMedian)) | \(t.lateRevisions) |\n"
        }
        s += "\n## Accuracy\n\n| Tool | pooled WER | EN | DE | self-correction applied | vocabulary hits | failure rate |\n|---|---|---|---|---|---|---|\n"
        for t in r.tools {
            s += "| \(t.tool) | \(percent(t.pooledWER)) | \(percent(t.pooledWER_en)) | \(percent(t.pooledWER_de)) | \(percent(t.correctionRate)) | \(percent(t.vocabHitRate)) | \(percent(t.failureRate)) |\n"
        }
        s += "\n## Paired comparisons (same round + phrase)\n\n| A vs B | metric | pairs | HL(A−B) ms | 95% CI | A win rate |\n|---|---|---|---|---|---|\n"
        for p in r.pairs {
            s += "| \(p.a) vs \(p.b) | \(p.metric) | \(p.pairs) | \(ms(p.hl)) | \(ms(p.ciLow))…\(ms(p.ciHigh)) | \(percent(p.winRate)) |\n"
        }
        let c2 = r.tools.compactMap { t in t.harnessMinusInternalMedian.map { "\(t.tool): \(ms($0)) ms" } }
        if !c2.isEmpty { s += "\nHarness M1 − Le Blab internal release→insert (median): " + c2.joined(separator: ", ") + "\n" }
        s += "\nM1 = release → last change of the final text (stable \(config.stabilityMs) ms + \(config.lateWatchMs) ms late watch). M1₃₅₀ = first 350 ms-quiet text (talkify-comparable). M2 = release → first visible text. Negative HL = A faster. Environment: \(r.env["power"] ?? "?"), thermal \(r.env["thermal"] ?? "?"), Wispr \(r.env["wisprVersion"] ?? "?").\n"
        return s
    }
}
