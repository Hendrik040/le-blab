import AppKit
import Combine
import LeBlabCore
import ServiceManagement
import SwiftUI

/// Thread-safe in-memory cache of the API key (read once from the Keychain).
final class APIKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func get() -> String? { lock.withLock { value } }
    func set(_ key: String?) { lock.withLock { value = key } }
}

/// Thread-safe mirror of the selected region for `@Sendable` network closures.
final class RegionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MistralAPI.Region = .global
    func get() -> MistralAPI.Region { lock.withLock { value } }
    func set(_ region: MistralAPI.Region) { lock.withLock { value = region } }
}

/// Wires the modules together: hotkey → DictationController → overlay/menu, plus settings,
/// permissions, Keychain and windows.
@MainActor
final class AppCoordinator: ObservableObject, DictationEnvironment {
    static let shared = AppCoordinator()

    enum KeyState: Equatable { case loading, missing, present, denied(String) }

    let settings = SettingsStore()
    let permissions = PermissionsManager()
    let diagnostics = DiagnosticsService()
    let history: HistoryStore
    let hotkeys = HotkeyManager()
    let insertion = TextInsertionService()
    let controller: DictationController
    let keychain = KeychainStore()
    private(set) lazy var overlay = OverlayController(coordinator: self)
    private(set) lazy var windows = WindowManager(coordinator: self)

    @Published private(set) var keyState: KeyState = .loading
    @Published private(set) var hotkeyBackend: HotkeyManager.Backend = .none
    @Published private(set) var hotkeyError: String?
    @Published var selfTestRunning = false

    private let keyCache = APIKeyCache()
    private let regionBox = RegionBox()
    private let micCapture = AudioCaptureManager()
    private var cancellables = Set<AnyCancellable>()
    private var syntheticMicrophone = false

    private init() {
        history = HistoryStore(enabled: settings.historyEnabled)
        let keyCache = self.keyCache
        let regionBox = self.regionBox
        regionBox.set(settings.region)
        let streaming = VoxtralRealtimeTranscriber(region: { regionBox.get() }, apiKey: { keyCache.get() })
        let batch = VoxtralBatchTranscriber(region: { regionBox.get() }, apiKey: { keyCache.get() })
        controller = DictationController(audio: micCapture, streaming: streaming, batch: batch, inserter: insertion)
        controller.environment = self
    }

    var needsAttention: Bool {
        keyState == .missing || permissions.microphone == .denied || permissions.accessibility != .granted || hotkeyBackend == .none
    }

    // MARK: - Lifecycle

