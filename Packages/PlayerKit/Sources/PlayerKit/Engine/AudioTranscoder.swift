import Foundation

/// Converts one audio track of a file to AAC with an `ffmpeg` program, for the rare track
/// the playback engine cannot decode itself.
///
/// The app does not ship ffmpeg: this uses a helper inside the app bundle if one is ever
/// added, otherwise an ffmpeg the user has installed. With neither, there is no transcoder.
public struct AudioTranscoder: Sendable, Equatable {
    public enum Failure: Error, Sendable, Equatable {
        case couldNotStart(String)
        /// ffmpeg ran and gave up; carries the end of what it said.
        case failed(status: Int32, message: String)
        case cancelled
    }

    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Where Homebrew and manual installs put ffmpeg.
    static let installLocations = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    /// A helper named `ffmpeg` inside the app bundle if there is one, otherwise an installed ffmpeg.
    public static func locate(
        bundle: Bundle = .main,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> AudioTranscoder? {
        let bundled = bundle.url(forAuxiliaryExecutable: "ffmpeg")?.path
        return ([bundled].compactMap(\.self) + installLocations)
            .first(where: isExecutable)
            .map { AudioTranscoder(executable: URL(fileURLWithPath: $0)) }
    }

    /// - Parameters:
    ///   - audioIndex: Which of the file's audio tracks, counting from 0.
    static func arguments(input: String, audioIndex: Int, output: URL) -> [String] {
        [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            // The input is a file or an http(s) address and must stay one: a crafted playlist
            // must not be able to make ffmpeg read other files or talk other protocols.
            "-protocol_whitelist", "file,http,https,tcp,tls,crypto",
            "-i", input,
            "-map", "0:a:\(audioIndex)", "-vn", "-sn", "-dn",
            "-c:a", "aac", "-b:a", "256k",
            "-f", "matroska", output.path,
        ]
    }

    /// Converts the track into `output` (Matroska with AAC). Cancelling the task stops ffmpeg.
    public func transcode(source: PlayableSource, audioIndex: Int, to output: URL) async throws(Failure) {
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(input: source.engineArgument, audioIndex: audioIndex, output: output)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors

        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                    process.terminationHandler = { finished in
                        continuation.resume(returning: finished.terminationStatus)
                    }
                    do {
                        try process.run()
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                if process.isRunning {
                    process.terminate()
                }
            }
        } catch {
            throw .couldNotStart(error.localizedDescription)
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: output)
            throw .cancelled
        }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: output)
            let said = (try? errors.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw .failed(status: status, message: String(said.suffix(400)))
        }
    }
}

/// What the player keeps track of, per file, to recover from audio it cannot decode.
struct AudioFallbackState {
    /// The audio track that was last asked for or seen playing.
    var wantedTrack: Int?
    /// Tracks whose decoder would not start.
    var failedTracks: Set<Int> = []
    /// Converted tracks by the number of the track they replace.
    var convertedFiles: [Int: URL] = [:]
    var task: Task<Void, Never>?

    /// The next thing to try for a track that will not decode, in order of preference: another
    /// track in the same language, converting it, then any other track.
    enum Step: Equatable {
        case switchTo(Int)
        case convert
        case giveUp
    }

    static func nextStep(failed: MediaTrack, tracks: [MediaTrack], failedTracks: Set<Int>, canConvert: Bool) -> Step {
        let usable = tracks.filter { $0.kind == .audio && !$0.isExternal && !failedTracks.contains($0.number) && $0.number != failed.number }
        if let sameLanguage = usable.first(where: { LanguageMatcher.matches($0.language, failed.language) }) {
            return .switchTo(sameLanguage.number)
        }
        if canConvert {
            return .convert
        }
        if let other = usable.first {
            return .switchTo(other.number)
        }
        return .giveUp
    }
}
