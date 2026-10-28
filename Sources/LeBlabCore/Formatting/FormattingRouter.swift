import Foundation

/// Decides whether a transcript needs the language model at all.
///
/// Voxtral 3 already returns punctuation and capitalization, so many dictations are finished text.
/// The model is only worth its 0.4–1.5 s round-trip when there is something it uniquely does:
/// self-corrections, enumerations, spoken punctuation/URLs, spelled-out numbers, stutters, or long
/// multi-topic dictation. Simple fillers ("um", "äh") are removed locally. When unsure, route to the
/// model — a false "needs model" only costs time, a false "clean" would skip a needed fix.
public enum FormattingRouter {
    public enum Decision: Equatable, Sendable {
        case local(reason: String)
        case languageModel(reason: String)

        public var needsLanguageModel: Bool {
            if case .languageModel = self { return true }
            return false
        }
    }

    public static let maxLocalWords = 60

    public static func decide(_ transcript: String) -> Decision {
        let text = transcript.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count > maxLocalWords { return .languageModel(reason: "long dictation") }
        for (reason, regex) in cues where regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return .languageModel(reason: reason)
        }
        if words.count > 12, !text.contains(where: { ".,?!;:".contains($0) }) {
            return .languageModel(reason: "no punctuation")
        }
        // German "um," is either a hesitation or the preposition before an aside — only the model can tell.
        if LanguageGuess.isGerman(text, hint: nil), germanUmComma.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return .languageModel(reason: "ambiguous um")
        }
        return .local(reason: "clean transcript")
    }

    private static func pattern(_ alternatives: [String]) -> NSRegularExpression {
        let body = alternatives.joined(separator: "|")
        return try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(?:"# + body + #")(?![\p{L}\p{N}])"#)
    }

    private static let germanUmComma = try! NSRegularExpression(pattern: #"(?<![\p{L}])um[,.]"#)

    private static let smallNumber = "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|eins|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|elf|zwölf)"

    private static let cues: [(String, NSRegularExpression)] = [
        ("self-correction", pattern([
            "actually", "i mean", "i meant", "no wait", "wait", "oh wait", "sorry", "scratch that", "make that", "make it",
            "or rather", "rather", "instead", "correction", "let me rephrase", "strike that", "never mind", "forget that",
            "ignore that",
            "nein", "ich meine", "ich mein", "meine ich", "doch", "beziehungsweise", "bzw", "lieber", "vielmehr", "korrektur",
            "korrigiere", "quatsch", "ach nee", "ach ne", "streich das", "vergiss das", "besser gesagt", "genauer gesagt",
            "moment",
        ])),
        ("mid-sentence no", try! NSRegularExpression(pattern: #"[,.;?!—–]\s*(?:no|nee|ne)(?![\p{L}])"#)),
        // A hesitation set off by commas often precedes a correction without a cue word ("Maria, uh, Marta").
        ("hesitation", try! NSRegularExpression(pattern: #",\s*(?:u+h+m*|u+m+|e+r+m*|ä+h+m*|ö+h+m*)\s*,"#)),
        ("spelled-out time", try! NSRegularExpression(pattern:
            #"(?<![\p{L}])(?:at|by|around|until|from|um|gegen|ab|bis)\s+"# + smallNumber + #"(?![\p{L}])"#)),
        ("number with unit", try! NSRegularExpression(pattern: #"(?<![\p{L}])"# + smallNumber
            + #"\s+(?:a\.?m\.?|p\.?m\.?|o'clock|uhr|percent|per cent|prozent|euros?|dollars?|bucks|minutes?|hours?|stunden|minuten|days?|tage|weeks?|wochen)(?![\p{L}])"#)),
        ("german clock time", pattern(["halb", "viertel vor", "viertel nach", "dreiviertel"])),
        ("enumeration", pattern([
            "first(?:ly)?", "second(?:ly)?", "third(?:ly)?", "fourth(?:ly)?", "number one", "number two", "bullet point",
            "erstens", "zweitens", "drittens", "viertens", "punkt eins", "aufzählung",
        ])),
        ("spoken layout", pattern([
            "new ?line", "new paragraph", "line break", "comma", "full stop", "question mark", "exclamation (?:mark|point)",
            "colon", "semicolon", "open quote", "close quote", "open bracket", "close bracket",
            "neue zeile", "neuer absatz", "absatz", "zeilenumbruch", "komma", "fragezeichen", "ausrufezeichen",
            "doppelpunkt", "semikolon", "anführungszeichen",
        ])),
        ("spoken url/file", pattern([
            "dot", "slash", "backslash", "underscore", "at sign", "hashtag", "dash", "hyphen", "punkt", "schrägstrich",
            "unterstrich", "bindestrich",
        ])),
        ("spelled-out number", pattern([
            "percent", "per cent", "hundred", "thousand", "million", "billion", "o'clock",
            "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
            "prozent", "hundert", "tausend", "millionen?", "milliarden?", "zwanzig", "dreißig", "vierzig", "fünfzig",
            "sechzig", "siebzig", "achtzig", "neunzig",
        ])),
        ("filler phrase", pattern(["you know", "kind of like", "sort of like", "sozusagen", "quasi", "irgendwie"])),
        ("stutter", try! NSRegularExpression(pattern: #"(?<![\p{L}])(\p{L}{2,})[\s,]+\1(?![\p{L}])"#)),
    ]
}
