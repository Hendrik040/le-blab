import AppKit
import ApplicationServices
import Carbon.HIToolbox

public enum InsertionMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Accessibility for native text views, clipboard paste for browsers/Electron/terminals.
    case automatic
    /// Always try Accessibility first, then paste.
    case accessibility
    /// Always paste via the clipboard (clipboard restored afterwards).
    case paste
    /// Simulated keystrokes — no clipboard involvement, slower.
    case typing
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .automatic: return "Automatic (recommended)"
        case .accessibility: return "Accessibility API, paste fallback"
        case .paste: return "Clipboard paste"
        case .typing: return "Simulated typing"
        }
    }
}

public enum InsertionOutcome: Equatable, Sendable {
    case accessibility
    case pasted
    case typed
    /// Automatic insertion wasn't possible; the transcript is kept (and on the clipboard if `copied`).
    case notInserted(reason: String, copied: Bool)

    public var label: String {
        switch self {
        case .accessibility: return "accessibility"
        case .pasted: return "paste"
        case .typed: return "typing"
        case .notInserted: return "not inserted"
        }
    }
}

@MainActor
public protocol TextInserting: AnyObject {
    func insert(_ text: String) async -> InsertionOutcome
    /// Inserts `text` only where it can later be replaced exactly (native text views via Accessibility).
    /// Returns nil — having inserted nothing — anywhere else, so the caller can use `insert` instead.
    func insertProvisional(_ text: String) async -> ProvisionalInsertion?
    /// Swaps a provisional insertion for `text` if the user hasn't touched it since; reports what is
    /// actually in the document afterwards.
    func replaceProvisional(_ insertion: ProvisionalInsertion, with text: String) async -> ReplacementOutcome
}

public enum ReplacementOutcome: Equatable, Sendable {
    /// The polished text is in the document.
    case replaced
    /// The user edited the text or moved on; their document was left as it was.
    case keptProvisional
    /// The field turned out not to support exact replacement; the provisional text stays.
    case notReplaceable
}

/// A piece of text Le Blab inserted and may still replace (see `TextInserting.insertProvisional`).
@MainActor
public final class ProvisionalInsertion {
    /// Exactly what was inserted, including any spacing that was added.
    public let insertedText: String
    let element: AXUIElement?
    /// UTF-16 range of `insertedText` in the field.
    let range: CFRange
    /// Characters around the insertion point, for re-spacing the polished text.
    let before: Character?
    let after: Character?
    let bundleID: String?

    /// False when the field accepted the text but can't be read back exactly; replacing is then unsafe.
    public var isReplaceable: Bool { element != nil }
    /// False when the app accepted the write but the text never showed up (it may still land late).
    public let confirmed: Bool

    init(insertedText: String, element: AXUIElement?, range: CFRange, before: Character? = nil, after: Character? = nil,
         bundleID: String? = nil, confirmed: Bool = true) {
        self.confirmed = confirmed
        self.insertedText = insertedText
        self.element = element
        self.range = range
        self.before = before
        self.after = after
        self.bundleID = bundleID
    }
}

/// Inserts text at the cursor of whatever app is focused. Never presses Return/Enter.
@MainActor
public final class TextInsertionService: TextInserting {
    public var method: InsertionMethod = .automatic
    public var restoreClipboard = true
    /// How long the target app gets to read the clipboard before it's restored.
    public var clipboardRestoreDelay: TimeInterval = 0.5

