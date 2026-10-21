import Foundation

/// Adds the space a human would type when dictation lands right after/before existing words.
/// The surrounding characters are read locally via Accessibility and never leave the Mac.
public enum SpacingRules {
    private static let noSpaceAfter: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "-", "@", "#", "\t"]
    private static let noSpaceBefore: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "’", "\"", "”", "%"]

    public static func adjust(_ text: String, before: Character?, after: Character?) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        if let before, !before.isWhitespace, !noSpaceAfter.contains(before),
           let first = result.first, !first.isWhitespace, !noSpaceBefore.contains(first) {
            result = " " + result
        }
        if let after, after.isLetter || after.isNumber, let last = result.last, !last.isWhitespace {
            result += " "
        }
        return result
    }
}
