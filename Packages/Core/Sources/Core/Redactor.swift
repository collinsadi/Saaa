import Foundation

/// Deterministic local redaction for exports (issue #4): masks emails,
/// long number sequences (phones, cards, ids), and currency amounts.
/// Honest limits: it cannot catch names or secrets expressed in words —
/// the export sheet says so and the user reviews before sharing.
public enum Redactor {

    private static let patterns: [(NSRegularExpression, String)] = {
        func regex(_ pattern: String) -> NSRegularExpression {
            // Patterns are compile-time constants; a failure is a programmer
            // error caught by the unit tests.
            try! NSRegularExpression(pattern: pattern)
        }
        return [
            (regex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#), "[email]"),
            (regex(#"[$€£¥]\s?\d[\d,.]*"#), "[amount]"),
            (regex(#"(?<![\w.])\+?\d[\d\s().-]{5,}\d(?![\w.])"#), "[number]"),
        ]
    }()

    public static func redact(_ text: String) -> String {
        var result = text
        for (regex, replacement) in patterns {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return result
    }
}
