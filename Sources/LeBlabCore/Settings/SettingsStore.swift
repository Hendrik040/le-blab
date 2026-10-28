import Combine
import Foundation

public enum ActivationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case holdToTalk, toggle
    public var id: String { rawValue }
    public var displayName: String { self == .holdToTalk ? "Hold to talk" : "Press to start, press again to stop" }
}

public enum TranscriptionQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Voxtral Mini Transcribe Realtime 3 — streaming, lowest latency.
    case fast
    /// Voxtral Small Transcribe 3 — batch on release, live preview still via realtime.
    case accurate
    public var id: String { rawValue }
    public var displayName: String { self == .fast ? "Fast — Voxtral Mini Transcribe Realtime 3" : "Accurate — Voxtral Small Transcribe 3" }
    public var shortName: String { self == .fast ? "Mini Realtime 3" : "Small Transcribe 3" }
}

public struct LanguageOption: Identifiable, Hashable, Sendable {
    public let code: String   // "auto" or ISO-639-1
    public var id: String { code }
    public var displayName: String {
        code == "auto" ? "Automatic" : (Locale.current.localizedString(forLanguageCode: code) ?? code)
    }
    public static let all: [LanguageOption] = ["auto", "en", "de", "fr", "es", "it", "pt", "nl", "pl", "sv", "da", "no", "fi",
                                               "cs", "ro", "hu", "el", "tr", "ru", "uk", "ar", "hi", "ja", "ko", "zh"]
        .map(LanguageOption.init(code:))
}