    private let pasteboard: NSPasteboard
    private var pendingRestore: Task<Void, Never>?
    /// Diagnostics: durations of the last insertion's steps (no content).
    public private(set) var lastTimings = ""
    /// Test harness only: checked immediately before anything is written. Returning false blocks the
    /// write (e.g. the user switched apps during an automated self-test).
    public var targetGuard: (() -> Bool)?
    private var guardBlocks: Bool { targetGuard.map { !$0() } ?? false }
    private var electronCache: [String: Bool] = [:]
    /// Apps where a provisional insert turned out not to be replaceable: use the normal path there.
    private var noProvisionalBundles: Set<String> = []
    /// Apps whose AX writes didn't show up: always paste there.
    private var pasteOnlyBundles: Set<String> = []

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func insert(_ text: String) async -> InsertionOutcome {
        lastTimings = ""
        if guardBlocks { return .notInserted(reason: "Target app changed (test guard).", copied: false) }
        // Serialize with a previous paste whose clipboard restore is still pending.
        await pendingRestore?.value
        pendingRestore = nil

        let text = text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return .notInserted(reason: "Nothing to insert.", copied: false) }

        if IsSecureEventInputEnabled() {
            return .notInserted(reason: "A password field or secure input is active, so Le Blab didn't type into it.", copied: false)
        }
        guard AXIsProcessTrusted() else {
            // Don't clobber the user's clipboard behind their back; the overlay offers Copy.
            return .notInserted(reason: "Le Blab needs Accessibility permission to insert text. Click Copy, then paste with ⌘V.",
                                copied: false)
        }

        let t0 = ProcessInfo.processInfo.systemUptime
        let target = FocusTarget.current()
        let t1 = ProcessInfo.processInfo.systemUptime
        if target?.isSecureField == true {
            return .notInserted(reason: "The focused field is a password field.", copied: false)
        }
        lastTimings = "focus=\(Int((t1 - t0) * 1000))ms"
        if !canReceiveText(target) {
            // A ⌘V into nothing would lose the dictation once the old clipboard is restored: leave it on the clipboard.
            copyToClipboard(text)
            return .notInserted(reason: "No text field was selected, so it's on the clipboard. Click where it should go and press ⌘V.",
                                copied: true)
        }
        let adjusted = SpacingRules.adjust(text, before: target?.characterBeforeCursor, after: target?.characterAfterCursor)

