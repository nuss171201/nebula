import Foundation
@testable import MediaCore
import Testing

@Suite("Guessing what a file is from its name")
struct MediaNameGuessTests {
    @Test("Titles, years and episode numbers are read from release-style names", arguments: [
        ("The.Office.US.S02E05.720p.WEB.x264-GRP.mkv", MediaNameGuess(title: "The Office US", season: 2, episode: 5)),
        ("Night of the Living Dead (1968).mp4", MediaNameGuess(title: "Night of the Living Dead", year: 1968)),
        ("Night.of.the.Living.Dead.1968.1080p.BluRay.x265.mkv", MediaNameGuess(title: "Night of the Living Dead", year: 1968)),
        ("Blade.Runner.2049.2017.2160p.UHD.mkv", MediaNameGuess(title: "Blade Runner 2049", year: 2017)),
        ("2001 A Space Odyssey.mkv", MediaNameGuess(title: "2001 A Space Odyssey")),
        ("[Group] Some Show - 3x07 - The Title [1080p].mkv", MediaNameGuess(title: "Some Show", season: 3, episode: 7)),
        ("show_name_s01_e02.avi", MediaNameGuess(title: "show name", season: 1, episode: 2)),
        ("Doctor.Who.2005.S01E01.mkv", MediaNameGuess(title: "Doctor Who", year: 2005, season: 1, episode: 1)),
        ("multi-track.mkv", MediaNameGuess(title: "multi-track")),
        ("Movie.720p.HDTV.mkv", MediaNameGuess(title: "Movie")),
        ("/Users/someone/Films/Sintel.2010.mkv", MediaNameGuess(title: "Sintel", year: 2010)),
        ("", MediaNameGuess(title: "")),
    ])
    func guesses(fileName: String, expected: MediaNameGuess) {
        #expect(MediaNameGuess(fileName: fileName) == expected)
    }

    @Test("Only a season together with an episode makes an episode")
    func episodes() {
        #expect(MediaNameGuess(fileName: "Show.S01E02.mkv").isEpisode)
        #expect(!MediaNameGuess(fileName: "Show.1999.mkv").isEpisode)
    }
}

@Suite("File fingerprint for subtitle matching")
struct VideoFileHashTests {
    @Test("The hash is the size plus the 64-bit words of the first and last chunk, wrapping")
    func arithmetic() {
        // All zero: the hash is just the size.
        let zeros = Data(count: VideoFileHash.chunkSize)
        #expect(VideoFileHash.hash(head: zeros, tail: zeros, size: 0x1234) == "0000000000001234")

        // One little-endian word of 1 at the start of each chunk adds 2.
        var one = zeros
        one[0] = 1
        #expect(VideoFileHash.hash(head: one, tail: one, size: 10) == "000000000000000c")

        // Overflow wraps instead of trapping.
        var high = zeros
        high.replaceSubrange(0 ..< 8, with: [UInt8](repeating: 0xFF, count: 8))
        #expect(VideoFileHash.hash(head: high, tail: zeros, size: 2) == "0000000000000001")
    }

    @Test("Reads only the ends of a file, and refuses files that are too small or missing")
    func files() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 64 KiB of zeros, 1000 bytes of noise the hash must not see, then 64 KiB of zeros… except one byte.
        var contents = Data(count: VideoFileHash.chunkSize)
        contents.append(Data(repeating: 0xAB, count: 1000))
        var tail = Data(count: VideoFileHash.chunkSize)
        tail[8] = 5
        contents.append(tail)
        let file = directory.appendingPathComponent("video.bin")
        try contents.write(to: file)

        let fingerprint = try #require(VideoFileHash.fingerprint(ofFileAt: file))
        #expect(fingerprint.size == Int64(contents.count))
        #expect(fingerprint.hash == String(format: "%016x", contents.count + 5))

        let small = directory.appendingPathComponent("small.bin")
        try Data(count: 100).write(to: small)
        #expect(VideoFileHash.fingerprint(ofFileAt: small) == nil)
        #expect(VideoFileHash.fingerprint(ofFileAt: directory.appendingPathComponent("missing.bin")) == nil)
    }
}