/// User preferences, persisted in UserDefaults. Secrets live in `KeychainStore`, never here.
@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var activationMode: ActivationMode { didSet { save(activationMode, "activationMode") } }
    @Published public var hotkey: KeyCombo { didSet { save(hotkey, "hotkey") } }
    @Published public var quality: TranscriptionQuality { didSet { save(quality, "quality") } }
    /// 80–1200 or 2400 ms (Voxtral 3 realtime range).
    @Published public var streamingDelayMs: Int { didSet { save(streamingDelayMs, "streamingDelayMs") } }
    @Published public var language: String { didSet { save(language, "language") } }
    @Published public var formattingMode: FormattingMode { didSet { save(formattingMode, "formattingMode") } }
    @Published public var formatterModel: String { didSet { save(formatterModel, "formatterModel") } }
    /// Smart mode: skip the language model when the transcript needs nothing it can uniquely fix.
    @Published public var skipCleanTranscripts: Bool { didSet { save(skipCleanTranscripts, "skipCleanTranscripts") } }
    /// Smart mode in native apps: insert cleaned text immediately, swap in the polished version after.
    @Published public var optimisticInsert: Bool { didSet { save(optimisticInsert, "optimisticInsert") } }
    /// Smart mode in apps that can't be edited in place (browsers, Slack, Electron): paste the locally
    /// cleaned text right away instead of waiting for the language model.
    @Published public var speedFirstInPasteApps: Bool { didSet { save(speedFirstInPasteApps, "speedFirstInPasteApps") } }
    @Published public var vocabulary: [VocabularyEntry] { didSet { save(vocabulary, "vocabulary") } }
    @Published public var region: MistralAPI.Region { didSet { save(region, "region") } }
    @Published public var insertionMethod: InsertionMethod { didSet { save(insertionMethod, "insertionMethod") } }
    @Published public var restoreClipboard: Bool { didSet { save(restoreClipboard, "restoreClipboard") } }
    @Published public var playSounds: Bool { didSet { save(playSounds, "playSounds") } }
    @Published public var showLivePreview: Bool { didSet { save(showLivePreview, "showLivePreview") } }
    /// Small always-on bubble at the bottom of the screen that reacts instantly to the shortcut.
    @Published public var showIdleBubble: Bool { didSet { save(showIdleBubble, "showIdleBubble") } }
    /// Toggle mode only: stop when Voxtral's turn detection says the speaker is done.
    @Published public var autoStopOnSilence: Bool { didSet { save(autoStopOnSilence, "autoStopOnSilence") } }
    @Published public var inputDeviceUID: String? { didSet { save(inputDeviceUID, "inputDeviceUID") } }
    /// Off by default. When off, no transcript is ever written to disk.
    @Published public var historyEnabled: Bool { didSet { save(historyEnabled, "historyEnabled") } }
    @Published public var historyRetentionDays: Int { didSet { save(historyRetentionDays, "historyRetentionDays") } }
    @Published public var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, "hasCompletedOnboarding") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activationMode = Self.load(defaults, "activationMode") ?? .holdToTalk
        hotkey = Self.load(defaults, "hotkey") ?? .controlShift
        quality = Self.load(defaults, "quality") ?? .fast
        streamingDelayMs = Self.load(defaults, "streamingDelayMs") ?? 240
        language = Self.load(defaults, "language") ?? "auto"
        formattingMode = Self.load(defaults, "formattingMode") ?? .smart
        formatterModel = Self.load(defaults, "formatterModel") ?? MistralAPI.Models.defaultFormatter
        skipCleanTranscripts = Self.load(defaults, "skipCleanTranscripts") ?? true
        optimisticInsert = Self.load(defaults, "optimisticInsert") ?? true
        speedFirstInPasteApps = Self.load(defaults, "speedFirstInPasteApps") ?? true
        vocabulary = Self.load(defaults, "vocabulary") ?? VocabularyEntry.defaults
        region = Self.load(defaults, "region") ?? .global
        insertionMethod = Self.load(defaults, "insertionMethod") ?? .automatic
        restoreClipboard = Self.load(defaults, "restoreClipboard") ?? true
        playSounds = Self.load(defaults, "playSounds") ?? true
        showLivePreview = Self.load(defaults, "showLivePreview") ?? true
        showIdleBubble = Self.load(defaults, "showIdleBubble") ?? true
        autoStopOnSilence = Self.load(defaults, "autoStopOnSilence") ?? false
        inputDeviceUID = Self.load(defaults, "inputDeviceUID") ?? nil
        historyEnabled = Self.load(defaults, "historyEnabled") ?? false
        historyRetentionDays = Self.load(defaults, "historyRetentionDays") ?? 30
        hasCompletedOnboarding = Self.load(defaults, "hasCompletedOnboarding") ?? false
    }

    public var languageCode: String? { language == "auto" ? nil : language }

    public static let streamingDelayChoices = [240, 480, 960, 1200, 2400]

    /// Everything the transcription layer needs for the next dictation.
    public func sessionOptions(turnDetection: Bool) -> SessionOptions {
        let realtime = TranscriptionConfig(model: MistralAPI.Models.realtime, language: languageCode,
                                           contextBias: VocabularyCorrector.biasTerms(vocabulary),
                                           targetStreamingDelayMs: streamingDelayMs, turnDetection: turnDetection)
        return SessionOptions(realtime: realtime,
                              accuracyModel: quality == .accurate ? MistralAPI.Models.smallBatch : nil)
    }

    public func resetToDefaults() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("leblab.") { defaults.removeObject(forKey: key) }
        let fresh = SettingsStore(defaults: defaults)
        activationMode = fresh.activationMode; hotkey = fresh.hotkey; quality = fresh.quality
        streamingDelayMs = fresh.streamingDelayMs; language = fresh.language; formattingMode = fresh.formattingMode
        formatterModel = fresh.formatterModel; vocabulary = fresh.vocabulary; region = fresh.region
        skipCleanTranscripts = fresh.skipCleanTranscripts; optimisticInsert = fresh.optimisticInsert
        speedFirstInPasteApps = fresh.speedFirstInPasteApps
        insertionMethod = fresh.insertionMethod; restoreClipboard = fresh.restoreClipboard; playSounds = fresh.playSounds
        showLivePreview = fresh.showLivePreview; showIdleBubble = fresh.showIdleBubble; autoStopOnSilence = fresh.autoStopOnSilence; inputDeviceUID = nil
        historyEnabled = false; historyRetentionDays = fresh.historyRetentionDays
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "leblab." + key) }
    }

    private static func load<T: Decodable>(_ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: "leblab." + key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
