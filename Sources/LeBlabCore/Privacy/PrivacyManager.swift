import Foundation

/// Single source of truth for what Le Blab sends where, shown verbatim in the Privacy settings.
/// Statements here were checked against Mistral's legal pages on 2026-10-21; keep them conservative.
public enum PrivacyManager {
    public struct Link: Identifiable, Hashable, Sendable {
        public let title: String
        public let url: URL
        public var id: String { url.absoluteString }
    }

    public static let links: [Link] = [
        Link(title: "Mistral Privacy Policy", url: URL(string: "https://legal.mistral.ai/terms/privacy-policy")!),
        Link(title: "Data Processing Addendum (DPA)", url: URL(string: "https://legal.mistral.ai/terms/data-processing-addendum")!),
        Link(title: "Commercial Terms of Service", url: URL(string: "https://legal.mistral.ai/terms/commercial-terms-of-service")!),
        Link(title: "Zero Data Retention (how to request)", url: URL(string: "https://docs.mistral.ai/admin/monitor-comply/zero-data-retention")!),
        Link(title: "Opting out of training on your data", url: URL(string: "https://help.mistral.ai/en/articles/455207-can-i-opt-out-of-my-input-or-output-data-being-used-for-training")!),
        Link(title: "Regional (EU/US) inference endpoints", url: URL(string: "https://docs.mistral.ai/inference/regional-inference")!),
    ]

    public struct DataFlow: Identifiable, Sendable {
        public let id: String
        public let what: String
        public let destination: String
        public let when: String
    }

    @MainActor
    public static func dataFlows(settings: SettingsStore) -> [DataFlow] {
        var flows = [
            DataFlow(id: "audio", what: "Microphone audio (only while you dictate)",
                     destination: "Mistral API — \(settings.region.displayName), \(settings.quality.shortName)",
                     when: "Streamed live over TLS while the shortcut is active"),
        ]
        if settings.quality == .accurate {
            flows.append(DataFlow(id: "audio-batch", what: "The same dictation's audio, once more",
                                  destination: "Mistral API — Voxtral Small Transcribe 3", when: "When you release the shortcut"))
        }
        if !settings.vocabulary.isEmpty {
            flows.append(DataFlow(id: "vocab", what: "Your custom vocabulary terms", destination: "Mistral API (context biasing)",
                                  when: "At the start of each dictation"))
        }
        if settings.formattingMode == .smart {
            flows.append(DataFlow(id: "llm", what: "The transcript text", destination: "Mistral API — \(settings.formatterModel)",
                                  when: "After each dictation, for cleanup"))
        }
        return flows
    }

    public static let neverSent: [String] = [
        "Text or content of other apps (the character next to the cursor is read locally for spacing only)",
        "App names, window titles, screenshots",
        "Analytics, telemetry or crash reports — Le Blab has none",
        "Audio or transcripts to any service other than Mistral",
    ]

    public static let localStorage: [String] = [
        "API key: macOS Keychain only",
        "Audio: memory only; zeroed after each dictation. No audio files are ever written",
        "Transcripts: memory only, unless you turn on local history (off by default)",
        "Logs: timings and error categories only, never transcript text or audio",
    ]

    public static let retentionNotice = """
    Mistral processes your audio remotely. Under Mistral's privacy policy, API inputs and outputs are kept for \
    30 rolling days for abuse monitoring unless Zero Data Retention (ZDR) has been approved for your organization. \
    ZDR is not on by default and must be requested from Mistral. Le Blab cannot see or change your account's retention \
    status, so it never claims zero retention.
    """

    public static let trainingNotice = """
    Model training and data retention are separate controls. Whether Mistral may train on your API data depends on \
    your plan and your organization's privacy setting in the Mistral admin console ("Anonymous improvement data"). \
    Turning off training does not shorten retention, and ZDR does not by itself change training terms.
    """

    public static let previewNotice = """
    Voxtral Mini Transcribe Realtime 3 is labelled "Public Preview" by Mistral. Mistral's commercial terms set \
    different data-use rules for preview models, and opt-outs (including ZDR) may not apply to them. If that matters \
    to you, confirm with Mistral before dictating sensitive content.
    """
}
