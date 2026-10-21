import LeBlabCore
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var controller: DictationController
    @EnvironmentObject var permissions: PermissionsManager

    var body: some View {
        Text(statusLine)
        Text("Microphone: \(microphoneLine)")
        Text("Model: \(settings.quality.shortName)" + (settings.formattingMode == .smart ? " + smart formatting" : ""))

        if let attention = attentionLine {
            Button("⚠︎ \(attention)") { coordinator.windows.showOnboarding() }
        }

        Divider()

        Button(controller.isRecording ? "Stop Dictation" : "Start Dictation  (\(settings.hotkey.displayString))") {
            coordinator.controller.toggleFromMenu()
        }
        .disabled(coordinator.keyState != .present && !controller.isRecording)

        Picker("Formatting", selection: $settings.formattingMode) {
            ForEach(FormattingMode.allCases) { Text($0.displayName).tag($0) }
        }
        Picker("Transcription", selection: $settings.quality) {
            ForEach(TranscriptionQuality.allCases) { Text($0.displayName).tag($0) }
        }
        Picker("Language", selection: $settings.language) {
            ForEach(LanguageOption.all.prefix(8)) { Text($0.displayName).tag($0.code) }
        }
        Picker("Shortcut Mode", selection: $settings.activationMode) {
            ForEach(ActivationMode.allCases) { Text($0.displayName).tag($0) }
        }

        Divider()

        Button("Copy Last Transcript") { coordinator.copyLastTranscript() }
            .disabled(controller.lastTranscript == nil)
        if settings.historyEnabled {
            Button("History…") { coordinator.windows.showSettings(tab: .history) }
        }

        Divider()

        Button("Settings…") { coordinator.windows.showSettings(tab: .general) }
            .keyboardShortcut(",")
        Button("Shortcut & Microphone…") { coordinator.windows.showSettings(tab: .general) }
        Button("API Key…") { coordinator.windows.showSettings(tab: .account) }
        Button("Privacy…") { coordinator.windows.showSettings(tab: .privacy) }
        Button("Diagnostics…") { coordinator.windows.showSettings(tab: .diagnostics) }

        Divider()

        Button("Quit Le Blab") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch controller.state {
        case .recording: return "● Recording…"
        case .processing: return "Transcribing…"
        case .failed(let message, _): return "Error: \(message.prefix(60))"
        default: return "Le Blab — Ready"
        }
    }

    private var microphoneLine: String {
        switch permissions.microphone {
        case .granted:
            if let uid = settings.inputDeviceUID, let device = AudioDevices.inputDevices().first(where: { $0.id == uid }) {
                return device.name
            }
            return AudioDevices.defaultInputDevice()?.name ?? "System default"
        case .denied: return "Access denied"
        case .notDetermined: return "Not yet allowed"
        }
    }

    private var attentionLine: String? {
        if coordinator.keyState == .missing { return "Add your Mistral API key" }
        if case .denied = coordinator.keyState { return "Keychain access denied" }
        if permissions.microphone == .denied { return "Microphone access needed" }
        if permissions.accessibility != .granted { return "Accessibility access needed" }
        if coordinator.hotkeyBackend == .none { return coordinator.hotkeyError ?? "Shortcut inactive" }
        return nil
    }
}
