import Foundation

/// Splits a byte stream into lines. Handles `\n`, `\r\n` and lone `\r`, and
/// unlike `AsyncLineSequence` it keeps EMPTY lines, which SSE needs as the
/// event dispatch signal.
public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []
    private var lastWasCR = false

    public init() {}

    /// Feeds one byte; returns a completed line when the byte ends one.
    public mutating func push(_ byte: UInt8) -> String? {
        switch byte {
        case 0x0A: // \n
            if lastWasCR {
                lastWasCR = false
                return nil // second half of \r\n, line already emitted
            }
            return emit()
        case 0x0D: // \r
            lastWasCR = true
            return emit()
        default:
            lastWasCR = false
            buffer.append(byte)
            return nil
        }
    }

    /// Feeds a chunk; returns every completed line in order.
    public mutating func push<Bytes: Sequence>(contentsOf bytes: Bytes) -> [String] where Bytes.Element == UInt8 {
        var lines: [String] = []
        for byte in bytes {
            if let line = push(byte) { lines.append(line) }
        }
        return lines
    }

    /// Returns any trailing partial line at end of input.
    public mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        return emit()
    }

    private mutating func emit() -> String {
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

/// One dispatched server-sent event.
public struct ServerSentEvent: Sendable, Equatable {
    public var event: String?
    public var data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental SSE parser (WHATWG event-stream rules, the subset the
/// Messages API uses): `event:` and `data:` fields, `:` comments, multiple
/// data lines joined by `\n`, dispatch on a blank line.
public struct SSEParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    /// Feeds one line (without its terminator). Returns an event when the
    /// line is the blank line that dispatches one.
    public mutating func feed(_ line: String) -> ServerSentEvent? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil // comment / keep-alive
        }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break // id, retry: unused by the Messages API
        }
        return nil
    }

    /// Flushes a final event when the stream ends without a trailing blank line.
    public mutating func finish() -> ServerSentEvent? {
        dispatch()
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            eventName = nil
            dataLines.removeAll()
        }
        guard !dataLines.isEmpty else { return nil }
        return ServerSentEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }
}