        switch method {
        case .typing:
            await waitForModifierRelease()
            if guardBlocks { return .notInserted(reason: "Target app changed (test guard).", copied: false) }
            typeText(adjusted)
            return .typed
        case .paste:
            return await paste(adjusted)
        case .accessibility, .automatic:
            // Accessibility writes send no key events, so held modifiers don't matter: no waiting.
            if let target, method == .accessibility || prefersAccessibility(target) {
                switch target.writeViaAccessibility(adjusted) {
                case .inserted:
                    return .accessibility
                case .unconfirmed:
                    // The app accepted the write but never showed it. Paste instead, and use paste for this
                    // app from now on so a late-landing AX write can't race a paste again.
                    if let bundle = target.bundleID { pasteOnlyBundles.insert(bundle) }
                case .rejected:
                    break
                }
            }
            return await paste(adjusted)
        }
    }

    // MARK: - Provisional insertion (insert now, polish later)

    public func insertProvisional(_ text: String) async -> ProvisionalInsertion? {
        lastTimings = ""
        if guardBlocks { return nil }
        // Cheap rejections first, so a paste app doesn't wait on anything here.
        guard method == .automatic || method == .accessibility, AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        await pendingRestore?.value
        pendingRestore = nil
        let text = text.trimmingCharacters(in: .newlines)
        let t0 = ProcessInfo.processInfo.systemUptime
        guard !text.isEmpty, let target = FocusTarget.current(), !target.isSecureField,
              method == .accessibility || prefersAccessibility(target),
              !(target.bundleID.map(noProvisionalBundles.contains) ?? false),
              let before = target.selectedRange, before.location >= 0, before.location < 1 << 40 else { return nil }
        // Only write if we can read the field back: otherwise the text could never be replaced.
        let count = target.characterCount ?? 0
        if let total = target.characterCount, before.location + before.length > total { return nil }   // stale/NSNotFound
        let probe = before.location > 0 ? CFRange(location: before.location - 1, length: 1)
            : (count > 0 ? CFRange(location: 0, length: 1) : nil)
        if let probe, target.element.string(forRange: probe) == nil { return nil }
        let charBefore = target.characterBeforeCursor, charAfter = target.characterAfterCursor
        let adjusted = SpacingRules.adjust(text, before: charBefore, after: charAfter)
        switch target.writeViaAccessibility(adjusted) {
        case .inserted: break
        case .rejected: return nil
        case .unconfirmed:
            // Might still land late: never let the caller insert again. Hand back a non-replaceable handle.
            if let bundle = target.bundleID { noProvisionalBundles.insert(bundle); pasteOnlyBundles.insert(bundle) }
            return ProvisionalInsertion(insertedText: adjusted, element: nil, range: CFRange(location: before.location, length: 0),
                                        before: charBefore, after: charAfter, bundleID: target.bundleID, confirmed: false)
        }
        let range = CFRange(location: before.location, length: adjusted.utf16.count)
        // Replaceable only if the exact text is there and the caret sits right after it.
        let caret = target.selectedRange
        let replaceable = target.element.string(forRange: range) == adjusted
            && caret?.location == range.location + range.length && caret?.length == 0
        if !replaceable, let bundle = target.bundleID { noProvisionalBundles.insert(bundle) }
        lastTimings = "optimistic insert=\(Int((ProcessInfo.processInfo.systemUptime - t0) * 1000))ms"
        return ProvisionalInsertion(insertedText: adjusted, element: replaceable ? target.element : nil, range: range,
                                    before: charBefore, after: charAfter, bundleID: target.bundleID)
    }

    public func replaceProvisional(_ insertion: ProvisionalInsertion, with text: String) async -> ReplacementOutcome {
        guard let element = insertion.element else { return .notReplaceable }
        if guardBlocks { return .keptProvisional }
        let t0 = ProcessInfo.processInfo.systemUptime
        defer { lastTimings += " replace=\(Int((ProcessInfo.processInfo.systemUptime - t0) * 1000))ms" }
        // Re-space the polished text against the original neighbours (it may now start with punctuation).
        let newText = SpacingRules.adjust(text.trimmingCharacters(in: .whitespacesAndNewlines),
                                          before: insertion.before, after: insertion.after)
        if newText.isEmpty || newText == insertion.insertedText { return .replaced }
        // The user must not have touched anything: same field focused, caret right after our text, text unchanged.
        guard let current = FocusTarget.current(), CFEqual(current.element, element),
              let caret = current.selectedRange, caret.length == 0,
              caret.location == insertion.range.location + insertion.range.length,
              element.string(forRange: insertion.range) == insertion.insertedText else {
            Log.insertion.info("Provisional text was edited or focus moved; keeping it")
            return .keptProvisional
        }
        let countBefore = current.characterCount
        guard element.setSelectedRange(insertion.range), element.range(kAXSelectedTextRangeAttribute).map({
            $0.location == insertion.range.location && $0.length == insertion.range.length
        }) == true else {
            _ = element.setSelectedRange(caret)
            return .keptProvisional
        }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText as CFString) == .success else {
            _ = element.setSelectedRange(caret)
            return .keptProvisional
        }
        usleep(20_000)
        let length = newText.utf16.count
        if element.string(forRange: CFRange(location: insertion.range.location, length: length)) == newText {
            // Replaced in place only if the field grew by the difference — not by the whole polished text.
            if let countBefore, let countAfter = current.characterCount,
               countAfter == countBefore + length, element.string(forRange: insertion.range) != insertion.insertedText {
                Log.insertion.error("Replace appended instead of replacing")
            }
            return .replaced
        }
        // Some fields ignore the selection and insert at the caret: the polished text then follows the
        // provisional one. Remove the provisional copy so the text never appears twice.
        let after = CFRange(location: insertion.range.location + insertion.range.length, length: length)
        if element.string(forRange: insertion.range) == insertion.insertedText, element.string(forRange: after) == newText {
            if let bundle = insertion.bundleID { noProvisionalBundles.insert(bundle) }
            if element.setSelectedRange(insertion.range),
               AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, "" as CFString) == .success {
                usleep(20_000)
                if element.string(forRange: CFRange(location: insertion.range.location, length: length)) == newText {
                    _ = element.setSelectedRange(CFRange(location: insertion.range.location + length, length: 0))
                    return .replaced
                }
            }
            Log.insertion.error("Couldn't remove provisional copy after append")
        }
        // A keystroke can land between selecting and writing (a millisecond window): the polished text then
        // sits a few characters later. Report what is actually in the document.
        for shift in 1...4 where element.string(forRange: CFRange(location: insertion.range.location + shift, length: length)) == newText {
            return .replaced
        }
        if element.string(forRange: insertion.range) == insertion.insertedText {
            // The write didn't take: put the caret back after the original text.
            _ = element.setSelectedRange(caret)
        }
        return .keptProvisional
    }

    // MARK: - Strategy

    /// False only when focus is clearly not somewhere text can go (nothing focused, the desktop, a Finder list).
    /// Browsers, Electron apps and terminals don't always report their text fields, so they always count as typeable.
    private func canReceiveText(_ target: FocusTarget?) -> Bool {
        let bundleID = target?.bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let bundleID, Self.pasteFirstBundles.contains(bundleID) || bundleID.hasPrefix("com.google.Chrome")
            || bundleID.hasPrefix("com.jetbrains.") { return true }
        if let bundleID, isElectron(bundleID: bundleID, url: target?.bundleURL
                                    ?? NSWorkspace.shared.frontmostApplication?.bundleURL) { return true }
        guard let target else { return false }
        return FocusClassifier.canReceiveText(role: target.role, isInsideWebArea: target.isInsideWebArea,
                                              hasTextRange: { target.selectedRange != nil })
    }

    /// Web views and Electron editors accept AX writes inconsistently (often "success" with no effect),
    /// and terminals don't support them at all — paste is the reliable path there.
    private func prefersAccessibility(_ target: FocusTarget) -> Bool {
        guard let bundleID = target.bundleID, !pasteOnlyBundles.contains(bundleID) else { return false }
        if Self.pasteFirstBundles.contains(bundleID) || bundleID.hasPrefix("com.google.Chrome") || bundleID.hasPrefix("com.jetbrains.") {
            return false
        }
        if isElectron(bundleID: bundleID, url: target.bundleURL) { return false }
        if target.role == "AXWebArea" || target.isInsideWebArea { return false }
        return true
    }

    static let pasteFirstBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.apple.Safari",
        "com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.hnc.Discord", "notion.id", "md.obsidian", "com.figma.Desktop", "com.linear",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "com.microsoft.teams2", "us.zoom.xos", "com.spotify.client",
    ]

    private func isElectron(bundleID: String, url: URL?) -> Bool {
        if let cached = electronCache[bundleID] { return cached }
        let result = url.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        electronCache[bundleID] = result
        return result
    }

    // MARK: - Paste

    /// Leaves `text` on the clipboard for the user to paste (not transient, never restored).
    private func copyToClipboard(_ text: String) {
        pendingRestore?.cancel()
        pendingRestore = nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func paste(_ text: String) async -> InsertionOutcome {
        // ⌘V is a synthetic key event: a still-held ⌃/⌥/⇧ from the shortcut would change its meaning.
        await waitForModifierRelease()
        if guardBlocks { return .notInserted(reason: "Target app changed (test guard).", copied: false) }
        let snapshot = restoreClipboard ? PasteboardSnapshot(of: pasteboard) : nil
        let ourChange = PasteboardMarkers.writeTransient(text, to: pasteboard)
        postKey(KeyboardLayout.keyCode(for: "v", fallback: UInt16(kVK_ANSI_V)), flags: .maskCommand)

        if let snapshot {
            let pasteboard = self.pasteboard
            let delay = clipboardRestoreDelay
            pendingRestore = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                // Only restore if nobody (user or app) changed the clipboard in the meantime.
                if pasteboard.changeCount == ourChange { snapshot.restore(to: pasteboard) }
            }
        }
        return .pasted
    }

    // MARK: - Typing

    private func typeText(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
        var buffer: [UniChar] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer)
                event?.post(tap: .cghidEventTap)
            }
            buffer.removeAll()
            usleep(2000)
        }
        for scalar in text.utf16 {
            if scalar == 0x0A {
                flush()
                // Shift+Return = newline in chat apps without sending the message.
                postKey(UInt16(kVK_Return), flags: .maskShift)
                continue
            }
            buffer.append(scalar)
            if buffer.count >= 16 { flush() }
        }
        flush()
    }

    // MARK: - Helpers

    /// Posts a complete chord: modifier down → key down → key up → modifier up. Sending only the key
    /// with a modifier flag leaves macOS's combined keyboard state believing the modifier is still
    /// held, which delayed the next insertion and made the next paste unreliable.
    private func postKey(_ keyCode: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let modifierKeys: [(CGEventFlags, Int)] = [(.maskCommand, kVK_Command), (.maskShift, kVK_Shift),
                                                   (.maskAlternate, kVK_Option), (.maskControl, kVK_Control)]
        let modifiers = modifierKeys.filter { flags.contains($0.0) }
        func post(_ code: Int, down: Bool, _ eventFlags: CGEventFlags, modifier: Bool) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return }
            if modifier { event.type = .flagsChanged }
            event.flags = eventFlags
            event.post(tap: .cghidEventTap)
        }
        var held: CGEventFlags = []
        for (flag, code) in modifiers {
            held.insert(flag)
            post(code, down: true, held, modifier: true)
        }
        post(Int(keyCode), down: true, flags, modifier: false)
        post(Int(keyCode), down: false, flags, modifier: false)
        for (flag, code) in modifiers.reversed() {
            held.remove(flag)
            post(code, down: false, held, modifier: true)
        }
    }

    /// If ⌥ from ⌥Space is still physically held, ⌘V would arrive as ⌥⌘V ("paste and match style"
    /// or worse). Give the user up to 400 ms to let go.
    private func waitForModifierRelease() async {
        let relevant: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl, .maskShift]
        let start = ProcessInfo.processInfo.systemUptime
        let held = CGEventSource.flagsState(.combinedSessionState).intersection(relevant)
        defer {
            lastTimings += " modifierWait=\(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))ms held=0x\(String(held.rawValue, radix: 16))"
        }
        for _ in 0..<40 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(relevant).isEmpty { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Decides from the focused element's Accessibility role whether pasting there could land in a text field.
enum FocusClassifier {
    /// Containers and controls that never take typed text themselves.
    static let nonTextRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXDrawer", "AXScrollArea", "AXSplitGroup", "AXGroup",
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXImage", "AXButton",
        "AXStaticText", "AXToolbar", "AXMenuBar", "AXMenu", "AXMenuItem", "AXTabGroup", "AXRadioButton", "AXCheckBox",
    ]

    /// Unknown roles count as typeable: a wrong "no field" only costs an extra ⌘V, a wrong "field" loses the text.
    static func canReceiveText(role: String?, isInsideWebArea: Bool, hasTextRange: () -> Bool) -> Bool {
        guard let role, nonTextRoles.contains(role) else { return true }
        return isInsideWebArea || hasTextRange()
    }
}

