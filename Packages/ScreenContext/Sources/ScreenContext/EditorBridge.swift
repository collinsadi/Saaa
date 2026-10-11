import Darwin
import Foundation
import os

/// An editor window with the Saaa extension connected.
public struct EditorPeer: Sendable, Hashable {
    public let app: String
    public let workspace: String?

    public init(app: String, workspace: String?) {
        self.app = app
        self.workspace = workspace
    }
}

/// What one editor window sent back.
public struct EditorReply: Sendable, Equatable {
    public let app: String
    public let context: EditorContext
}

public enum EditorBridgeError: Error, Equatable {
    case pathTooLong
    case socket(Int32)
}

/// The local end of the editor extensions: a Unix socket in Saaa's own
/// folder that only this user can open. Extensions connect and say hello;
/// Saaa asks the window the user is in for its context only when a Look or
/// a Watch read happens, and the extension answers with exact text.
/// Nothing here touches the network or the disk beyond the socket file.
///
/// All state lives on one serial queue; the public methods hop onto it.
/// The protocol is in `Editors/vscode/PROTOCOL.md`.
public final class EditorBridge: @unchecked Sendable {

    public static let shared = EditorBridge(socketURL: defaultSocketURL)

    public static var defaultSocketURL: URL {
        URL.applicationSupportDirectory.appending(path: "Saaa/editor.sock")
    }

    /// How long a Look waits for the editor before reading the screen.
    public static let requestTimeout: TimeInterval = 0.35
    static let maxClients = 32
    /// One message can't grow past this; the connection is dropped instead.
    static let maxMessageBytes = 4 << 20

    /// URI schemes the VS Code family reports, for when process ancestry
    /// can't tie a connection to the app in front.
    static let schemeBundles: [String: String] = [
        "vscode": "com.microsoft.VSCode",
        "vscode-insiders": "com.microsoft.VSCodeInsiders",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "windsurf": "com.exafunction.windsurf",
        "vscodium": "com.vscodium",
    ]

    public let socketURL: URL

