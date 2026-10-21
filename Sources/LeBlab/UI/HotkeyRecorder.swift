import AppKit
import LeBlabCore
import SwiftUI

/// Click, then press the new shortcut. Modifier-only shortcuts (Fn, right ⌥/⌘) are offered as presets.
struct HotkeyRecorder: View {
    @Binding var combo: KeyCombo
    /// The live global shortcut is paused while recording so it can't fire (or swallow the keys).
    var onRecordingChange: (Bool) -> Void = { _ in }
    @State private var recording = false
    @State private var monitor: Any?
    @State private var chordPeak: KeyModifiers = []

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Text(recording ? "Press shortcut…" : combo.displayString)
                    .frame(minWidth: 120)
                    .font(.system(.body, design: .rounded).weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            Menu("Presets") {
                ForEach(KeyCombo.presets, id: \.self) { preset in
                    Button((preset.kind == .key ? "" : "Hold ") + preset.displayString + (preset == .controlShift ? " (default)" : "")) {
                        combo = preset
                    }
                }
            }
            .fixedSize()
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        onRecordingChange(true)
        chordPeak = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                // Modifier chord: press e.g. ⌃ and ⇧ together, then release them.
                var held = KeyModifiers(nsFlags: event.modifierFlags)
                if event.modifierFlags.contains(.function) { held.insert(.function) }
                if held.isEmpty {
                    if chordPeak.rawValue.nonzeroBitCount >= 2 || chordPeak == [.function] {
                        combo = chordPeak == [.function] ? .fnKey : KeyCombo(chord: chordPeak)
                        stop()
                    }
                    chordPeak = []
                } else {
                    chordPeak.formUnion(held)
                }
                return event
            }
            chordPeak = []
            if event.keyCode == 53 { stop(); return nil }   // Escape aborts
            let mods = KeyModifiers(nsFlags: event.modifierFlags)
            guard !mods.isEmpty || (96...122).contains(Int(event.keyCode)) else { NSSound.beep(); return nil }
            combo = KeyCombo(keyCode: event.keyCode, modifiers: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        if recording { onRecordingChange(false) }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
