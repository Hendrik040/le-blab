import AppKit
import Carbon.HIToolbox
import CoreGraphics

public enum HotkeyEvent: Equatable, Sendable {
    case pressed
    case released
    /// Escape while dictation is active.
    case cancel
    /// Another key was pressed while a modifier-only shortcut was held (e.g. Fn+←) — not a dictation.
    case chordInterrupted
}

/// Global push-to-talk shortcut.
///
/// Two backends:
/// - **Event tap** (preferred, needs Accessibility — which text insertion needs anyway): sees key-down,
///   key-up and modifier changes, swallows the shortcut so ⌥Space never types a non-breaking space,
///   supports modifier-only shortcuts (Fn, right ⌥), and intercepts Escape only while recording.
///   Runs on its own thread so a busy main thread can never lag system-wide typing.
/// - **Carbon hot key** (fallback before Accessibility is granted): no permission needed, key combos only.
///
/// Input Monitoring permission is not required by either backend.
@MainActor
public final class HotkeyManager {
    public enum Backend: String, Sendable { case eventTap = "Event tap", carbon = "Carbon hot key", none = "Inactive" }

    public private(set) var backend: Backend = .none
    public private(set) var registrationError: String?
    public private(set) var combo: KeyCombo = .optionSpace
    public var onEvent: ((HotkeyEvent) -> Void)?

    private let tap = EventTapMonitor()
    private let carbon = CarbonHotkeys()

    public init() {
        tap.onEvent = { [weak self] event in self?.onEvent?(event) }
        carbon.onEvent = { [weak self] event in self?.onEvent?(event) }
    }

    /// (Re)installs the shortcut, choosing the best backend available right now.
    @discardableResult
    public func activate(_ combo: KeyCombo, accessibilityTrusted: Bool) -> Backend {
        self.combo = combo
        tap.stop()
        carbon.unregisterAll()
        registrationError = nil

        if accessibilityTrusted, tap.start(combo: combo) {
            backend = .eventTap
            Log.hotkey.info("Hotkey active via event tap")
            return backend
        }
        if combo.kind != .key {
            backend = .none
            registrationError = "\(combo.displayString) needs Accessibility permission. Grant it, or choose a key combination."
            return backend
        }
        switch carbon.register(combo) {
        case noErr:
            backend = .carbon
            Log.hotkey.info("Hotkey active via Carbon")
        case OSStatus(eventHotKeyExistsErr):
            backend = .none
            registrationError = "\(combo.displayString) is already taken by another app. Pick a different shortcut."
        case let status:
            backend = .none
            registrationError = "macOS refused \(combo.displayString) (error \(status)). Grant Accessibility or pick another shortcut."
        }
        return backend
    }

    /// Escape cancels only while a dictation is running; otherwise it reaches apps untouched.
    public func setCancelActive(_ active: Bool) {
        tap.setCancelActive(active)
        if backend == .carbon { carbon.setEscapeRegistered(active) }
    }

    public func deactivate() {
        tap.stop()
        carbon.unregisterAll()
        backend = .none
    }
}

// MARK: - Event tap backend

final class EventTapMonitor: @unchecked Sendable {
    var onEvent: (@MainActor (HotkeyEvent) -> Void)?

    private let lock = NSLock()
    private var combo: KeyCombo = .optionSpace
    private var cancelActive = false
    private var keyHeld = false
    private var modifierHeld = false
    private var chordDuringModifier = false
    private var swallowEscapeUp = false

    private var machPort: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    // Device-dependent modifier bits (IOLLEvent.h) distinguish left/right keys.
    private static let rightOptionMask: UInt64 = 0x0000_0040
    private static let rightCommandMask: UInt64 = 0x0000_0010

    func start(combo: KeyCombo) -> Bool {
        stop()
        lock.withLock {
            self.combo = combo
            keyHeld = false
            modifierHeld = false
        }
        let ready = DispatchSemaphore(value: 0)
        var success = false
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: CGEventMask(mask), callback: eventTapCallback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self.lock.withLock {
                self.machPort = port
                self.runLoop = loop
            }
            success = true
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "LeBlab.HotkeyTap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
        if !success { self.thread = nil }
        return success
    }

