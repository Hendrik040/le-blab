import LeBlabCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var navigation: SettingsNavigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettings().tabItem { Label("General", systemImage: SettingsTab.general.symbol) }.tag(SettingsTab.general)
            TranscriptionSettings().tabItem { Label("Transcription", systemImage: SettingsTab.transcription.symbol) }.tag(SettingsTab.transcription)
            FormattingSettings().tabItem { Label("Formatting", systemImage: SettingsTab.formatting.symbol) }.tag(SettingsTab.formatting)
            AccountSettings().tabItem { Label("Account", systemImage: SettingsTab.account.symbol) }.tag(SettingsTab.account)
            PrivacySettings().tabItem { Label("Privacy", systemImage: SettingsTab.privacy.symbol) }.tag(SettingsTab.privacy)
            HistorySettings().tabItem { Label("History", systemImage: SettingsTab.history.symbol) }.tag(SettingsTab.history)
            DiagnosticsSettings().tabItem { Label("Diagnostics", systemImage: SettingsTab.diagnostics.symbol) }.tag(SettingsTab.diagnostics)
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var permissions: PermissionsManager
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Dictation shortcut") {
                    HotkeyRecorder(combo: $settings.hotkey) { recording in
                        if recording { coordinator.hotkeys.deactivate() } else { coordinator.activateHotkey() }
                    }
                }
                if let conflict = settings.hotkey.knownConflict {
                    Text(conflict).font(.caption).foregroundStyle(.secondary)
                }
                if let error = coordinator.hotkeyError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Picker("Activation", selection: $settings.activationMode) {
                    ForEach(ActivationMode.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.activationMode == .toggle {
                    Toggle("Stop automatically when I stop talking", isOn: $settings.autoStopOnSilence)
                    Text("Uses Voxtral 3's built-in turn detection.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Escape cancels a dictation in progress. Le Blab never presses Return for you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Microphone") {
                Picker("Input device", selection: Binding(get: { settings.inputDeviceUID ?? "" },
                                                         set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 })) {
                    Text("System default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                }
                PermissionRow(title: "Microphone access", status: permissions.microphone,
                              action: { Task { _ = await permissions.requestMicrophone() } },
                              openSettings: permissions.openMicrophoneSettings)
            }
            Section("Behavior") {
                Picker("Text insertion", selection: $settings.insertionMethod) {
                    ForEach(InsertionMethod.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Restore my clipboard after pasting", isOn: $settings.restoreClipboard)
                Toggle("Show live transcript while speaking", isOn: $settings.showLivePreview)
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Launch at login", isOn: Binding(get: { coordinator.launchAtLogin }, set: { coordinator.launchAtLogin = $0 }))
                PermissionRow(title: "Accessibility access (insert text, shortcut)", status: permissions.accessibility,
                              action: permissions.promptAccessibility, openSettings: permissions.openAccessibilitySettings)
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDevices.inputDevices() }
    }
}

struct PermissionRow: View {
    let title: String
    let status: PermissionsManager.Status
    let action: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(status == .granted ? .green : .orange)
            Text(title)
            Spacer()
            if status != .granted {
                Button(status == .notDetermined ? "Allow…" : "Request", action: action)
                Button("Open System Settings", action: openSettings)
            } else {
                Text("Granted").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Transcription

struct TranscriptionSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var newTerm = ""
    @State private var newAliases = ""

    var body: some View {
        Form {
            Section("Model") {
                Picker("Quality", selection: $settings.quality) {
                    ForEach(TranscriptionQuality.allCases) { Text($0.displayName).tag($0) }
                }
                Text(settings.quality == .fast
                     ? "Streams audio to \(MistralAPI.Models.realtime) and inserts its final transcript."
                     : "Live preview streams via the realtime model; on release the whole clip is transcribed by \(MistralAPI.Models.smallBatch). Slower, more accurate, and audio is processed twice.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Streaming delay", selection: $settings.streamingDelayMs) {
                    ForEach(SettingsStore.streamingDelayChoices, id: \.self) { ms in
                        Text(delayLabel(ms)).tag(ms)
                    }
                }
                Text("How much look-ahead the realtime model uses. Lower = faster partials; higher = more accurate final text.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Language", selection: $settings.language) {
                    ForEach(LanguageOption.all) { Text($0.displayName).tag($0.code) }
                }
                Text("Automatic detects the language per dictation, so you can switch between English and German freely.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("API region", selection: $settings.region) {
                    ForEach(MistralAPI.Region.allCases) { Text($0.displayName).tag($0) }
                }
            }
            Section("Custom vocabulary") {
                Text("Sent as Voxtral context biasing at the start of each dictation, and used to fix spelling afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(settings.vocabulary) { entry in
                    HStack {
                        Text(entry.term).fontWeight(.medium)
                        if !entry.aliases.isEmpty {
                            Text("← " + entry.aliases.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.vocabulary.removeAll { $0.id == entry.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Term (e.g. Kubernetes)", text: $newTerm)
                    TextField("Sounds like (optional, comma-separated)", text: $newAliases)
                    Button("Add", action: addTerm).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func delayLabel(_ ms: Int) -> String {
        switch ms {
        case 240: return "240 ms — fastest"
        case 480: return "480 ms — balanced (default)"
        case 2400: return "2400 ms — most accurate"
        default: return "\(ms) ms"
        }
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        let aliases = newAliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        settings.vocabulary.append(VocabularyEntry(term: term, aliases: aliases))
        newTerm = ""
        newAliases = ""
    }
}

// MARK: - Formatting

struct FormattingSettings: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var settings: SettingsStore
    @State private var sample = "so um I think we should uh ship the CodeRabbit integration on tuesday no wait wednesday"
    @State private var output = ""
    @State private var running = false

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Formatting", selection: $settings.formattingMode) {
                    ForEach(FormattingMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(settings.formattingMode == .raw
                     ? "Inserts Voxtral's words as recognized, with only whitespace and vocabulary fixes. Transcripts are not sent to any language model."
                     : "Sends each transcript (only the transcript and your vocabulary, never other app content) to a Mistral language model to remove fillers, fix punctuation and apply self-corrections. If the model is slow, fails, or its output doesn't look like an edit of what you said, Le Blab inserts the raw transcript instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.formattingMode == .smart {
                Section("Language model") {
                    Picker("Model", selection: $settings.formatterModel) {
                        ForEach(MistralAPI.Models.formatterChoices, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Try it") {
                    TextField("Sample transcript", text: $sample, axis: .vertical).lineLimit(2...4)
                    HStack {
                        Button(running ? "Formatting…" : "Format sample") { run() }.disabled(running || sample.isEmpty)
                        Text("Sends the sample text to Mistral.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !output.isEmpty { Text(output).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func run() {
        running = true
        let formatter = coordinator.makeFormatter()
        let text = sample
        Task {
            let start = Date()
            let result = await formatter.format(text, language: nil)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            output = result.text + "\n\n(\(ms) ms" + (result.fallbackReason.map { ", fallback: \($0)" } ?? "") + ")"
            running = false
        }
    }
}

// MARK: - Account

struct AccountSettings: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var keyInput = ""
    @State private var message: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Mistral API key") {
                HStack {
                    Image(systemName: keyIcon).foregroundStyle(keyColor)
                    Text(keyStatus)
                }
                SecureField("Paste a new API key", text: $keyInput)
                HStack {
                    Button("Save to Keychain") { save() }.disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(testing ? "Testing…" : "Test connection") { test() }.disabled(testing || coordinator.keyState != .present)
                    Spacer()
                    Button("Remove key", role: .destructive) {
                        try? coordinator.removeAPIKey()
                        message = "Key removed from the Keychain."
                    }.disabled(coordinator.keyState != .present)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Link("Create a key in Mistral AI Studio", destination: URL(string: "https://console.mistral.ai/api-keys")!)
                Text("The key is stored only in your macOS Keychain and sent only to Mistral's API over TLS. Testing calls GET /v1/models and sends no audio or text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var keyStatus: String {
        switch coordinator.keyState {
        case .loading: return "Reading Keychain…"
        case .missing: return "No key stored"
        case .present: return "Key stored in Keychain"
        case .denied(let reason): return "Keychain: \(reason)"
        }
    }
    private var keyIcon: String { coordinator.keyState == .present ? "checkmark.seal.fill" : "key" }
    private var keyColor: Color { coordinator.keyState == .present ? .green : .orange }

    private func save() {
        let candidate = keyInput
        testing = true
        Task {
            let result = await coordinator.testAPIKey(candidate)
            testing = false
            switch result {
            case .success:
                do {
                    try coordinator.saveAPIKey(candidate)
                    keyInput = ""
                    message = "Saved. Key verified with Mistral."
                } catch { message = "Couldn't save: \(error)" }
            case .failure(let error):
                message = "Not saved — \(error.userMessage)"
            }
        }
    }

    private func test() {
        testing = true
        Task {
            let result = await coordinator.testAPIKey()
            testing = false
            switch result {
            case .success(let models):
                let voxtral = models.filter { $0.contains("voxtral") }.count
                message = "Connected. \(models.count) models available (\(voxtral) Voxtral)."
            case .failure(let error): message = error.userMessage
            }
        }
    }
}

// MARK: - Privacy

struct PrivacySettings: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var settings: SettingsStore
    @State private var confirmDeleteAll = false

    var body: some View {
        Form {
            Section("What leaves your Mac") {
                ForEach(PrivacyManager.dataFlows(settings: settings)) { flow in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flow.what).fontWeight(.medium)
                        Text("→ \(flow.destination)").font(.caption)
                        Text(flow.when).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Smart formatting (sends transcripts to a language model)",
                       isOn: Binding(get: { settings.formattingMode == .smart }, set: { settings.formattingMode = $0 ? .smart : .raw }))
            }
            Section("Never sent") {
                ForEach(PrivacyManager.neverSent, id: \.self) { Label($0, systemImage: "xmark.shield").font(.callout) }
            }
            Section("Stored on this Mac") {
                ForEach(PrivacyManager.localStorage, id: \.self) { Label($0, systemImage: "internaldrive").font(.callout) }
                Toggle("Keep local transcript history", isOn: $settings.historyEnabled)
                if settings.historyEnabled {
                    Stepper("Delete history after \(settings.historyRetentionDays) days", value: $settings.historyRetentionDays, in: 1...365)
                }
                Text("Turning history off deletes the history file immediately.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Retention and training at Mistral") {
                Text(PrivacyManager.retentionNotice).font(.callout)
                Text(PrivacyManager.trainingNotice).font(.callout)
                Label(PrivacyManager.previewNotice, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                ForEach(PrivacyManager.links) { link in Link(link.title, destination: link.url) }
            }
            Section {
                Button("Delete all Le Blab data on this Mac…", role: .destructive) { confirmDeleteAll = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete history, settings and the stored API key?", isPresented: $confirmDeleteAll) {
            Button("Delete everything", role: .destructive) { coordinator.deleteAllLocalData() }
        }
    }
}

// MARK: - History

struct HistorySettings: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var history: HistoryStore
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !settings.historyEnabled {
                ContentUnavailableView {
                    Label("History is off", systemImage: "clock.badge.xmark")
                } description: {
                    Text("By default Le Blab keeps no record of what you dictate. Turn on local-only history to review past transcripts.")
                } actions: {
                    Button("Turn on local history") { settings.historyEnabled = true }
                }
            } else {
                HStack {
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                    Button("Clear history", role: .destructive) { history.clear() }.disabled(history.entries.isEmpty)
                }
                List(filtered) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).textSelection(.enabled)
                        HStack {
                            Text(entry.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                            if let language = entry.language { Text(language.uppercased()).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                            }.buttonStyle(.borderless)
                            Button(role: .destructive) { history.delete(entry.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
    }

    private var filtered: [HistoryEntry] {
        query.isEmpty ? history.entries : history.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }
}

// MARK: - Diagnostics

struct DiagnosticsSettings: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var diagnostics: DiagnosticsService
    @EnvironmentObject var permissions: PermissionsManager
    @EnvironmentObject var settings: SettingsStore
    @State private var connection: String?
    @State private var phrase = "Hey David, I just wanted to check if we can move the meeting to Friday at four."

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Microphone", value: permissions.microphone.rawValue)
                LabeledContent("Accessibility", value: permissions.accessibility.rawValue)
                LabeledContent("Shortcut", value: "\(settings.hotkey.displayString) via \(coordinator.hotkeyBackend.rawValue)")
                LabeledContent("API key", value: coordinator.keyState == .present ? "present" : "missing")
                LabeledContent("Endpoint", value: MistralAPI.realtimeURL(region: settings.region, model: MistralAPI.Models.realtime).absoluteString)
                HStack {
                    Button("Test connection") {
                        connection = "Testing…"
                        Task {
                            let start = Date()
                            let result = await coordinator.testAPIKey()
                            let ms = Int(Date().timeIntervalSince(start) * 1000)
                            switch result {
                            case .success: connection = "OK — \(ms) ms round trip"
                            case .failure(let e): connection = e.userMessage
                            }
                        }
                    }
                    if let connection { Text(connection).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Latency (last \(diagnostics.summary.count) successful dictations)") {
                let s = diagnostics.summary
                LabeledContent("Key press → first partial (p50)", value: DiagnosticsService.format(s.firstPartialP50))
                LabeledContent("Release → final transcript (p50)", value: DiagnosticsService.format(s.releaseToFinalP50))
                LabeledContent("Release → text inserted (p50 / p90)",
                               value: "\(DiagnosticsService.format(s.releaseToInsertP50)) / \(DiagnosticsService.format(s.releaseToInsertP90))")
                LabeledContent("Mistral API time (p50)", value: DiagnosticsService.format(s.apiLatencyP50))
            }
            Section("Pipeline self-test") {
                TextField("Phrase", text: $phrase)
                HStack {
                    Button(coordinator.selfTestRunning ? "Running…" : "Run with synthesized speech") {
                        Task { await coordinator.runSelfTest(phrase: phrase, outputPath: nil, quitAfter: false) }
                    }.disabled(coordinator.selfTestRunning || coordinator.keyState != .present)
                    Text("Speaks the phrase with macOS's voice in memory, streams it through Voxtral and inserts the result into the focused app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Recent dictations (timings only — no content)") {
                if diagnostics.recent.isEmpty { Text("No dictations yet.").foregroundStyle(.secondary) }
                ForEach(diagnostics.recent) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(m.date.formatted(date: .omitted, time: .standard)) · \(m.outcome) · \(String(format: "%.1f", m.audioSeconds)) s audio · \(m.characters) chars")
                            .font(.caption.weight(.medium))
                        Text("connect \(DiagnosticsService.format(m.connect)) · first partial \(DiagnosticsService.format(m.firstPartial)) · release→final \(DiagnosticsService.format(m.releaseToFinal)) · format \(DiagnosticsService.format(m.formattingTime)) · release→insert \(DiagnosticsService.format(m.releaseToInsert))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Text("\(m.source?.rawValue ?? "-") · \(m.formatting) · \(m.insertion ?? "-")" + (m.reconnects > 0 ? " · \(m.reconnects) reconnect(s)" : ""))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if !diagnostics.recent.isEmpty { Button("Clear") { diagnostics.clear() } }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }
}
