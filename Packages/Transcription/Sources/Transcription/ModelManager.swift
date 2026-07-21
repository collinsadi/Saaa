import CryptoKit
import Foundation
import os

/// Errors thrown by ``ModelManager``.
public enum ModelError: Error, Equatable {
    /// The downloaded file's SHA-256 did not match the pinned hash.
    case checksumMismatch(model: WhisperModel, actual: String)
    /// The server responded with a non-success status.
    case downloadFailed(statusCode: Int)
    /// Filesystem failure while caching.
    case cacheFailure(String)
}

/// Download progress for one model.
public struct ModelDownloadProgress: Sendable, Equatable {
    public let model: WhisperModel
    public let bytesReceived: Int64
    public let bytesTotal: Int64

    public var fraction: Double {
        bytesTotal > 0 ? Double(bytesReceived) / Double(bytesTotal) : 0
    }
}

/// Downloads, verifies, and caches the whisper model files. Cached models are
/// never re-downloaded (a corrupted cache surfaces as a whisper load failure,
/// whose recovery is ``evict(_:)`` + re-download).
public actor ModelManager {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "ModelManager")

    private let cacheDirectory: URL

    /// `cacheDirectory` defaults to `~/Library/Application Support/Saaa/Models`.
    public init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory
            ?? URL.applicationSupportDirectory.appendingPathComponent("Saaa/Models", isDirectory: true)
    }

    /// Where a model lives once cached.
    public nonisolated func cachedURL(for model: WhisperModel) -> URL {
        cacheDirectory.appendingPathComponent(model.rawValue)
    }

    /// Whether the model file exists locally.
    public nonisolated func isCached(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: cachedURL(for: model).path)
    }

    /// Returns the local URL, downloading + SHA-256-verifying first if needed.
    /// Progress callbacks arrive on an arbitrary executor. Cancellable.
    public func ensure(
        _ model: WhisperModel,
        onProgress: (@Sendable (ModelDownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        let destination = cachedURL(for: model)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            throw ModelError.cacheFailure(String(describing: error))
        }

        Self.log.info("downloading \(model.rawValue, privacy: .public) (\(model.byteSize) bytes)")
        let temp = cacheDirectory
            .appendingPathComponent("\(model.rawValue).download-\(UUID().uuidString)")
        let downloaded = try await Self.download(
            model: model, to: temp, onProgress: onProgress)

        let digest = try Self.sha256OfFile(at: downloaded)
        guard digest == model.sha256 else {
            try? FileManager.default.removeItem(at: downloaded)
            throw ModelError.checksumMismatch(model: model, actual: digest)
        }
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: downloaded)
        } catch {
            try? FileManager.default.removeItem(at: downloaded)
            throw ModelError.cacheFailure(String(describing: error))
        }
        onProgress?(ModelDownloadProgress(
            model: model, bytesReceived: model.byteSize, bytesTotal: model.byteSize))
        Self.log.info("cached \(model.rawValue, privacy: .public)")
        return destination
    }

    /// Removes a cached model (corrupt-cache recovery path).
    public func evict(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: cachedURL(for: model))
    }

    // MARK: - Internals

    private static func download(
        model: WhisperModel,
        to temp: URL,
        onProgress: (@Sendable (ModelDownloadProgress) -> Void)?
    ) async throws -> URL {
        let delegate = DownloadDelegate(model: model, destination: temp, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: model.downloadURL)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Streaming SHA-256 of a file — never loads it whole.
    static func sha256OfFile(at url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ModelError.cacheFailure("cannot read \(url.path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 22), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Bridges URLSession's delegate-based download progress into async/await.
/// The continuation is resumed exactly once — either from
/// `didFinishDownloadingTo` (success; the file must be moved synchronously
/// inside that callback) or from `didCompleteWithError`.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let model: WhisperModel
    private let destination: URL
    private let onProgress: (@Sendable (ModelDownloadProgress) -> Void)?
    private let lock = NSLock()
    private var finished = false

    var continuation: CheckedContinuation<URL, Error>?

    init(
        model: WhisperModel,
        destination: URL,
        onProgress: (@Sendable (ModelDownloadProgress) -> Void)?
    ) {
        self.model = model
        self.destination = destination
        self.onProgress = onProgress
    }

    private func resumeOnce(_ result: Result<URL, Error>) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard !alreadyFinished, let continuation else { return }
        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(ModelDownloadProgress(
            model: model,
            bytesReceived: totalBytesWritten,
            bytesTotal: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.byteSize))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            resumeOnce(.failure(ModelError.downloadFailed(statusCode: http.statusCode)))
            return
        }
        do {
            // `location` is only valid inside this callback — claim it now.
            try FileManager.default.moveItem(at: location, to: destination)
            resumeOnce(.success(destination))
        } catch {
            resumeOnce(.failure(ModelError.cacheFailure(String(describing: error))))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resumeOnce(.failure(error))
        }
        // nil error: success already handled in didFinishDownloadingTo.
    }
}
