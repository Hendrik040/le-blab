import AppKit
import Carbon.HIToolbox
import CoreGraphics

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
    /// Fn / Globe. Only meaningful for modifier chords (arrow and F-keys also set the Fn flag).
    public static let function = KeyModifiers(rawValue: 1 << 4)

    /// ⌘⌥⌃⇧ plus Fn, for matching modifier chords.
    public init(chordFlags flags: CGEventFlags) {
        var m = KeyModifiers(cgFlags: flags)
        if flags.contains(.maskSecondaryFn) { m.insert(.function) }
        self = m
    }

    public init(cgFlags: CGEventFlags) {
        var m: KeyModifiers = []
        if cgFlags.contains(.maskCommand) { m.insert(.command) }
        if cgFlags.contains(.maskAlternate) { m.insert(.option) }
        if cgFlags.contains(.maskControl) { m.insert(.control) }
        if cgFlags.contains(.maskShift) { m.insert(.shift) }
        self = m
    }

    public init(nsFlags: NSEvent.ModifierFlags) {
        var m: KeyModifiers = []
        if nsFlags.contains(.command) { m.insert(.command) }
        if nsFlags.contains(.option) { m.insert(.option) }
        if nsFlags.contains(.control) { m.insert(.control) }
        if nsFlags.contains(.shift) { m.insert(.shift) }
        self = m
    }

    var carbonFlags: UInt32 {
        var f = 0
        if contains(.command) { f |= cmdKey }
        if contains(.option) { f |= optionKey }
        if contains(.control) { f |= controlKey }
        if contains(.shift) { f |= shiftKey }
        return UInt32(f)
    }

    public var symbols: String {
        (contains(.function) ? "Fn" : "") + (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A global shortcut: key + modifiers (⌥Space), a lone modifier key held down (Fn, right ⌥),
/// or a chord of modifiers held together (⌃⇧, Fn⇧).
public struct KeyCombo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case key, modifierOnly, modifierChord }

    public var kind: Kind
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, modifiers: KeyModifiers) {
        self.kind = .key
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    private init(modifierKeyCode: UInt16) {
        self.kind = .modifierOnly
        self.keyCode = modifierKeyCode
        self.modifiers = []
    }

    public init(chord: KeyModifiers) {
        self.kind = .modifierChord
        self.keyCode = 0
        self.modifiers = chord
    }

    /// Default: hold Control+Shift. Easy to hold, not used on its own by macOS, doesn't type anything.
    public static let controlShift = KeyCombo(chord: [.control, .shift])
    public static let fnShift = KeyCombo(chord: [.function, .shift])
    public static let optionSpace = KeyCombo(keyCode: UInt16(kVK_Space), modifiers: .option)
    public static let fnKey = KeyCombo(modifierKeyCode: UInt16(kVK_Function))
    public static let rightOption = KeyCombo(modifierKeyCode: UInt16(kVK_RightOption))
    public static let rightCommand = KeyCombo(modifierKeyCode: UInt16(kVK_RightCommand))
    public static let presets: [KeyCombo] = [.controlShift, .fnShift, .optionSpace, .fnKey, .rightOption, .rightCommand]

    /// Modifier-only shortcuts are also the first half of other apps' shortcuts, so feedback is
    /// delayed briefly; if another key joins, it was a normal shortcut and the dictation is discarded.
    public var needsChordDebounce: Bool { kind != .key }

    /// Combos taken by macOS or popular apps, with a hint for the settings UI.
    public var knownConflict: String? {
        if kind == .modifierChord {
            if modifiers.contains(.function) {
                return "Set System Settings → Keyboard → \"Press 🌐 key to\" → Do Nothing, so the Globe key doesn't open emoji or dictation. Other dictation apps (e.g. Wispr Flow) may also use Fn."
            }
            return "Other apps' \(modifiers.symbols)+key shortcuts keep working: when another key joins the chord, Le Blab steps aside."
        }
        if kind == .modifierOnly, Int(keyCode) == kVK_Function {
            return "Fn is also the default for macOS dictation/emoji and for other dictation apps (e.g. Wispr Flow)."
        }
        guard kind == .key else { return nil }
        switch (Int(keyCode), modifiers) {
        case (kVK_Space, [.command]): return "Spotlight uses ⌘Space."
        case (kVK_Space, [.control]), (kVK_Space, [.control, .option]): return "macOS uses this to switch input sources."
        case (kVK_Space, [.option]): return "Some apps (ChatGPT, Raycast, Alfred) also default to ⌥Space."
        case (kVK_Space, [.command, .option]): return "Finder uses ⌥⌘Space for search."
        default: break
        }
        if modifiers.isEmpty || modifiers == [.shift] { return "Shortcuts without ⌘, ⌥ or ⌃ will block normal typing." }
        return nil
    }

    public var displayString: String {
        switch kind {
        case .modifierChord:
            return modifiers.symbols
        case .modifierOnly:
            switch Int(keyCode) {
            case kVK_Function: return "Fn (Globe)"
            case kVK_RightOption: return "Right ⌥"
            case kVK_RightCommand: return "Right ⌘"
            default: return "Modifier \(keyCode)"
            }
        case .key:
            return modifiers.symbols + Self.keyName(keyCode)
        }
    }

    /// The CGEventFlags bit a modifier-only combo watches.
    var modifierFlag: CGEventFlags {
        switch Int(keyCode) {
        case kVK_Function: return .maskSecondaryFn
        case kVK_RightOption, kVK_Option: return .maskAlternate
        case kVK_RightCommand, kVK_Command: return .maskCommand
        default: return []
        }
    }

    static func keyName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"; case kVK_F4: return "F4"
        case kVK_F5: return "F5"; case kVK_F6: return "F6"; case kVK_F7: return "F7"; case kVK_F8: return "F8"
        case kVK_F9: return "F9"; case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_F13: return "F13"; case kVK_F14: return "F14"; case kVK_F15: return "F15"
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"; case kVK_UpArrow: return "↑"; case kVK_DownArrow: return "↓"
        default:
            return KeyboardLayout.character(for: code)?.uppercased() ?? "Key \(code)"
        }
    }
}

/// Translates virtual key codes using the user's current keyboard layout.
public enum KeyboardLayout {
    public static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    /// Key code that types `character` in the current layout (so ⌘V works on Dvorak/AZERTY too).
    public static func keyCode(for target: String, fallback: UInt16) -> UInt16 {
        for code in UInt16(0)..<UInt16(128) where character(for: code)?.lowercased() == target {
            return code
        }
        return fallback
    }
}
