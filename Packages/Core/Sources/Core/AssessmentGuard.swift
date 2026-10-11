import Foundation

/// AI_POLICY Rule 3 outside calls: Code Assist stops at the approach when
/// the screen looks like a hiring assessment, an exam or a proctored test.
/// Practice stays useful (nudges and approaches); finished solutions don't.
public enum AssessmentGuard {

    /// Hiring-assessment platforms and proctoring tools, matched in the
    /// window title, the app name and the top of the screen text.
    static let markers = [
        "hackerrank", "codesignal", "coderpad", "codility", "hackerearth", "karat", "testgorilla",
        "qualified.io", "hirevue", "devskiller", "codingame for work", "honorlock", "proctorio",
        "respondus", "lockdown browser", "examsoft", "examplify", "proctoru",
    ]

    /// Whole words that turn a practice site into a timed test. Whole words
    /// only: "exam" must not match the "Example 1" on every problem page.
    static let testWords: Set<String> = ["contest", "assessment", "assessments", "exam", "exams", "quiz"]
    static let testPhrases = ["online test", "coding test"]

    public static func matches(windowTitle: String?, appName: String, screenText: String = "") -> Bool {
        let haystack = [windowTitle ?? "", appName, String(screenText.prefix(400))]
            .joined(separator: "\n").lowercased()
        if markers.contains(where: haystack.contains) { return true }
        guard ["leetcode", "codeforces", "atcoder"].contains(where: haystack.contains) else { return false }
        if testPhrases.contains(where: haystack.contains) { return true }
        let words = haystack.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.contains(where: testWords.contains)
    }
}
