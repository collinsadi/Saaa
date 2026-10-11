import CoreGraphics
import Foundation

/// One run of recognized text and its box in image pixels, origin top-left.
public struct TextFragment: Sendable, Equatable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

// Geometry in Double, so layout math never mixes CGFloat and Double.
extension TextFragment {
    var minX: Double { Double(box.minX) }
    var maxX: Double { Double(box.maxX) }
    var minY: Double { Double(box.minY) }
    var maxY: Double { Double(box.maxY) }
    var midX: Double { Double(box.midX) }
    var midY: Double { Double(box.midY) }
    var width: Double { Double(box.width) }
    var height: Double { Double(box.height) }
}

/// Turns OCR fragments back into text a person (and Claude) can read.
///
/// - Side-by-side panes split on wide vertical gaps that rows sit on both
///   sides of, so an IDE's file list or a problem statement beside its
///   editor doesn't interleave with the code line by line.
/// - Inside a pane, fragments on one row join left to right, rows run top
///   to bottom, and a big vertical gap leaves a blank line.
/// - Leading indentation comes back from each row's x position over the
///   median character width. It matters for code, Python above all.
/// - A gutter of sequential line numbers is dropped.
public enum OCRLayout {

    /// Marks the boundary between side-by-side panes in assembled text.
    public static let paneSeparator = "[next pane]"