    private let queue = DispatchQueue(label: "dev.collinsadi.saaa.editor-bridge")
    private var listener: DispatchSourceRead?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var focusCounter = 0
    private var lastPeers: [EditorPeer] = []
    private var peersHandler: (@Sendable ([EditorPeer]) -> Void)?

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "EditorBridge")

    public init(socketURL: URL) {
        self.socketURL = socketURL
    }

    deinit {
        listener?.cancel()
        for client in clients.values { client.source.cancel() }
    }

    // MARK: - Public

    /// Starts listening. Safe to call again; a stale socket file from an
    /// earlier run is replaced.
    public func start() throws {
        try queue.sync { try listen() }
    }

    /// Closes every connection and removes the socket file.
    public func stop() {
        queue.sync {
            for client in Array(clients.values) { drop(client) }
            if listener != nil {
                listener?.cancel()
                listener = nil
                unlink(socketURL.path(percentEncoded: false))
            }
        }
    }

    /// Editor windows connected right now, for Settings.
    public var peers: [EditorPeer] {
        queue.sync { lastPeers }
    }

    /// Called on a background queue whenever the connected windows change,
    /// and once right away.
    public func onPeersChange(_ handler: @escaping @Sendable ([EditorPeer]) -> Void) {
        queue.async {
            self.peersHandler = handler
            handler(self.lastPeers)
        }
    }

    /// Asks the editor window of the app in front for its context. Nil when
    /// that app has no extension connected, the window has no text editor
    /// active, or it doesn't answer within `timeout`.
    public func context(
        forAppPID pid: pid_t, bundleID: String?, windowTitle: String?, timeout: TimeInterval = requestTimeout
    ) async -> EditorReply? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.request(pid: pid, bundleID: bundleID, windowTitle: windowTitle, timeout: timeout, continuation: continuation)
            }
        }
    }

    // MARK: - Listening

    private func listen() throws {
        guard listener == nil else { return }
        let path = socketURL.path(percentEncoded: false)
        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw EditorBridgeError.pathTooLong }
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EditorBridgeError.socket(errno) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            Self.log.error("Editor bridge couldn't listen: errno \(code, privacy: .public)")
            throw EditorBridgeError.socket(code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        listener = source
        source.resume()
    }

    private func acceptAll(_ listening: Int32) {
        while true {
            let fd = accept(listening, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            admit(fd)
        }
    }

    /// Only this user's processes get in, and never too many at once.
    private func admit(_ fd: Int32) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), clients.count < Self.maxClients else {
            close(fd)
            return
        }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var peer: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let known = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0 && peer > 0

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let client = Client(fd: fd, source: source, ancestry: known ? Self.ancestry(of: peer) : [])
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.readAvailable(client)
        }
        source.setCancelHandler { close(fd) }
        clients[ObjectIdentifier(client)] = client
        source.resume()
        _ = send(#"{"type":"welcome","protocol":1}"# + "\n", to: client)
    }

    // MARK: - Reading

    private func readAvailable(_ client: Client) {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(client.fd, $0.baseAddress, $0.count) }
            if count > 0 {
                client.buffer.append(contentsOf: chunk[0..<count])
                drainLines(client)
                if client.buffer.count > Self.maxMessageBytes {
                    drop(client)
                    return
                }
                continue
            }
            if count == 0 {
                drop(client)
                return
            }
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK { return }
            drop(client)
            return
        }
    }

    private func drainLines(_ client: Client) {
        var start = 0
        while let newline = client.buffer[start...].firstIndex(of: 10) {
            let line = client.buffer[start..<newline]
            start = newline + 1
            if let message = Self.parse(line) { handle(message, from: client) }
        }
        if start > 0 { client.buffer.removeFirst(start) }
    }

    private func handle(_ message: Message, from client: Client) {
        switch message {
        case .hello(let hello):
            client.hello = hello
            client.focused = hello.focused ?? false
            if client.focused { markFocused(client) }
            publishPeers()
        case .focus(let focused):
            client.focused = focused
            if focused { markFocused(client) }
        case .context(let id, let context):
            guard let entry = pending[id], entry.client == ObjectIdentifier(client) else { return }
            pending[id] = nil
            entry.continuation.resume(returning: context.map { EditorReply(app: client.hello?.app ?? "Editor", context: $0) })
        }
    }

    private func markFocused(_ client: Client) {
        focusCounter += 1
        client.focusOrder = focusCounter
    }

    // MARK: - Requests

    private func request(
        pid: pid_t, bundleID: String?, windowTitle: String?, timeout: TimeInterval,
        continuation: CheckedContinuation<EditorReply?, Never>
    ) {
        let ready = clients.values.filter { $0.hello != nil }.sorted { $0.fd < $1.fd }
        let candidates = ready.map {
            Candidate(
                ancestry: $0.ancestry, scheme: $0.hello?.scheme, workspace: $0.hello?.workspace,
                focused: $0.focused, focusOrder: $0.focusOrder)
        }
        guard let index = Self.choose(candidates, appPID: pid, bundleID: bundleID, windowTitle: windowTitle) else {
            continuation.resume(returning: nil)
            return
        }
        let client = ready[index]
        let id = nextID
        nextID += 1
        pending[id] = Pending(client: ObjectIdentifier(client), continuation: continuation)
        guard send(#"{"type":"context","id":\#(id)}"# + "\n", to: client) else {
            finish(id)
            return
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(id) }
    }

    /// Ends a request with no answer, unless it already has one.
    private func finish(_ id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(returning: nil)
    }

    @discardableResult
    private func send(_ line: String, to client: Client) -> Bool {
        let bytes = Array(line.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(client.fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            return false
        }
        return true
    }

    private func drop(_ client: Client) {
        let key = ObjectIdentifier(client)
        guard clients.removeValue(forKey: key) != nil else { return }
        client.source.cancel()
        for (id, entry) in pending where entry.client == key {
            pending[id] = nil
            entry.continuation.resume(returning: nil)
        }
        publishPeers()
    }

    private func publishPeers() {
        let peers = clients.values
            .compactMap { client in client.hello.map { EditorPeer(app: $0.app ?? "Editor", workspace: $0.workspace) } }
            .sorted { ($0.app, $0.workspace ?? "") < ($1.app, $1.workspace ?? "") }
        guard peers != lastPeers else { return }
        lastPeers = peers
        peersHandler?(peers)
    }

    // MARK: - Pure parts

    struct Hello: Decodable, Equatable {
        var app: String?
        var scheme: String?
        var workspace: String?
        var focused: Bool?
        var protocolVersion: Int?

        enum CodingKeys: String, CodingKey {
            case app, scheme, workspace, focused
            case protocolVersion = "protocol"
        }
    }

    enum Message: Equatable {
        case hello(Hello)
        case focus(Bool)
        case context(id: Int, EditorContext?)
    }

    private struct Envelope: Decodable { let type: String }
    private struct FocusBody: Decodable { let focused: Bool }
    private struct ContextID: Decodable { let id: Int }
    private struct ContextBody: Decodable {
        let id: Int
        let context: EditorContext?
    }

    /// One line from an extension. Unknown or malformed lines are ignored;
    /// a reply whose context doesn't decode still ends its request.
    static func parse(_ line: some Collection<UInt8>) -> Message? {
        let data = Data(line)
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        switch envelope.type {
        case "hello":
            return (try? decoder.decode(Hello.self, from: data)).map(Message.hello)
        case "focus":
            return (try? decoder.decode(FocusBody.self, from: data)).map { .focus($0.focused) }
        case "context":
            if let body = try? decoder.decode(ContextBody.self, from: data) { return .context(id: body.id, body.context) }
            return (try? decoder.decode(ContextID.self, from: data)).map { .context(id: $0.id, nil) }
        default:
            return nil
        }
    }

    struct Candidate: Equatable {
        var ancestry: [pid_t]
        var scheme: String?
        var workspace: String?
        var focused: Bool
        var focusOrder: Int
    }

    /// The window to ask: one belonging to the app in front (by process
    /// ancestry, or by URI scheme when ancestry is unknown), preferring the
    /// focused window, then the one named in the front window's title,
    /// then the one focused most recently.
    static func choose(_ candidates: [Candidate], appPID: pid_t, bundleID: String?, windowTitle: String?) -> Int? {
        var matching = candidates.indices.filter { candidates[$0].ancestry.contains(appPID) }
        if matching.isEmpty, let bundleID {
            matching = candidates.indices.filter { index in
                candidates[index].scheme.flatMap { schemeBundles[$0] } == bundleID
            }
        }
        guard !matching.isEmpty else { return nil }
        let latest = { (indices: [Int]) in indices.max { candidates[$0].focusOrder < candidates[$1].focusOrder } }
        let focused = matching.filter { candidates[$0].focused }
        if !focused.isEmpty { return latest(focused) }
        if let title = windowTitle?.lowercased(), !title.isEmpty {
            let named = matching.filter { index in
                guard let workspace = candidates[index].workspace?.lowercased(), !workspace.isEmpty else { return false }
                return title.contains(workspace)
            }
            if !named.isEmpty { return latest(named) }
        }
        return latest(matching)
    }

    /// A process and its parents, nearest first, up to (not including) launchd.
    static func ancestry(of pid: pid_t, limit: Int = 12) -> [pid_t] {
        var chain = [pid]
        var current = pid
        while chain.count < limit, let parent = parent(of: current), parent > 1, !chain.contains(parent) {
            chain.append(parent)
            current = parent
        }
        return chain
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}

/// One connected editor window. Touched only on the bridge's queue.
private final class Client: @unchecked Sendable {
    let fd: Int32
    let source: any DispatchSourceRead
    let ancestry: [pid_t]
    var hello: EditorBridge.Hello?
    var focused = false
    var focusOrder = 0
    var buffer: [UInt8] = []

    init(fd: Int32, source: any DispatchSourceRead, ancestry: [pid_t]) {
        self.fd = fd
        self.source = source
        self.ancestry = ancestry
    }
}

private struct Pending {
    let client: ObjectIdentifier
    let continuation: CheckedContinuation<EditorReply?, Never>
}
