@testable import AppUI
import Foundation
import MediaCore
import Testing

private func decodeStream(_ json: String) throws -> StreamItem {
    try JSONDecoder().decode(StreamItem.self, from: Data(json.utf8))
}

private func choice(_ json: String, addon: String = "a", position: Int = 0) throws -> StreamChoice {
    try StreamChoice(stream: decodeStream(json), addonID: addon, addonName: "Add-on \(addon.uppercased())", position: position)
}

@Suite("Reading and arranging streams (pure)")
struct StreamChoiceTests {
    @Test("Quality is read from the words add-ons use", arguments: [
        ("Example 2160p HDR", StreamQuality.uhd4K), ("4K\nDV", .uhd4K), ("Film.1080p.WEB", .hd1080), ("[720p] x264", .hd720),
        ("DVDRip", .sd), ("480p", .sd), ("1440p", .qhd1440),
    ])
    func quality(text: String, expected: StreamQuality) {
        #expect(StreamTextParser.quality(in: text) == expected)
    }

    @Test("Words that only look like a quality are not one")
    func noQuality() {
        #expect(StreamTextParser.quality(in: "Good release, 24k gold") == nil)
        #expect(StreamTextParser.quality(in: "") == nil)
    }

    @Test("Size is the largest one mentioned", arguments: [
        ("💾 1.4 GB", 1_503_238_553), ("700MB x264", 734_003_200), ("Pack 40 GB, this file 2,5 GB", 42_949_672_960),
        ("1 TB", 1_099_511_627_776),
    ] as [(String, Int64)])
    func size(text: String, expected: Int64) {
        #expect(StreamTextParser.size(in: text) == expected)
    }

    @Test("A stream's kind, title, size and quality come from what the add-on sent")
    func choices() throws {
        let torrent = try choice(#"""
        {"infoHash": "ABCDEF0123456789ABCDEF0123456789ABCDEF01", "fileIdx": 2, "name": "Add-on\n1080p", "title": "Film.2020.1080p.WEB\n👤 12 💾 2.1 GB",
         "behaviorHints": {"bingeGroup": "x|1080p", "filename": "Film.2020.1080p.WEB.mkv"}}
        """#)
        #expect(torrent.kind == .torrent && torrent.kindLabel == "Torrent")
        #expect(torrent.title == "Add-on 1080p")
        #expect(torrent.quality == .hd1080)
        #expect(torrent.sizeBytes == Int64(2.1 * 1_073_741_824))
        #expect(torrent.id == "a#0")

        // A size the add-on states outright wins over one found in the text.
        let direct = try choice(#"{"url": "https://cdn.example.com/a.mp4", "description": "720p 900 MB", "behaviorHints": {"videoSize": 1000}}"#)
        #expect(direct.kind == .direct && direct.sizeBytes == 1000 && direct.quality == .hd720)
        #expect(direct.title == "Add-on A")
        #expect(try choice(#"{"ytId": "abcdefghijk"}"#).kind == .youTube)
        #expect(try choice(#"{"externalUrl": "https://example.com/watch"}"#).kind == .external)
    }

    @Test("Streams are grouped by quality (best first, larger first), by size, or by add-on")
    func grouping() throws {
        let choices = try [
            choice(#"{"url": "https://e.com/1", "name": "720p", "description": "1 GB"}"#, addon: "a", position: 0),
            choice(#"{"url": "https://e.com/2", "name": "4K", "description": "20 GB"}"#, addon: "a", position: 1),
            choice(#"{"url": "https://e.com/3", "name": "unknown"}"#, addon: "b", position: 0),
            choice(#"{"url": "https://e.com/4", "name": "2160p", "description": "45 GB"}"#, addon: "b", position: 1),
            choice(#"{"url": "https://e.com/5", "name": "720p"}"#, addon: "b", position: 2),
        ]
        let byQuality = StreamGroup.groups(of: choices, by: .quality)
        #expect(byQuality.map(\.title) == ["4K", "720p", "Other"])
        #expect(byQuality[0].choices.map(\.id) == ["b#1", "a#1"])
        // Unknown sizes come after known ones, in the order they arrived.
        #expect(byQuality[1].choices.map(\.id) == ["a#0", "b#2"])

        let bySize = StreamGroup.groups(of: choices, by: .size)
        #expect(bySize.count == 1)
        #expect(bySize[0].choices.map(\.id) == ["b#1", "a#1", "a#0", "b#0", "b#2"])

        let bySource = StreamGroup.groups(of: choices, by: .source)
        #expect(bySource.map(\.title) == ["Add-on A", "Add-on B"])
        #expect(bySource[1].choices.map(\.id) == ["b#0", "b#1", "b#2"])
        #expect(StreamGroup.groups(of: [], by: .quality).isEmpty)
        // With no quality known at all, the one group is not called "Other".
        #expect(StreamGroup.groups(of: [choices[2]], by: .quality).map(\.title) == ["Streams"])
    }

    @Test("The stream most like last time's: same add-on and release group, else same add-on and quality")
    func lastChoice() throws {
        let played = try choice(#"{"infoHash": "abcdef0123456789abcdef0123456789abcdef01", "name": "1080p", "behaviorHints": {"bingeGroup": "grp-1080"}}"#)
        let last = LastStreamChoice(played)
        let nextEpisode = try [
            choice(#"{"infoHash": "1111111111111111111111111111111111111111", "name": "1080p", "behaviorHints": {"bingeGroup": "other"}}"#, position: 0),
            choice(#"{"infoHash": "2222222222222222222222222222222222222222", "name": "720p", "behaviorHints": {"bingeGroup": "grp-1080"}}"#, position: 1),
            choice(
                #"{"infoHash": "3333333333333333333333333333333333333333", "name": "1080p", "behaviorHints": {"bingeGroup": "grp-1080"}}"#,
                addon: "b",
                position: 0
            ),
        ]
        // The group wins over the quality label; another add-on's identical group does not count.
        #expect(last.bestMatch(in: nextEpisode)?.id == "a#1")
        // No such group this time: same add-on, same quality, same kind.
        #expect(last.bestMatch(in: [nextEpisode[0], nextEpisode[2]])?.id == "a#0")
        #expect(last.bestMatch(in: [nextEpisode[2]]) == nil)
        let direct = try choice(#"{"url": "https://e.com/x", "name": "1080p"}"#)
        #expect(last.bestMatch(in: [direct]) == nil)
        // Survives being stored.
        #expect(try JSONDecoder().decode(LastStreamChoice.self, from: JSONEncoder().encode(last)) == last)
    }
}
