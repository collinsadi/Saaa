import Foundation

/// Word-level similarity for the echo guard. Short phrases ("yeah",
/// "okay") never count: too ambiguous to call an echo.
public enum TextSimilarity {

    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    public static func isNearDuplicate(_ lhs: String, _ rhs: String, minimumWords: Int = 3) -> Bool {
        let a = words(lhs)
        let b = words(rhs)
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        guard shorter.count >= minimumWords else { return false }
        let longerSet = Set(longer)
        let shared = shorter.filter { longerSet.contains($0) }.count
        let containment = Double(shared) / Double(shorter.count)
        let union = Set(a).union(b).count
        let jaccard = union > 0 ? Double(Set(a).intersection(b).count) / Double(union) : 0
        // An echo is the same utterance heard twice: nearly every word of the
        // shorter phrase recurs AND the phrases mostly overlap overall.
        return (containment >= 0.85 && jaccard >= 0.5) || jaccard >= 0.8
    }
}