    func stop() {
        let (port, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer { machPort = nil; runLoop = nil }
            return (machPort, runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
        thread = nil
    }

    func setCancelActive(_ active: Bool) {
        lock.withLock { cancelActive = active }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ machPort }) { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var emit: HotkeyEvent?
        var swallow = false

        lock.lock()
        switch type {
        case .keyDown:
            if cancelActive, code == UInt16(kVK_Escape) {
                emit = .cancel
                swallow = true
                swallowEscapeUp = true
            } else if combo.kind == .key, code == combo.keyCode, KeyModifiers(cgFlags: flags) == combo.modifiers {
                if !keyHeld && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    keyHeld = true
                    emit = .pressed
                }
                swallow = true
            } else if combo.kind != .key, modifierHeld, !chordDuringModifier {
                chordDuringModifier = true
                emit = .chordInterrupted
            }
        case .keyUp:
            if combo.kind == .key, code == combo.keyCode, keyHeld {
                keyHeld = false
                emit = .released
                swallow = true
            } else if code == UInt16(kVK_Escape), swallowEscapeUp {
                swallowEscapeUp = false
                swallow = true
            }
        case .flagsChanged:
            if combo.kind == .modifierChord {
                let held = KeyModifiers(chordFlags: flags)
                if held == combo.modifiers, !modifierHeld {
                    modifierHeld = true
                    chordDuringModifier = false
                    emit = .pressed
                } else if modifierHeld, held != combo.modifiers {
                    modifierHeld = false
                    // Released one of the keys → end of dictation. Added another modifier → not ours.
                    if chordDuringModifier {
                        emit = nil
                    } else if held.isSuperset(of: combo.modifiers) {
                        chordDuringModifier = true
                        emit = .chordInterrupted
                    } else {
                        emit = .released
                    }
                }
            } else if combo.kind == .modifierOnly, code == combo.keyCode {
                let down = isModifierDown(flags)
                if down, !modifierHeld {
                    modifierHeld = true
                    chordDuringModifier = false
                    emit = .pressed
                } else if !down, modifierHeld {
                    modifierHeld = false
                    if !chordDuringModifier { emit = .released }
                }
            }
        default:
            break
        }
        lock.unlock()

        if let emit, let onEvent {
            DispatchQueue.main.async { MainActor.assumeIsolated { onEvent(emit) } }
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func isModifierDown(_ flags: CGEventFlags) -> Bool {
        switch Int(combo.keyCode) {
        case kVK_RightOption: return flags.rawValue & Self.rightOptionMask != 0
        case kVK_RightCommand: return flags.rawValue & Self.rightCommandMask != 0
        default: return flags.contains(combo.modifierFlag)
        }
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<EventTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}

// MARK: - Carbon backend

@MainActor
final class CarbonHotkeys {
    var onEvent: ((HotkeyEvent) -> Void)?
    private var mainRef: EventHotKeyRef?
    private var escapeRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4C42_4C42 // "LBLB"
    private static let mainID: UInt32 = 1
    private static let escapeID: UInt32 = 2

    func register(_ combo: KeyCombo) -> OSStatus {
        installHandlerIfNeeded()
        unregisterAll()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.modifiers.carbonFlags,
                                         EventHotKeyID(signature: Self.signature, id: Self.mainID),
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr { mainRef = ref }
        return status
    }

    func setEscapeRegistered(_ on: Bool) {
        if on, escapeRef == nil {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: Self.escapeID),
                                   GetEventDispatcherTarget(), 0, &ref) == noErr {
                escapeRef = ref
            }
        } else if !on, let ref = escapeRef {
            UnregisterEventHotKey(ref)
            escapeRef = nil
        }
    }

    func unregisterAll() {
        if let mainRef { UnregisterEventHotKey(mainRef) }
        if let escapeRef { UnregisterEventHotKey(escapeRef) }
        mainRef = nil
        escapeRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let owner = Unmanaged<CarbonHotkeys>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if id == CarbonHotkeys.escapeID {
                        if pressed { owner.onEvent?(.cancel) }
                    } else {
                        owner.onEvent?(pressed ? .pressed : .released)
                    }
                }
            }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
