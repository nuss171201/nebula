import Foundation

/// Why a file on a web server could not be fetched.
enum DirectDownloadError: Error, Equatable {
    /// The server answered with something other than the file (a status, in words).
    case refused(Int)
    /// What arrived is a playlist of segments, not a video.
    case playlist
    case couldNotSave
    /// The connection failed; carries the system's description.
    case network(String)

    var userMessage: String {
        switch self {
        case let .refused(status): "The server would not send the file (it answered \(status))."
        case .playlist: "This stream is a playlist of many small files, which cannot be downloaded."
        case .couldNotSave: "The file arrived but could not be saved."
        case let .network(description): "The download stopped. \(description)"
        }
    }
}

/// Fetches one file from a web server to a place on disk, reporting how far it has come.
///
/// One instance is one attempt. Cancelling the task that waits on `run` stops the transfer
/// and leaves what is needed to go on from there in `resumeData`, where the server allows it.
final class DirectDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, String?), any Error>?
    private var task: URLSessionDownloadTask?
    private var stored: Result<(URL, String?), any Error>?
    private var keptResumeData: Data?
    private let folder: URL
    private let onProgress: @Sendable (_ done: Int64, _ total: Int64?) -> Void

    /// What a later attempt can go on from, if this one was interrupted.
    var resumeData: Data? {
        lock.withLock { keptResumeData }
    }

    /// - Parameter folder: Where the finished file is put, under a name of its own, until the
    ///   caller moves it to where it is kept.
    init(folder: URL, onProgress: @escaping @Sendable (_ done: Int64, _ total: Int64?) -> Void) {
        self.folder = folder
        self.onProgress = onProgress
    }

    /// Fetches the file. Returns where it was put and the name the server suggests for it.
    /// - Parameter resumeData: What an interrupted attempt left, to go on from there.
    func run(_ request: URLRequest, resumeData: Data? = nil) async throws -> (URL, String?) {
        let configuration = URLSessionConfiguration.ephemeral
        // Between two packets, not for the whole file: a film takes as long as it takes.
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
        lock.withLock { self.task = task }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel { [weak self] data in
                self?.lock.withLock { self?.keptResumeData = data }
            }
        }
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is gone when this returns, so it is judged and moved here.
        let response = downloadTask.response as? HTTPURLResponse
        let result: Result<(URL, String?), any Error>
        if let status = response?.statusCode, !(200 ..< 300).contains(status) {
            result = .failure(DirectDownloadError.refused(status))
        } else if let type = response?.mimeType?.lowercased(), type.contains("mpegurl") || type.contains("dash+xml") {
            result = .failure(DirectDownloadError.playlist)
        } else {
            let destination = folder.appendingPathComponent("\(UUID().uuidString).part")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: location, to: destination)
                result = .success((destination, response?.suggestedFilename))
            } catch {
                result = .failure(DirectDownloadError.couldNotSave)
            }
        }
        lock.withLock { stored = result }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, stored) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, self.stored)
        }
        guard let continuation else { return }
        if let error = error as? NSError {
            if error.code == NSURLErrorCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            // A dropped connection often leaves enough to go on from.
            if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                lock.withLock { keptResumeData = data }
            }
            continuation.resume(throwing: DirectDownloadError.network(error.localizedDescription))
        } else if let stored {
            continuation.resume(with: stored)
        } else {
            continuation.resume(throwing: DirectDownloadError.couldNotSave)
        }
    }
}
