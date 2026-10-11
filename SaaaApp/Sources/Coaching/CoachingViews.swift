import Core
import DesignSystem
import SwiftUI

enum CoachFormat {
    /// "1:45" for a stretch of talk.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = total / 60
        let rest = total % 60
        return "\(minutes):\(rest < 10 ? "0" : "")\(rest)"
    }

    static func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }
}

/// Speaking stats as a grid of small tiles, live or after the call.
struct CoachStatsGrid: View {
    let stats: CoachingStats

    @Environment(\.saaa) private var saaa

    private let columns = [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Space.md) {
            tile("Your share", stats.talkShare.map(CoachFormat.percent) ?? "Not yet", detail: shareDetail)
            tile("Pace", stats.wordsPerMinute.map { "\(Int($0.rounded())) wpm" } ?? "Not yet", detail: stats.pace?.label)
            tile("Questions you asked", "\(stats.questionsAsked)", detail: nil)
            tile("Longest stretch", CoachFormat.duration(stats.longestMonologue), detail: stats.longestMonologue >= CallCoach.monologueNudge ? "Long" : nil)
            tile("Filler words", "\(stats.fillerCount)", detail: stats.fillers.first.map { "Mostly \"\($0.phrase)\"" })
            tile("Talked over them", "\(stats.talkOvers)", detail: nil)
        }
        .accessibilityElement(children: .contain)
    }

    private var shareDetail: String? {
        guard let share = stats.talkShare else { return nil }
        if share > 0.65 { return "Mostly you" }
        if share < 0.35 { return "Mostly them" }
        return "Balanced"
    }

    private func tile(_ title: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(saaa.textSecondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(saaa.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The playbook's checklist: what's covered, and where when Saaa knows.
struct ChecklistRows: View {
    struct Row: Identifiable {
        let item: String
        let covered: Bool
        var evidence: String = ""
        var id: String { item }
    }

    let rows: [Row]

    @Environment(\.saaa) private var saaa

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Image(systemName: row.covered ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(row.covered ? saaa.successText : saaa.textTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.item)
                            .font(.system(size: 13))
                            .foregroundStyle(row.covered ? saaa.textPrimary : saaa.textSecondary)
                        if !row.evidence.isEmpty {
                            Text(row.evidence)
                                .font(.system(size: 11.5))
                                .foregroundStyle(saaa.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.item), \(row.covered ? "covered" : "not covered yet")")
            }
        }
    }
}
