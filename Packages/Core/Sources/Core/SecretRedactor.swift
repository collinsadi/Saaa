import Foundation

/// Masks secrets in text read from a screen before it leaves the Mac: API
/// keys and tokens by their known shapes, private-key blocks, passwords in
/// URLs, and values assigned to secret-looking names. A safety net, not a
/// guarantee: the live panel shows exactly what was sent.
public enum SecretRedactor {

    public static let placeholder = "[secret]"

    private struct Rule {
        let regex: NSRegularExpression
        /// Replacement template; `$1` and `$2` keep a matched prefix and suffix.
        let template: String
    }

    private static let rules: [Rule] = {
        // Patterns are compile-time constants; a failure is a programmer
        // error caught by the unit tests.
        func rule(_ pattern: String, _ template: String = placeholder, caseInsensitive: Bool = false) -> Rule {
            let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
            return Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), template: template)
        }
        let kept = "$1\(placeholder)$2"
        return [
            // PEM private keys, to the END line or the end of the text.
            rule(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#),
            // Known token shapes.
            rule(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
            rule(#"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}"#),
            rule(#"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#),
            rule(#"\bgithub_pat_[A-Za-z0-9_]{22,}\b"#),
            rule(#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
            rule(#"\bAIza[0-9A-Za-z_\-]{35}\b"#),
            rule(#"\b(?:sk|rk|pk)_(?:live|test)_[0-9A-Za-z]{16,}\b"#),
            rule(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
            // user:password@host keeps the scheme and the user.
            rule(#"(\b[A-Za-z][A-Za-z0-9+.\-]*://[^\s:/@]+:)[^\s@/]+(@)"#, kept),
            // SECRET_NAME=value lines, as in .env files and shell exports.
            rule(
                #"(?m)^(\s*(?:export\s+)?[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY|CREDENTIALS?)[A-Z0-9_]*\s*[=:]\s*)(?!["']?\[secret\])["']?(?=[^\s"']*[A-Za-z])[^\s"']{6,}["']?()"#,
                kept),
            // password = "value", apiKey: 'value' and friends inside code.
            rule(
                #"((?:password|passwd|secret|token|api_?key|access_?key|private_?key)["']?\s*[=:]\s*["'])(?!\[secret\])[^"'\s]{4,}(["'])"#,
                kept, caseInsensitive: true),
        ]
    }()

    /// The text with secrets masked, and how many were masked.
    public static func redact(_ text: String) -> (text: String, count: Int) {
        var result = text
        var count = 0
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            let matches = rule.regex.numberOfMatches(in: result, range: range)
            guard matches > 0 else { continue }
            count += matches
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return (result, count)
    }
}
