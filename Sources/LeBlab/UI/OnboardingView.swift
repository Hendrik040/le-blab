import LeBlabCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var permissions: PermissionsManager
    @State private var keyInput = ""
    @State private var keyMessage: String?
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    AnimatedDuck(state: .recording(preview: ""), level: 0.45, stateChangedAt: Date())
                        .frame(width: 72, height: 64)
                    VStack(alignment: .leading) {
                        Text("Le Blab").font(.largeTitle.bold())
                        Text("Blab into any app. Powered by Mistral Voxtral 3.").foregroundStyle(.secondary)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Your audio is processed remotely by Mistral's API, only while you hold the shortcut.", systemImage: "network")
                        Label("No recordings are saved. Transcript history is off unless you turn it on.", systemImage: "internaldrive")
                        Label("Smart formatting sends the transcript to a Mistral language model. You can turn it off.", systemImage: "text.badge.checkmark")
                        Button("Read the privacy details") { coordinator.windows.showSettings(tab: .privacy) }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                step(1, "Mistral API key", done: coordinator.keyState == .present) {
                    if coordinator.keyState == .present {
                        Text("Stored in your Keychain.").foregroundStyle(.secondary)
                    } else {
                        SecureField("Paste your Mistral API key", text: $keyInput)
                        HStack {
                            Button(saving ? "Verifying…" : "Verify & save") { saveKey() }.disabled(keyInput.isEmpty || saving)
                            Link("Get a key", destination: URL(string: "https://console.mistral.ai/api-keys")!)
                        }
                        if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(.secondary) }
                    }
                }

                step(2, "Microphone", done: permissions.microphone == .granted) {
                    if permissions.microphone == .denied {
                        Text("Microphone access was denied. Enable Le Blab in System Settings → Privacy & Security → Microphone.")
                            .font(.callout)
                        Button("Open Microphone Settings", action: permissions.openMicrophoneSettings)
                    } else if permissions.microphone == .notDetermined {
                        Button("Allow microphone access") { Task { _ = await permissions.requestMicrophone() } }
                    } else {
                        Text("Allowed.").foregroundStyle(.secondary)
                    }
                }

                step(3, "Accessibility", done: permissions.accessibility == .granted) {
                    if permissions.accessibility == .granted {
                        Text("Allowed — Le Blab can insert text and listen for its shortcut.").foregroundStyle(.secondary)
                    } else {
                        Text("Needed to type the transcript into other apps and to detect press-and-hold of the shortcut. Le Blab never reads other apps' content beyond the character next to your cursor (for spacing).")
                            .font(.callout)
                        HStack {
                            Button("Request access", action: permissions.promptAccessibility)
                            Button("Open Accessibility Settings", action: permissions.openAccessibilitySettings)
                        }
                        Text("Toggle Le Blab on in the list. If it's already on but not working, remove it with – and add it again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                step(4, "Try it", done: false) {
                    Text("Click into any text field, hold **\(settings.hotkey.displayString)**, speak, and release.")
                    HStack {
                        Text("Shortcut:")
                        HotkeyRecorder(combo: $settings.hotkey) { recording in
                            if recording { coordinator.hotkeys.deactivate() } else { coordinator.activateHotkey() }
                        }
                    }
                    if let error = coordinator.hotkeyError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }

                HStack {
                    Spacer()
                    Button("Done") {
                        settings.hasCompletedOnboarding = true
                        coordinator.windows.closeOnboarding()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear { permissions.startPolling() }
    }

    @ViewBuilder
    private func step<Content: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.25)).frame(width: 26, height: 26)
                if done { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } else { Text("\(n)").font(.callout.bold()) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
        }
    }

    private func saveKey() {
        saving = true
        let candidate = keyInput
        Task {
            let result = await coordinator.testAPIKey(candidate)
            saving = false
            switch result {
            case .success:
                do {
                    try coordinator.saveAPIKey(candidate)
                    keyInput = ""
                    keyMessage = nil
                } catch { keyMessage = "Couldn't save to Keychain: \(error)" }
            case .failure(let error):
                keyMessage = error.userMessage
            }
        }
    }
}
