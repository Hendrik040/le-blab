import Foundation

/// Word error rate for benchmark scoring: (substitutions + deletions + insertions) / reference words,
/// after a normalization that is applied identically to reference and hypothesis, so formatting
/// choices ("4 PM" vs "four p.m.", "speech-to-text" vs "speech to text", "let's" vs "let us")
/// don't count as recognition errors. Compound/split differences ("code rabbit" vs "coderabbit")
/// deliberately stay errors — vocabulary is scored separately.
public enum WordErrorRate {
    public struct Result: Equatable, Sendable {
        public let wer: Double
        public let referenceWords: Int
        public let substitutions: Int
        public let deletions: Int
        public let insertions: Int
        public var errors: Int { substitutions + deletions + insertions }
    }

    /// Lowest WER across several accepted references (verbatim, intended, format variants).
    public static func best(references: [String], hypothesis: String, language: String = "en") -> Result {
        references.map { compute(reference: $0, hypothesis: hypothesis, language: language) }
            .min { $0.wer < $1.wer } ?? compute(reference: "", hypothesis: hypothesis, language: language)
    }

    public static func compute(reference: String, hypothesis: String, language: String = "en") -> Result {
        let ref = normalize(reference, language: language), hyp = normalize(hypothesis, language: language)
        guard !ref.isEmpty else {
            return Result(wer: hyp.isEmpty ? 0 : 1, referenceWords: 0, substitutions: 0, deletions: 0, insertions: hyp.count)
        }
        struct Cell { var cost: Int; var s: Int; var d: Int; var i: Int }
        var prev = (0...hyp.count).map { Cell(cost: $0, s: 0, d: 0, i: $0) }
        for (ri, r) in ref.enumerated() {
            var row = [Cell(cost: ri + 1, s: 0, d: ri + 1, i: 0)]
            for (hi, h) in hyp.enumerated() {
                let diag = prev[hi], up = prev[hi + 1], left = row[hi]
                if r == h {
                    row.append(diag)
                } else {
                    let options = [
                        Cell(cost: diag.cost + 1, s: diag.s + 1, d: diag.d, i: diag.i),
                        Cell(cost: up.cost + 1, s: up.s, d: up.d + 1, i: up.i),
                        Cell(cost: left.cost + 1, s: left.s, d: left.d, i: left.i + 1),
                    ]
                    row.append(options.min { $0.cost < $1.cost }!)
                }
            }
            prev = row
        }
        let end = prev[hyp.count]
        return Result(wer: Double(end.cost) / Double(ref.count), referenceWords: ref.count,
                      substitutions: end.s, deletions: end.d, insertions: end.i)
    }

    public static func normalize(_ text: String, language: String = "en") -> [String] {
        let german = language.hasPrefix("de")
        var t = text.precomposedStringWithCompatibilityMapping.lowercased()
        for (a, b) in [("’", "'"), ("‘", "'"), ("‚", "'"), ("“", "\""), ("”", "\""), ("„", "\""), ("–", " "), ("—", " "), ("ß", "ss")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.replacingOccurrences(of: "%", with: " percent ")
        t = t.replacingOccurrences(of: "€", with: " euro ")
        t = t.replacingOccurrences(of: #"(\d{1,2}):00\b"#, with: "$1", options: .regularExpression)       // 4:00 → 4
        t = t.replacingOccurrences(of: #"(?<=\d)[.,](?=\d{3}\b)"#, with: "", options: .regularExpression) // 3,000 → 3000
        t = t.replacingOccurrences(of: #"(\d)\s*([ap])\.?\s?m\.?(?![a-z])"#, with: "$1 $2m", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b([ap])\.\s?m\.?"#, with: "$1m", options: .regularExpression)
        for (from, to) in contractions { t = t.replacingOccurrences(of: from, with: to) }

        // Hyphens, slashes and all other punctuation separate words.
        var tokens = t.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let fillers = german ? germanFillers : englishFillers
        tokens = tokens.filter { !fillers.contains($0) }
        tokens = tokens.map { variants[$0] ?? $0 }
        return combineNumbers(tokens.map { numberWords[$0] ?? $0 })
    }

    /// "20" "1" (from "twenty-one") → "21".
    static func combineNumbers(_ tokens: [String]) -> [String] {
        var out: [String] = []
        for token in tokens {
            if let unit = Int(token), (1...9).contains(unit), let last = out.last, let tens = Int(last),
               tens >= 20, tens <= 90, tens % 10 == 0, token.count == 1 {
                out[out.count - 1] = String(tens + unit)
            } else {
                out.append(token)
            }
        }
        return out
    }

    static let englishFillers: Set<String> = ["um", "uh", "uhm", "erm", "hmm", "hm", "äh", "ähm", "öh"]
    /// "um" is a real German word ("um vier Uhr"), so it is never dropped in German.
    static let germanFillers: Set<String> = ["äh", "ähm", "öh", "öhm", "hm", "hmm", "uh", "erm"]

    static let contractions: [(String, String)] = [
        ("let's", "let us"), ("i'm", "i am"), ("don't", "do not"), ("can't", "can not"), ("cannot", "can not"),
        ("won't", "will not"), ("it's", "it is"), ("we're", "we are"), ("you're", "you are"), ("they're", "they are"),
        ("that's", "that is"), ("what's", "what is"), ("there's", "there is"), ("i've", "i have"), ("i'll", "i will"),
        ("i'd", "i would"), ("isn't", "is not"), ("aren't", "are not"), ("didn't", "did not"), ("doesn't", "does not"),
        ("we'll", "we will"), ("you'll", "you will"), ("gibt's", "gibt es"), ("geht's", "geht es"), ("wie's", "wie es"),
    ]

    static let variants: [String: String] = ["okay": "ok", "email": "email", "e": "e", "alright": "all right"]

    static let numberWords: [String: String] = {
        var m: [String: String] = [:]
        let en = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                  "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        for (i, w) in en.enumerated() { m[w] = String(i) }
        for (w, v) in [("twenty", 20), ("thirty", 30), ("forty", 40), ("fifty", 50), ("sixty", 60), ("seventy", 70),
                       ("eighty", 80), ("ninety", 90), ("hundred", 100)] { m[w] = String(v) }
        let deUnits = ["null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn", "elf", "zwölf",
                       "dreizehn", "vierzehn", "fünfzehn", "sechzehn", "siebzehn", "achtzehn", "neunzehn"]
        for (i, w) in deUnits.enumerated() { m[w] = String(i) }
        m["ein"] = nil
        let deTens = [("zwanzig", 20), ("dreißig", 30), ("dreissig", 30), ("vierzig", 40), ("fünfzig", 50), ("sechzig", 60),
                      ("siebzig", 70), ("achtzig", 80), ("neunzig", 90), ("hundert", 100)]
        let deCompound = ["ein", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun"]
        for (w, v) in deTens {
            m[w] = String(v)
            if v < 100 { for (u, unit) in deCompound.enumerated() { m[unit + "und" + w] = String(v + u + 1) } }
        }
        return m
    }()
}