    func launch() {
        Log.app.info("Le Blab launching")
        if let dir = SelfTest.value(after: "--render-assets") {
            AssetRenderer.run(into: dir)
            NSApp.terminate(nil)
            return
        }
        if let statusPath = SelfTest.value(after: "--status-output") {
            // Diagnostics-only instance: report permission state, then quit without registering anything.
            // (Doesn't touch the Keychain, so it never triggers an access prompt.)
            Task {
                permissions.refresh()
                let status = "accessibility=\(permissions.accessibility.rawValue) microphone=\(permissions.microphone.rawValue)"
                try? status.write(toFile: statusPath, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        history.retentionDays = settings.historyRetentionDays
        applySettings()
        observeSettings()
        loadAPIKey()

        permissions.onAccessibilityChange = { [weak self] _ in self?.activateHotkey() }
        hotkeys.onEvent = { [weak self] event in self?.controller.handle(event) }
        activateHotkey()

        controller.$state.removeDuplicates().sink { [weak self] state in
            self?.overlay.update(state: state)
        }.store(in: &cancellables)
        controller.$isRecording.removeDuplicates().sink { [weak self] recording in
            self?.hotkeys.setCancelActive(recording)
        }.store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissions.refresh() }
        }

        if let phrase = SelfTest.requestedPhrase() {
            Task { await runSelfTest(phrase: phrase, outputPath: SelfTest.requestedOutputPath(), quitAfter: true) }
            return
        }
        if !settings.hasCompletedOnboarding || keyState == .missing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                if !self.settings.hasCompletedOnboarding { self.windows.showOnboarding() }
            }
        }
    }

    func shutdown() {
        hotkeys.deactivate()
        controller.cancel(showHint: nil, silent: true)
    }

    private func applySettings() {
        insertion.method = settings.insertionMethod
        insertion.restoreClipboard = settings.restoreClipboard
        regionBox.set(settings.region)
    }

    private func observeSettings() {
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applySettings() }
        }.store(in: &cancellables)
        settings.$hotkey.dropFirst().removeDuplicates().sink { [weak self] combo in
            DispatchQueue.main.async { self?.activateHotkey(combo) }
        }.store(in: &cancellables)
        settings.$historyEnabled.dropFirst().removeDuplicates().sink { [weak self] enabled in
            self?.history.isEnabled = enabled
        }.store(in: &cancellables)
        settings.$historyRetentionDays.dropFirst().sink { [weak self] days in
            self?.history.retentionDays = days
        }.store(in: &cancellables)
    }

    func activateHotkey(_ combo: KeyCombo? = nil) {
        permissions.refresh()
        let backend = hotkeys.activate(combo ?? settings.hotkey, accessibilityTrusted: permissions.accessibility == .granted)
        hotkeyBackend = backend
        hotkeyError = hotkeys.registrationError
    }

    // MARK: - API key

    func loadAPIKey() {
        // Test-only: automated self-tests may pass the key via the environment so rebuilt dev
        // binaries don't trigger a Keychain prompt each time. Normal launches use the Keychain only.
        if SelfTest.requestedPhrase() != nil, let key = ProcessInfo.processInfo.environment["MISTRAL_API_KEY"], !key.isEmpty {
            keyCache.set(key)
            keyState = .present
            return
        }
        keyState = .loading
        let keychain = self.keychain
        Task.detached(priority: .userInitiated) {
            let result: Result<String?, Error> = Result { try keychain.readMigratingLegacy() }
            await MainActor.run {
                switch result {
                case .success(let key?):
                    self.keyCache.set(key)
                    self.keyState = .present
                case .success(nil):
                    self.keyCache.set(nil)
                    self.keyState = .missing
                case .failure(let error):
                    self.keyCache.set(nil)
                    self.keyState = .denied(String(describing: error))
                }
            }
        }
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try keychain.save(trimmed)
        keyCache.set(trimmed)
        keyState = .present
    }

    func removeAPIKey() throws {
        try keychain.delete()
        keyCache.set(nil)
        keyState = .missing
    }

    func testAPIKey(_ candidate: String? = nil) async -> Result<[String], TranscriptionError> {
        guard let key = candidate ?? keyCache.get() else { return .failure(.missingAPIKey) }
        return await MistralAPI.verifyKey(key, region: settings.region)
    }

    // MARK: - DictationEnvironment

    var apiKeyAvailable: Bool { keyCache.get() != nil }
    var microphoneAuthorized: Bool {
        if syntheticMicrophone { return true }
        permissions.refresh()
        return permissions.microphone == .granted
    }
    func requestMicrophoneAccess() async -> Bool { await permissions.requestMicrophone() }
    func sessionOptions(turnDetection: Bool) -> SessionOptions { settings.sessionOptions(turnDetection: turnDetection) }
    var activationMode: ActivationMode { settings.activationMode }
    var autoStopOnSilence: Bool { settings.autoStopOnSilence }
    var inputDeviceUID: String? { settings.inputDeviceUID }
    var shortcutLabel: String { settings.hotkey.displayString }
    var activationFeedbackDelay: TimeInterval { settings.hotkey.needsChordDebounce && !syntheticMicrophone ? 0.2 : 0 }
    var formattingLabel: String { "smart (\(settings.formatterModel))" }

    func makeFormatter() -> TranscriptFormatting {
        switch settings.formattingMode {
        case .raw:
            return RawFormatter(vocabulary: VocabularyCorrector(entries: settings.vocabulary))
        case .smart:
            let keyCache = self.keyCache, regionBox = self.regionBox
            let client = MistralChatClient(region: { regionBox.get() }, apiKey: { keyCache.get() })
            return SmartFormatter(client: client, model: settings.formatterModel, vocabulary: settings.vocabulary)
        }
    }

    func recordingDidStart() {
        if settings.playSounds { Sounds.play(.start) }
        if settings.formattingMode == .smart || settings.quality == .accurate { MistralAPI.warmUp(region: settings.region) }
    }

    func recordingDidStop(cancelled: Bool) {
        if settings.playSounds { Sounds.play(cancelled ? .cancel : .stop) }
    }

    func record(history entry: HistoryEntry) { history.append(entry) }

    func record(metrics: DictationMetrics) {
        diagnostics.record(metrics)
        if metrics.outcome.hasPrefix("error") { diagnostics.recordError(metrics.outcome) }
    }

    // MARK: - Actions

    func copyLastTranscript() {
        guard let text = controller.lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func pasteLastTranscript() {
        guard let text = controller.lastTranscript else { return }
        Task { _ = await insertion.insert(text) }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.app.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
            }
            objectWillChange.send()
        }
    }

    /// Wipes everything Le Blab stores locally: history, settings and the Keychain item.
    func deleteAllLocalData() {
        history.clear()
        diagnostics.clear()
        try? removeAPIKey()
        settings.resetToDefaults()
    }

    // MARK: - Self-test (synthesized speech through the full pipeline)

    func runSelfTest(phrase: String, outputPath: String?, quitAfter: Bool) async {
        guard !selfTestRunning else { return }
        selfTestRunning = true
        defer { selfTestRunning = false }
        // Wait for the Keychain read.
        for _ in 0..<300 where keyState == .loading { try? await Task.sleep(nanoseconds: 100_000_000) }
        let report = await SelfTest.run(phrase: phrase, coordinator: self)
        if let outputPath { try? report.write(toFile: outputPath, atomically: true, encoding: .utf8) }
        if quitAfter {
            try? await Task.sleep(nanoseconds: 800_000_000)
            NSApp.terminate(nil)
        }
    }

    /// Swaps the microphone for an in-memory audio source for the duration of `body`.
    func withSyntheticMicrophone(_ source: AudioCapturing, _ body: () async -> Void) async {
        let original = controller.audio
        controller.audio = source
        syntheticMicrophone = true
        await body()
        controller.audio = original
        syntheticMicrophone = false
    }
}

enum Sounds {
    enum Cue { case start, stop, cancel }
    private static let cache: [Cue: NSSound] = {
        var c: [Cue: NSSound] = [:]
        if let s = NSSound(named: "Tink") { s.volume = 0.25; c[.start] = s }
        if let s = NSSound(named: "Pop") { s.volume = 0.25; c[.stop] = s }
        if let s = NSSound(named: "Bottle") { s.volume = 0.2; c[.cancel] = s }
        return c
    }()

    static func play(_ cue: Cue) {
        guard let sound = cache[cue] else { return }
        sound.stop()
        sound.play()
    }
}
