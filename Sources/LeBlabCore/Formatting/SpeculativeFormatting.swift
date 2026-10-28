import Foundation

/// Starts the formatting request before the final transcript exists.
///
/// The language model is the slowest step (0.4–1.5 s). Instead of waiting for Voxtral to finalize
/// and *then* asking the model, Le Blab asks it with the live text — at key release, and already
/// while the user pauses before releasing. When the final transcript matches that text (ignoring a
/// trailing period, which Voxtral adds last), the answer is reused, so the model's latency overlaps
/// transcription instead of following it. Only text that would go to the model anyway is sent.
@MainActor
public final class SpeculativeFormatting {
    private let formatter: TranscriptFormatting
    private var entries: [(key: String, task: Task<FormattedText, Never>)] = []
    public private(set) var requests = 0

    public init(formatter: TranscriptFormatting) {
        self.formatter = formatter
    }

    /// Comparison key: whitespace/case-insensitive, trailing sentence punctuation ignored.
    nonisolated static func key(_ text: String) -> String {
        var t = TranscriptAssembler.normalize(text).lowercased()
        while let last = t.last, ".!?…。".contains(last) || last == " " { t.removeLast() }
        return t
    }

    public func speculate(_ text: String, language: String?) {
        guard formatter.provisionalText(for: text, language: language) != nil else { return }   // model-bound text only
        let key = Self.key(text)
        guard !key.isEmpty, !entries.contains(where: { $0.key == key }) else { return }
        let formatter = self.formatter
        requests += 1
        entries.append((key, Task { await formatter.format(text, language: language) }))
        if entries.count > 3 { entries.removeFirst() }
    }

    /// The in-flight (or finished) request whose input matches `finalText`, if any.
    public func task(for finalText: String) -> Task<FormattedText, Never>? {
        let key = Self.key(finalText)
        return entries.last { $0.key == key }?.task
    }
}
