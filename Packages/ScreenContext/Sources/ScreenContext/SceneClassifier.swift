import Core
import Foundation

/// Decides what kind of moment a screen shows from its text alone, on the
/// Mac, with cheap rules. Order matters: an error beats everything (it is
/// the most urgent thing on screen), and a problem statement beats the
/// code under it.
public enum SceneClassifier {

    public static func classify(_ text: String) -> ScreenScene {
        let lowered = text.lowercased()
        if looksLikeError(text, lowered: lowered) { return .error }
        if problemSignals(lowered) >= 2 { return .problem }
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let codeLines = lines.filter(looksLikeCode).count
        let codeHeavy = codeLines >= 4 && Double(codeLines) >= Double(lines.count) * 0.25
        if !codeHeavy, asksACodingQuestion(lowered) { return .question }
        return codeHeavy ? .code : .other
    }

    // MARK: - Errors

    static let errorPhrases = [
        "traceback (most recent call last)", "segmentation fault", "panicked at", "uncaught ",
        "fatal error:", "build failed", "tests failed", "test failed", "✘ test",
        "cannot find '", "has no member '", "cannot convert value of type", "use of unresolved identifier",
        "no such module", "is not defined", "undefined is not a function", "cannot read properties of",
        "unexpected token", "syntaxerror", "nullpointerexception", "undefined reference to",
    ]

    static let errorPatterns: [NSRegularExpression] = [
        // "error: ..." or "main.swift:12:5: error: ..." at the start of a line.
        #"(?im)^\s*(?:[\w./\\-]+:\d+(?::\d+)?:\s*)?(?:fatal\s+)?error(?:\[[A-Z0-9]+\])?:"#,
        // TypeError: ..., ValueError: ..., IllegalStateException at ...
        #"\b[A-Z][A-Za-z]*(?:Error|Exception)(?::|\s+at\b)"#,
        // Python, Java and JavaScript stack frames; Go panics.
        #"(?m)^\s*File ".*", line \d+"#,
        #"(?m)^\s*at [\w.$<>\[\]]+ ?\(.*:\d+(?::\d+)?\)"#,
        #"(?m)^panic: "#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func looksLikeError(_ text: String, lowered: String) -> Bool {
        if errorPhrases.contains(where: lowered.contains) { return true }
        let range = NSRange(text.startIndex..., in: text)
        return errorPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    // MARK: - Problem statements

    static let givenPhrases = [
        "given an array", "given a string", "given an integer", "given the root", "given a linked list",
        "given two", "given a binary", "given an m x n", "given a list", "given n ", "you may assume",
    ]

    static let constraintPattern = try! NSRegularExpression(pattern: #"\d+\s*<=\s*[a-z][\w.\[\]]*\s*<="#)

    /// LeetCode, HackerRank and textbook problems share a shape: numbered
    /// examples, input and output, constraints, "Given an array...".
    static func problemSignals(_ lowered: String) -> Int {
        var score = 0
        if lowered.range(of: #"example \d"#, options: .regularExpression) != nil { score += 1 }
        if (lowered.contains("input:") && lowered.contains("output:"))
            || (lowered.contains("sample input") && lowered.contains("sample output")) { score += 1 }
        if lowered.contains("constraints") { score += 1 }
        if givenPhrases.contains(where: lowered.contains) { score += 1 }
        if constraintPattern.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) != nil {
            score += 1
        }
        return score
    }

    // MARK: - Code

    static let codeStarts = [
        "func ", "def ", "class ", "struct ", "enum ", "import ", "from ", "return ", "let ", "var ",
        "const ", "if ", "else", "for ", "while ", "switch ", "case ", "public ", "private ", "#include",
        "fn ", "package ", "interface ", "function ", "async ", "await ", "try ", "catch", "guard ",
        "elif ", "except", "//", "#!", "SELECT ", "select ",
    ]

    static let codeOperators = ["=>", "->", "==", "!=", "&&", "||", "::", "+=", "-="]

    static func looksLikeCode(_ line: String) -> Bool {
        if codeStarts.contains(where: line.hasPrefix) { return true }
        if let last = line.last, "{};".contains(last) { return true }
        return codeOperators.contains(where: line.contains)
    }

    // MARK: - Questions

    static let askOpeners = [
        "how do i", "how can i", "how to ", "why does", "why is my", "why am i", "what's the best way",
        "what is the best way", "is there a way", "how would you", "can someone", "any idea",
    ]

    /// Words that make a question a coding one: unambiguous programming
    /// terms only, matched as whole words, so meeting slides ("can we make
    /// an exception?", "reply in the thread?") stay "other".
    static let codeWords: Set<String> = [
        "python", "javascript", "typescript", "java", "kotlin", "golang", "rust", "swift", "sql",
        "regex", "json", "recursion", "algorithm", "leetcode", "segfault", "xcode", "npm", "hashmap",
        "struct", "null", "nullptr", "async", "await", "lambda", "boolean",
    ]

    static let codePhrases = [
        "linked list", "hash map", "stack trace", "o(n", "big o", "time complexity", "pip install",
        "binary tree", "c++", "c#", "array of", "this function", "the function", "my code", "this code",
        "the code", "compile error", "null pointer", "unit test", "for loop", "while loop",
    ]

    static func asksACodingQuestion(_ lowered: String) -> Bool {
        lowered.split(separator: "\n").contains { line in
            let asks = line.trimmingCharacters(in: .whitespaces).hasSuffix("?") || askOpeners.contains(where: line.contains)
            guard asks else { return false }
            if codePhrases.contains(where: line.contains) { return true }
            let words = line.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            return words.contains(where: codeWords.contains)
        }
    }
}
