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
    private var electronCache: [String: Bool] = [:]

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func insert(_ text: String) async -> InsertionOutcome {
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

        await waitForModifierRelease()
        let target = FocusTarget.current()
        if target?.isSecureField == true {
            return .notInserted(reason: "The focused field is a password field.", copied: false)
        }
        let adjusted = SpacingRules.adjust(text, before: target?.characterBeforeCursor, after: target?.characterAfterCursor)

        switch method {
        case .typing:
            typeText(adjusted)
            return .typed
        case .paste:
            return paste(adjusted)
        case .accessibility:
            if let target, target.insertViaAccessibility(adjusted) { return .accessibility }
            return paste(adjusted)
        case .automatic:
            if let target, prefersAccessibility(target), target.insertViaAccessibility(adjusted) { return .accessibility }
            return paste(adjusted)
        }
    }

    // MARK: - Strategy

    /// Web views and Electron editors accept AX writes inconsistently (often "success" with no effect),
    /// and terminals don't support them at all — paste is the reliable path there.
    private func prefersAccessibility(_ target: FocusTarget) -> Bool {
        guard let bundleID = target.bundleID else { return false }
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

    private func paste(_ text: String) -> InsertionOutcome {
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

    private func postKey(_ keyCode: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// If ⌥ from ⌥Space is still physically held, ⌘V would arrive as ⌥⌘V ("paste and match style"
    /// or worse). Give the user up to 400 ms to let go.
    private func waitForModifierRelease() async {
        let relevant: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl, .maskShift]
        for _ in 0..<40 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(relevant).isEmpty { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
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
    func insertViaAccessibility(_ text: String) -> Bool {
        let beforeRange = selectedRange
        let beforeCount = characterCount
        guard beforeRange != nil || beforeCount != nil else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        usleep(30_000)
        let afterRange = selectedRange
        let afterCount = characterCount
        if let beforeCount, let afterCount, beforeCount != afterCount { return true }
        if let b = beforeRange, let a = afterRange, b.location != a.location || b.length != a.length { return true }
        Log.insertion.info("AX write reported success but nothing changed; falling back")
        return false
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
