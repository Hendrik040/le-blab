import Foundation

/// A custom vocabulary term, optionally with phrases the recognizer tends to hear instead.
public struct VocabularyEntry: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var term: String
    /// Extra "sounds like" spellings, e.g. `vox trail` for `Voxtral`.
    public var aliases: [String]

    public init(term: String, aliases: [String] = []) {
        self.term = term
        self.aliases = aliases
    }

    public static let defaults: [VocabularyEntry] = [
        VocabularyEntry(term: "CodeRabbit"),
        VocabularyEntry(term: "DevRel"),
        VocabularyEntry(term: "GitHub"),
        VocabularyEntry(term: "Mistral"),
        VocabularyEntry(term: "Voxtral", aliases: ["vox trail", "vox tral", "voxtrel", "vox troll", "box troll"]),
    ]
}

/// Deterministic, conservative vocabulary fix-ups applied after recognition.
///
/// Voxtral 3 supports `context_bias`, which does most of the work at recognition time; this
/// catches the remaining case/spacing variants ("code rabbit", "github", "Dev Rel") without
/// touching partial words, URLs, e-mail addresses or paths.
public struct VocabularyCorrector: Sendable {
    private let rules: [(regex: NSRegularExpression, replacement: String)]

    public init(entries: [VocabularyEntry]) {
        var rules: [(NSRegularExpression, String)] = []
        var seen = Set<String>()
        // Longer variants first so "code rabbit ai" style aliases win over shorter ones.
        let pairs = entries.flatMap { entry -> [(String, String)] in
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return [] }
            var variants = entry.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if term.count >= 3 { variants.append(term) }
            return variants.map { ($0, term) }
        }.sorted { $0.0.count > $1.0.count }

        for (variant, term) in pairs {
            let key = variant.lowercased() + "→" + term
            guard seen.insert(key).inserted, let regex = Self.regex(for: variant) else { continue }
            rules.append((regex, NSRegularExpression.escapedTemplate(for: term)))
        }
        self.rules = rules
    }

    public func apply(_ text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.replacement)
        }
        return result
    }

    /// Terms to send as `context_bias`.
    public static func biasTerms(_ entries: [VocabularyEntry]) -> [String] {
        var seen = Set<String>()
        return entries.map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Splits a canonical term into speakable parts: "CodeRabbit" → ["Code", "Rabbit"], "GPT-4o" → ["GPT", "4o"].
    static func parts(of term: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let chars = Array(term)
        for (i, c) in chars.enumerated() {
            if c == " " || c == "-" || c == "_" {
                if !current.isEmpty { parts.append(current); current = "" }
                continue
            }
            if !current.isEmpty, c.isUppercase, let prev = current.last, prev.isLowercase {
                parts.append(current); current = ""
            } else if !current.isEmpty, c.isUppercase, i + 1 < chars.count, chars[i + 1].isLowercase,
                      let prev = current.last, prev.isUppercase {
                // "HTTPServer" → "HTTP", "Server"
                parts.append(current); current = ""
            }
            current.append(c)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func regex(for variant: String) -> NSRegularExpression? {
        let parts = parts(of: variant).map(NSRegularExpression.escapedPattern(for:))
        guard !parts.isEmpty else { return nil }
        // Parts may be joined by nothing, a space or a hyphen: "code rabbit", "coderabbit", "code-rabbit".
        let body = parts.joined(separator: #"[\s\-]?"#)
        // Not inside a larger word, not part of a URL/e-mail/path/domain.
        let pattern = #"(?<![\p{L}\p{N}_@/.\-])"# + body + #"(?![\p{L}\p{N}_]|\.[\p{L}\p{N}]|@|/)"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
