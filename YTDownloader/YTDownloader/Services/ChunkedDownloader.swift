import Foundation

/// Downloads a file in 10 MB pieces using HTTP "Range" requests.
///
/// Why pieces instead of one big request?
///  - YouTube slows down ("throttles") long single connections; short ranged requests stay fast.
///  - A failed download can continue where it stopped, because finished pieces stay on disk.
final class ChunkedDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    static let shared = ChunkedDownloader()

    enum DownloadError: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .http(403): return "YouTube refused the download (link expired). Tap Retry."
            case .http(let code): return "Server error \(code)."
            }
        }
    }

    /// (bytes written so far, total bytes or 0 if unknown)
    typealias ProgressHandler = @Sendable (Int64, Int64) -> Void

    private let chunkSize: Int64 = 10 * 1024 * 1024

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Public

    /// Downloads `url` into `destination`. If `destination` already holds part of the file,
    /// the download continues from there.
    func download(_ url: URL, to destination: URL, progress: @escaping ProgressHandler) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }
        var total: Int64?
        var lastReport = Date.distantPast

        while true {
            try Task.checkCancellation()
            let offset = Self.fileSize(destination)
            if let total, offset >= total { break }

            var end = offset + chunkSize - 1
            if let total { end = min(end, total - 1) }

            var request = URLRequest(url: url)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")

            let result = try await run(request, writingTo: destination, at: offset) { received in
                // Report at most ~6 times per second to keep the UI smooth but cheap.
                let now = Date()
                if now.timeIntervalSince(lastReport) > 0.15 {
                    lastReport = now
                    progress(offset + received, total ?? 0)
                }
            }

            switch result.status {
            case 206:
                total = Self.totalFromContentRange(result.contentRange) ?? total
                if total == nil, result.received < end - offset + 1 { // last short piece, size unknown
                    total = Self.fileSize(destination)
                }
            case 200:
                // Server ignored the range and sent the whole file in one go.
                total = Self.fileSize(destination)
            case 416:
                // Range not satisfiable: we already have everything.
                total = Self.fileSize(destination)
            default:
                throw DownloadError.http(result.status)
            }
            if result.status == 206 && result.received == 0 { break }   // nothing more to read
        }

        let size = Self.fileSize(destination)
        progress(size, total ?? size)
    }

    /// Size of a remote file in bytes, using a 1-byte ranged request.
    func remoteSize(of url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 206 {
            return Self.totalFromContentRange(http.value(forHTTPHeaderField: "Content-Range"))
        }
        return http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - One ranged request

    private struct ChunkResult {
        var status: Int
        var contentRange: String?
        var received: Int64
    }

    private final class State {
        let handle: FileHandle
        let startOffset: Int64
        let onBytes: (Int64) -> Void
        var continuation: CheckedContinuation<ChunkResult, Error>?
        var result = ChunkResult(status: 0, contentRange: nil, received: 0)
        var accepting = false

        init(handle: FileHandle, startOffset: Int64, onBytes: @escaping (Int64) -> Void) {
            self.handle = handle
            self.startOffset = startOffset
            self.onBytes = onBytes
        }
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]

    private func run(_ request: URLRequest, writingTo file: URL, at offset: Int64,
                     onBytes: @escaping (Int64) -> Void) async throws -> ChunkResult {
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(offset))   // drop any half-written bytes
        try handle.seek(toOffset: UInt64(offset))
        defer { try? handle.close() }

        let task = session.dataTask(with: request)
        let state = State(handle: handle, startOffset: offset, onBytes: onBytes)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.continuation = continuation
                lock.withLock { states[task.taskIdentifier] = state }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func state(for task: URLSessionTask) -> State? {
        lock.withLock { states[task.taskIdentifier] }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = state(for: dataTask), let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        state.result.status = http.statusCode
        state.result.contentRange = http.value(forHTTPHeaderField: "Content-Range")
        switch http.statusCode {
        case 206:
            state.accepting = true
        case 200:
            // Full file coming: start the file from scratch.
            try? state.handle.truncate(atOffset: 0)
            try? state.handle.seek(toOffset: 0)
            state.accepting = true
        default:
            state.accepting = false   // don't write error pages into the video file
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(for: dataTask), state.accepting else { return }
        do {
            try state.handle.write(contentsOf: data)
            state.result.received += Int64(data.count)
            state.onBytes(state.result.received)
        } catch {
            state.accepting = false
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let state = lock.withLock { states.removeValue(forKey: task.taskIdentifier) }
        guard let state, let continuation = state.continuation else { return }
        state.continuation = nil
        if let error {
            let isCancel = (error as? URLError)?.code == .cancelled
            continuation.resume(throwing: isCancel ? CancellationError() as Error : error)
        } else {
            continuation.resume(returning: state.result)
        }
    }

    // MARK: - Helpers

    /// "bytes 0-1023/52345678" → 52345678
    private static func totalFromContentRange(_ header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}
