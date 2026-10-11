import Darwin
import Foundation
import Testing
@testable import ScreenContext

@Suite struct EditorBridgeParsingTests {

    @Test func parsesHelloFocusAndReplies() {
        let hello = EditorBridge.parse(Array(#"{"type":"hello","protocol":1,"app":"Cursor","scheme":"cursor","workspace":"saaa","focused":true}"#.utf8))
        #expect(hello == .hello(.init(app: "Cursor", scheme: "cursor", workspace: "saaa", focused: true, protocolVersion: 1)))
        #expect(EditorBridge.parse(Array(#"{"type":"focus","focused":false}"#.utf8)) == .focus(false))
        #expect(EditorBridge.parse(Array(#"{"type":"context","id":3,"context":null}"#.utf8)) == .context(id: 3, nil))
    }

    @Test func aBrokenReplyStillEndsItsRequest() {
        #expect(EditorBridge.parse(Array(#"{"type":"context","id":4,"context":{"visible":"oops"}}"#.utf8)) == .context(id: 4, nil))
    }

    @Test func ignoresJunk() {
        #expect(EditorBridge.parse(Array("not json".utf8)) == nil)
        #expect(EditorBridge.parse(Array(#"{"type":"shutdown"}"#.utf8)) == nil)
        #expect(EditorBridge.parse(Array(#"{"type":"focus"}"#.utf8)) == nil)
    }

    /// The shared example: the extension's tests build it, this decodes it.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: Self.fixture.path)))
    func decodesTheExtensionsSharedFixture() throws {
        let context = try JSONDecoder().decode(EditorContext.self, from: Data(contentsOf: Self.fixture))
        #expect(context.file == "src/app.ts")
        #expect(context.cursorLine == 5)
        #expect(context.visible.map(\.startLine) == [1, 9])
        #expect(context.problems.first == .init(
            line: 5, severity: "error", message: "Property 'value' does not exist on type 'number'.", source: "ts", code: "2339"))
        #expect(context.terminal?.exitCode == 1)
        let snapshot = try #require(EditorLook.compose(context, appName: "Visual Studio Code"))
        #expect(snapshot.scene == .error)
        #expect(snapshot.text.contains("5  " + "  for (const item of items) sum += item.value;"))
    }

    static let fixture = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Editors/vscode/test/fixtures/context.json")
}

@Suite struct EditorBridgeChoiceTests {

    typealias Candidate = EditorBridge.Candidate

    @Test func picksTheFocusedWindowOfTheAppInFront() {
        let candidates = [
            Candidate(ancestry: [10, 5], scheme: "vscode", workspace: "api", focused: false, focusOrder: 3),
            Candidate(ancestry: [11, 5], scheme: "vscode", workspace: "web", focused: true, focusOrder: 2),
            Candidate(ancestry: [20, 7], scheme: "cursor", workspace: "web", focused: true, focusOrder: 9),
        ]
        #expect(EditorBridge.choose(candidates, appPID: 5, bundleID: nil, windowTitle: nil) == 1)
        #expect(EditorBridge.choose(candidates, appPID: 7, bundleID: nil, windowTitle: nil) == 2)
        #expect(EditorBridge.choose(candidates, appPID: 99, bundleID: nil, windowTitle: nil) == nil)
    }

    @Test func withNoWindowFocusedTheTitleThenTheLatestFocusDecide() {
        let candidates = [
            Candidate(ancestry: [10, 5], scheme: "vscode", workspace: "api", focused: false, focusOrder: 3),
            Candidate(ancestry: [11, 5], scheme: "vscode", workspace: "web", focused: false, focusOrder: 2),
        ]
        #expect(EditorBridge.choose(candidates, appPID: 5, bundleID: nil, windowTitle: "index.ts - Web - Visual Studio Code") == 1)
        #expect(EditorBridge.choose(candidates, appPID: 5, bundleID: nil, windowTitle: nil) == 0)
    }

    @Test func fallsBackToTheSchemeWhenAncestryIsUnknown() {
        let candidates = [Candidate(ancestry: [], scheme: "cursor", workspace: nil, focused: false, focusOrder: 0)]
        #expect(EditorBridge.choose(candidates, appPID: 5, bundleID: "com.todesktop.230313mzl4w4u92", windowTitle: nil) == 0)
        #expect(EditorBridge.choose(candidates, appPID: 5, bundleID: "com.microsoft.VSCode", windowTitle: nil) == nil)
    }

    @Test func ancestryStartsWithTheProcessAndClimbs() {
        let chain = EditorBridge.ancestry(of: getpid())
        #expect(chain.first == getpid())
        #expect(chain.count >= 2 ? chain[1] == getppid() : getppid() <= 1)
    }
}

/// The real socket, with a fake editor in this process.
@Suite(.serialized) struct EditorBridgeSocketTests {

    static let reply = #"{"file":"a.py","language":"python","lineCount":1,"cursorLine":1,"visible":[{"startLine":1,"text":"print(x)"}],"problems":[{"line":1,"severity":"error","message":"\"x\" is not defined"}]}"#