    public static func assemble(_ fragments: [TextFragment]) -> String {
        let usable = clean(fragments)
        guard !usable.isEmpty else { return "" }
        let charWidth = medianCharacterWidth(usable)
        return splitIntoPanes(usable, charWidth: charWidth)
            .map { assemblePane($0, charWidth: charWidth) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n\(paneSeparator)\n\n")
    }

    // MARK: - Steps

    /// Drops empty runs and the tiny glyphs of minimaps and thumbnails.
    static func clean(_ fragments: [TextFragment]) -> [TextFragment] {
        let candidates = fragments.filter {
            !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.width > 0 && $0.height > 0
        }
        guard !candidates.isEmpty else { return [] }
        let heights = candidates.map(\.height).sorted()
        let typical = heights[heights.count / 2]
        return candidates.filter { $0.height >= typical * 0.45 }
    }

    static func medianCharacterWidth(_ fragments: [TextFragment]) -> Double {
        let widths = fragments.compactMap { fragment -> Double? in
            let count = fragment.text.count
            return count >= 3 ? Double(fragment.width) / Double(count) : nil
        }.sorted()
        guard !widths.isEmpty else { return 8 }
        return max(1, widths[widths.count / 2])
    }

    /// Rows top to bottom, each sorted left to right. A fragment joins a row
    /// when its vertical centre sits within half a line of the row's first.
    static func groupRows(_ fragments: [TextFragment]) -> [[TextFragment]] {
        var rows: [[TextFragment]] = []
        for fragment in fragments.sorted(by: { $0.midY < $1.midY }) {
            if let anchor = rows.last?.first,
               abs(fragment.midY - anchor.midY) < min(anchor.height, fragment.height) * 0.5 {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { $0.sorted { $0.minX < $1.minX } }
    }

    /// Splits on vertical gaps at least 8 characters wide that at most one
    /// row in twenty crosses (a title bar may span panes) and that at least
    /// three rows have text on both sides of. Code indentation never
    /// qualifies: no row has text on both sides of its own indent.
    static func splitIntoPanes(_ fragments: [TextFragment], charWidth: Double) -> [[TextFragment]] {
        let rows = groupRows(fragments)
        guard rows.count >= 3,
              let minX = fragments.map(\.minX).min(),
              let maxX = fragments.map(\.maxX).max() else { return [fragments] }
        let binWidth = max(2, charWidth / 2)
        let binCount = Int(((maxX - minX) / binWidth).rounded(.up)) + 1
        guard binCount > 4, binCount <= 20_000 else { return [fragments] }
        func bin(_ x: Double) -> Int {
            min(binCount - 1, max(0, Int(((x - minX) / binWidth).rounded(.down))))
        }
        var crossings = [Int](repeating: 0, count: binCount)
        for row in rows {
            var covered = [Bool](repeating: false, count: binCount)
            for fragment in row {
                for index in bin(fragment.minX)...bin(fragment.maxX) { covered[index] = true }
            }
            for index in 0..<binCount where covered[index] { crossings[index] += 1 }
        }
        let allowed = max(1, rows.count / 20)
        let minimumGap = max(8 * charWidth, 48)
        var cuts: [Double] = []
        var runStart: Int?
        for index in 0...binCount {
            if index < binCount, crossings[index] <= allowed {
                if runStart == nil { runStart = index }
                continue
            }
            defer { runStart = nil }
            guard let start = runStart, start > 0, index < binCount else { continue }
            let gapStart = minX + Double(start) * binWidth
            let gapEnd = minX + Double(index) * binWidth
            guard gapEnd - gapStart >= minimumGap else { continue }
            let straddling = rows.filter { row in
                row.contains { $0.maxX <= gapStart + binWidth } && row.contains { $0.minX >= gapEnd - binWidth }
            }.count
            if straddling >= 3 { cuts.append((gapStart + gapEnd) / 2) }
        }
        guard !cuts.isEmpty else { return [fragments] }
        var panes = [[TextFragment]](repeating: [], count: cuts.count + 1)
        for fragment in fragments {
            let index = cuts.firstIndex { fragment.midX < $0 } ?? cuts.count
            panes[index].append(fragment)
        }
        return panes.filter { !$0.isEmpty }
    }

    static func assemblePane(_ fragments: [TextFragment], charWidth: Double) -> String {
        let rows = dropLineNumberGutter(groupRows(fragments))
        let kept = rows.flatMap { $0 }
        guard let left = kept.map(\.minX).min() else { return "" }
        let heights = kept.map(\.height).sorted()
        let rowHeight = heights[heights.count / 2]
        var lines: [String] = []
        var previousBottom: Double?
        for row in rows {
            guard let first = row.first else {
                // A gutter number alone on its row: a blank line of code.
                if lines.last?.isEmpty == false { lines.append("") }
                continue
            }
            if let previousBottom, first.minY - previousBottom > rowHeight * 1.6, lines.last?.isEmpty == false {
                lines.append("")
            }
            let indent = min(40, max(0, Int(((first.minX - left) / charWidth).rounded())))
            var line = String(repeating: " ", count: indent)
            var cursor: Double?
            for fragment in row {
                if let cursor {
                    let spaces = min(4, max(1, Int(((fragment.minX - cursor) / charWidth).rounded())))
                    line += String(repeating: " ", count: spaces)
                }
                line += fragment.text.trimmingCharacters(in: .whitespaces)
                cursor = fragment.maxX
            }
            lines.append(line)
            previousBottom = row.map(\.maxY).max()
        }
        return stripLeadingNumbers(lines).joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    // MARK: - Line-number gutters

    static func lineNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (1...5).contains(trimmed.count), trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(trimmed)
    }

    static func isMostlySequential(_ numbers: [Int]) -> Bool {
        guard numbers.count >= 3 else { return false }
        let steps = zip(numbers, numbers.dropFirst()).filter { $1 == $0 + 1 }.count
        return Double(steps) >= Double(numbers.count - 1) * 0.7
    }

    /// Editors draw line numbers apart from the code: when most rows start
    /// with a bare number and the numbers count up, drop them.
    static func dropLineNumberGutter(_ rows: [[TextFragment]]) -> [[TextFragment]] {
        let numbers = rows.compactMap { $0.first.flatMap { lineNumber($0.text) } }
        guard rows.count >= 4, Double(numbers.count) >= Double(rows.count) * 0.6,
              isMostlySequential(numbers) else { return rows }
        return rows.map { row in
            guard let first = row.first, lineNumber(first.text) != nil else { return row }
            return Array(row.dropFirst())
        }
    }

    /// The same gutter when OCR merged each number into its line.
    static func stripLeadingNumbers(_ lines: [String]) -> [String] {
        func split(_ line: String) -> (number: Int, rest: Substring)? {
            let trimmed = line.drop { $0 == " " }
            let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
            guard (1...5).contains(digits.count), let number = Int(digits) else { return nil }
            let after = trimmed.dropFirst(digits.count)
            guard after.first == " " else { return nil }
            let rest = after.drop { $0 == " " }
            return rest.isEmpty ? nil : (number, rest)
        }
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let hits = nonEmpty.compactMap(split)
        guard nonEmpty.count >= 4, Double(hits.count) >= Double(nonEmpty.count) * 0.6,
              isMostlySequential(hits.map(\.number)) else { return lines }
        return lines.map { line in split(line).map { String($0.rest) } ?? line }
    }
}
