import Foundation
import CryptoKit

public enum Hashing {
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Downloads a file over HTTPS with progress, then verifies its SHA-256 when one is pinned.
/// A verified file already on disk is reused.
public final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public typealias Progress = @Sendable (_ received: Int64, _ total: Int64) -> Void

    private var progress: Progress?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL!

    public static func fetch(_ url: URL, to file: URL, sha256: String?, progress: Progress? = nil) async throws {
        guard url.scheme == "https" else { throw AquaError("Refusing non-HTTPS download: \(url)") }
        if FileManager.default.fileExists(atPath: file.path) {
            if let sha256, (try? Hashing.sha256(of: file)) == sha256 { return }
            if sha256 == nil { return }
            try FileManager.default.removeItem(at: file)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = file.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)

        let downloader = Downloader()
        downloader.progress = progress
        downloader.destination = partial
        let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                downloader.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }

        if let sha256 {
            let actual = try Hashing.sha256(of: partial)
            guard actual == sha256 else {
                try? FileManager.default.removeItem(at: partial)
                throw AquaError("\(file.lastPathComponent) failed verification (expected \(sha256.prefix(12))…, got \(actual.prefix(12))…). Nothing was installed.")
            }
        }
        try FileManager.default.moveItem(at: partial, to: file)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(AquaError("Download failed with HTTP \(http.statusCode): \(downloadTask.originalRequest?.url?.absoluteString ?? "")")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