    func makeBridge() throws -> EditorBridge {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "saaa-\(UUID().uuidString.prefix(8)).sock")
        let bridge = EditorBridge(socketURL: url)
        try bridge.start()
        return bridge
    }

    @Test func asksTheConnectedEditorAndGetsExactText() async throws {
        let bridge = try makeBridge()
        defer { bridge.stop() }
        let editor = try FakeEditor(path: bridge.socketURL.path(percentEncoded: false))
        defer { editor.close() }
        try editor.send(#"{"type":"hello","protocol":1,"app":"Visual Studio Code","scheme":"vscode","workspace":"saaa","focused":true}"#)
        try await waitUntil { bridge.peers == [EditorPeer(app: "Visual Studio Code", workspace: "saaa")] }
        let answering = Task.detached { try editor.answerNextRequest(with: Self.reply) }
        let reply = await bridge.context(forAppPID: getpid(), bundleID: nil, windowTitle: nil, timeout: 3)
        try await answering.value
        #expect(reply?.app == "Visual Studio Code")
        #expect(reply?.context.problems.first?.message == "\"x\" is not defined")
        #expect(editor.receivedWelcome)
    }

    @Test func aSilentEditorTimesOut() async throws {
        let bridge = try makeBridge()
        defer { bridge.stop() }
        let editor = try FakeEditor(path: bridge.socketURL.path(percentEncoded: false))
        defer { editor.close() }
        try editor.send(#"{"type":"hello","protocol":1,"app":"Code","focused":true}"#)
        try await waitUntil { bridge.peers.count == 1 }
        let started = Date.now
        let reply = await bridge.context(forAppPID: getpid(), bundleID: nil, windowTitle: nil, timeout: 0.2)
        #expect(reply == nil)
        #expect(Date.now.timeIntervalSince(started) < 2)
    }

    @Test func aDisconnectEndsTheRequestAndForgetsTheWindow() async throws {
        let bridge = try makeBridge()
        defer { bridge.stop() }
        let editor = try FakeEditor(path: bridge.socketURL.path(percentEncoded: false))
        try editor.send(#"{"type":"hello","protocol":1,"app":"Code","focused":true}"#)
        try await waitUntil { bridge.peers.count == 1 }
        let closing = Task.detached {
            _ = try editor.readLine(containing: #""type":"context""#)
            editor.close()
        }
        let reply = await bridge.context(forAppPID: getpid(), bundleID: nil, windowTitle: nil, timeout: 5)
        try await closing.value
        #expect(reply == nil)
        try await waitUntil { bridge.peers.isEmpty }
    }

    @Test func noEditorForTheAppMeansNoWait() async throws {
        let bridge = try makeBridge()
        defer { bridge.stop() }
        let started = Date.now
        #expect(await bridge.context(forAppPID: getpid(), bundleID: "com.microsoft.VSCode", windowTitle: nil, timeout: 5) == nil)
        #expect(Date.now.timeIntervalSince(started) < 1)
    }

    @Test func theSocketIsOwnerOnly() throws {
        let bridge = try makeBridge()
        defer { bridge.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: bridge.socketURL.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(attributes[.type] as? FileAttributeType == .typeSocket)
    }
}

/// The extension's own client, compiled by `npm test` in Editors/vscode,
/// run by Node against the bridge. Skipped when either is missing.
@Suite struct EditorExtensionEndToEndTests {

    static let driver = EditorBridgeParsingTests.fixture
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "out/test/driver.js")

    static let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(.enabled(if: node != nil && FileManager.default.fileExists(atPath: driver.path(percentEncoded: false))))
    func theExtensionClientAnswersTheBridge() async throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "saaa-\(UUID().uuidString.prefix(8)).sock")
        let bridge = EditorBridge(socketURL: url)
        try bridge.start()
        defer { bridge.stop() }
        let process = Process()
        process.executableURL = URL(filePath: try #require(Self.node))
        process.arguments = [Self.driver.path(percentEncoded: false), url.path(percentEncoded: false)]
        try process.run()
        defer { process.terminate() }
        try await waitUntil(seconds: 10) { bridge.peers == [EditorPeer(app: "Driver Editor", workspace: "e2e")] }
        // Node is a child of this test process, so ancestry ties it to us.
        let reply = try #require(await bridge.context(forAppPID: getpid(), bundleID: nil, windowTitle: nil, timeout: 3))
        #expect(reply.context.file == "src/total.ts")
        #expect(reply.context.cursorLine == 1)
        let snapshot = try #require(EditorLook.compose(reply.context, appName: reply.app))
        #expect(snapshot.scene == .error)
        #expect(snapshot.text.contains("- line 1, error: Property 'value' does not exist on type 'number'. [ts 2339]"))
        #expect(snapshot.text.contains("1  const total = items.reduce((sum, item) => sum + item.value, 0);"))
    }
}

/// Polls until `condition` holds.
func waitUntil(seconds: Double = 2, _ condition: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<Int(seconds * 100) {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting")
}

/// A blocking client socket that plays an editor extension.
final class FakeEditor: @unchecked Sendable {
    private let fd: Int32
    private var buffer: [UInt8] = []
    private let lock = NSLock()
    private(set) var receivedWelcome = false

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func send(_ json: String) throws {
        let bytes = Array((json + "\n").utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw POSIXError(.EPIPE) }
    }

    /// Reads lines until one contains `marker`.
    func readLine(containing marker: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        while true {
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeFirst(newline + 1)
                if line.contains(#""type":"welcome""#) { receivedWelcome = true }
                if line.contains(marker) { return line }
            }
            var chunk = [UInt8](repeating: 0, count: 4_096)
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    func answerNextRequest(with context: String) throws {
        let request = try readLine(containing: #""type":"context""#)
        guard let range = request.range(of: #""id":"#) else { throw POSIXError(.EBADMSG) }
        let id = request[range.upperBound...].prefix { $0.isNumber }
        try send(#"{"type":"context","id":\#(id),"context":\#(context)}"#)
    }

    func close() {
        Darwin.close(fd)
    }
}