/// The focused UI element of the frontmost app, via the Accessibility API.
struct FocusTarget {
    let element: AXUIElement
    let bundleID: String?
    let bundleURL: URL?
    let role: String?
    let subrole: String?
    let isInsideWebArea: Bool

    static func current() -> FocusTarget? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        return FocusTarget(element: element, bundleID: app?.bundleIdentifier, bundleURL: app?.bundleURL,
                           role: element.string(kAXRoleAttribute), subrole: element.string(kAXSubroleAttribute),
                           isInsideWebArea: element.hasAncestor(role: "AXWebArea"))
    }

    var isSecureField: Bool { subrole == (kAXSecureTextFieldSubrole as String) }

    var selectedRange: CFRange? { element.range(kAXSelectedTextRangeAttribute) }

    var characterCount: Int? {
        if let n = element.int(kAXNumberOfCharactersAttribute) { return n }
        return element.string(kAXValueAttribute)?.utf16.count
    }

    var characterBeforeCursor: Character? {
        guard let range = selectedRange, range.location > 0 else { return nil }
        return element.string(forRange: CFRange(location: range.location - 1, length: 1))?.last
    }

    var characterAfterCursor: Character? {
        guard let range = selectedRange, let count = characterCount, range.location + range.length < count else { return nil }
        return element.string(forRange: CFRange(location: range.location + range.length, length: 1))?.first
    }

    /// Sets the selected text (= inserts at the cursor, replacing any selection) and verifies that the
    /// element actually changed — many web views report success without doing anything.
    enum AXWriteResult { case inserted, rejected, unconfirmed }

    /// Sets the selected text (= inserts at the cursor, replacing any selection) and confirms the
    /// element actually changed. Some apps apply AX writes asynchronously, so a "no change yet" is
    /// re-checked for up to `confirmWindow` before giving up — falling back to paste too early is what
    /// produced duplicate text.
    func writeViaAccessibility(_ text: String, confirmWindow: TimeInterval = 0.25) -> AXWriteResult {
        let beforeRange = selectedRange
        let beforeCount = characterCount
        guard beforeRange != nil || beforeCount != nil else { return .rejected }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return .rejected }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return .rejected
        }
        let expected = beforeRange.map { CFRange(location: $0.location, length: text.utf16.count) }
        let deadline = ProcessInfo.processInfo.systemUptime + confirmWindow
        repeat {
            usleep(10_000)
            if let expected, element.string(forRange: expected) == text { return .inserted }
            if let beforeCount, let afterCount = characterCount, afterCount != beforeCount { return .inserted }
            if let b = beforeRange, let a = selectedRange, b.location != a.location || b.length != a.length { return .inserted }
        } while ProcessInfo.processInfo.systemUptime < deadline
        Log.insertion.info("AX write reported success but nothing changed")
        return .unconfirmed
    }

    func insertViaAccessibility(_ text: String) -> Bool {
        writeViaAccessibility(text) == .inserted
    }
}

extension AXUIElement {
    func string(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func int(_ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    func range(_ attribute: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    func setSelectedRange(_ range: CFRange) -> Bool {
        var r = range
        guard let value = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(self, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func string(forRange range: CFRange) -> String? {
        var r = range
        guard let axRange = AXValueCreate(.cfRange, &r) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(self, kAXStringForRangeParameterizedAttribute as CFString,
                                                         axRange, &value) == .success else { return nil }
        return value as? String
    }

    func hasAncestor(role: String, maxDepth: Int = 12) -> Bool {
        var current: AXUIElement? = self
        for _ in 0..<maxDepth {
            var parent: CFTypeRef?
            guard let node = current,
                  AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            let element = parent as! AXUIElement
            if element.string(kAXRoleAttribute) == role { return true }
            current = element
        }
        return false
    }
}

/// Test support: reads the focused element's text. Used only by the app's `--selftest-readback`
/// flag against a throwaway test document — never during normal dictation.
public enum AccessibilityReadback {
    public static func focusedValue() -> String? {
        FocusTarget.current()?.element.string(kAXValueAttribute)
    }

    public static func focusedAppBundleID() -> String? {
        FocusTarget.current()?.bundleID
    }
}
