import AddonTestSupport
import Foundation
@testable import MediaCore
import Testing

@Suite("Meta, stream and subtitle parsing")
struct MetaDecodingTests {
    private struct MetaBox: Decodable {
        let meta: MetaItem
    }

    private func meta(_ json: String) throws -> MetaItem {
        try JSONDecoder().decode(MetaBox.self, from: Data(json.utf8)).meta
    }

    private func decode<Value: Decodable>(_: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    @Test("Reads a series with seasons, episodes and a trailer")
    func series() throws {
        let item = try meta(AddonFixtures.seriesMetaJSON())
        #expect(item.type == .series)
        #expect(item.name == "Example Show")
        #expect(item.imdbRating == 8.1)
        #expect(item.runtime == "45 min")
        #expect(item.genres == ["Drama", "Mystery"])
        #expect(item.cast == ["Ada Example", "Bo Sample"])
        #expect(item.directors == ["Cy Placeholder"])
        #expect(item.trailers == [MetaTrailer(youTubeID: "abcdefghijk", title: "Example Show")])
        #expect(item.videos.count == 4)

        let special = item.videos[0]
        #expect(special.title == "Behind the Scenes")
        #expect(special.season == 0)
        #expect(special.episode == 1)
        #expect(special.released != nil)

        let pilot = item.videos[1]
        #expect(pilot.id == "tt0000042:1:1")
        #expect(pilot.overview == "It begins.")
        #expect(pilot.thumbnail?.absoluteString == "https://images.example.com/ep/1-1.jpg")
    }

    @Test("Reads a movie whose people come from links and whose genres use the legacy key")
    func movie() throws {
        let item = try meta(AddonFixtures.movieMetaJSON())
        #expect(item.genres == ["Adventure"])
        #expect(item.cast == ["Ada Example"])
        #expect(item.directors == ["Cy Placeholder"])
        #expect(item.writers.isEmpty)
        #expect(item.trailers.map(\.youTubeID) == ["zyxwvutsrqp"])
        #expect(item.defaultVideoID == "tt0000001")
        #expect(item.links.count == 3)

        let released = try #require(item.released)
        let components = Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: released)
        #expect(components.year == 2001)
        #expect(components.month == 6)
        #expect(components.day == 15)
    }

    @Test("Tolerates loosely typed fields")
    func looseTypes() throws {
        let item = try meta("""
        {"meta": {"id": 12345, "type": "movie", "name": "  Loose  ", "imdbRating": 7, "year": 1999,
                  "poster": "//images.example.com/p.jpg", "background": "not a url", "logo": "ftp://x/y.png",
                  "genres": "Drama", "cast": ["A", "", 5, "B"], "posterShape": "landscape",
                  "released": "1999-03-31", "videos": [{"id": "v1", "season": "2", "episode": "3"}, {"noid": 1}],
                  "description": "   "}}
        """)
        #expect(item.id == "12345")
        #expect(item.name == "Loose")
        #expect(item.imdbRating == 7)
        #expect(item.releaseInfo == "1999")
        #expect(item.poster?.absoluteString == "https://images.example.com/p.jpg")
        #expect(item.background == nil)
        #expect(item.logo == nil)
        #expect(item.genres == ["Drama"])
        #expect(item.cast == ["A", "B"])
        #expect(item.posterShape == .landscape)
        #expect(item.released != nil)
        #expect(item.description == nil)
        #expect(item.videos.count == 1)
        #expect(item.videos[0].season == 2)
        #expect(item.videos[0].episode == 3)
        #expect(item.videos[0].title == "Episode 3")
    }

    @Test("Items without an id, type or name are rejected", arguments: [
        #"{"meta": {"type": "movie", "name": "x"}}"#,
        #"{"meta": {"id": "tt1", "name": "x"}}"#,
        #"{"meta": {"id": "tt1", "type": "movie", "name": ""}}"#,
    ])
    func rejects(json: String) {
        #expect(throws: (any Error).self) {
            try meta(json)
        }
    }

    @Test("Poster shapes have the expected proportions")
    func posterShapes() {
        #expect(PosterShape.poster.aspectRatio < 1)
        #expect(PosterShape.landscape.aspectRatio > 1)
        #expect(PosterShape.square.aspectRatio == 1)
    }

    @Test("Each kind of stream source is recognised and unusable streams are dropped")
    func streams() throws {
        struct Box: Decodable {
            let streams: [Failable<StreamItem>]
        }
        let box = try decode(Box.self, """
        {"streams": [
          {"url": "https://cdn.example.com/video.mp4", "name": "1080p", "description": "Direct file",
           "behaviorHints": {"notWebReady": true, "bingeGroup": "g1", "videoSize": "734003200", "filename": "video.mp4",
                             "proxyHeaders": {"request": {"Referer": "https://example.com"}}},
           "subtitles": [{"id": "s1", "url": "https://subs.example.com/1.srt", "lang": "eng"}, {"url": "file:///x.srt"}]},
          {"ytId": "abcdefghijk", "title": "Trailer"},
          {"infoHash": "ABCDEF0123456789ABCDEF0123456789ABCDEF01", "fileIdx": 2, "sources": ["tracker:udp://t.example.com:80", "dht:abc"]},
          {"externalUrl": "https://example.com/watch"},
          {"infoHash": "tooshort"},
          {"name": "nothing playable"}
        ]}
        """)
        let streams = box.streams.compactMap(\.value)
        #expect(streams.count == 4)

        #expect(try streams[0].source == .url(#require(URL(string: "https://cdn.example.com/video.mp4"))))
        #expect(streams[0].name == "1080p")
        #expect(streams[0].details == "Direct file")
        #expect(streams[0].behaviorHints.notWebReady)
        #expect(streams[0].behaviorHints.bingeGroup == "g1")
        #expect(streams[0].behaviorHints.videoSize == 734_003_200)
        #expect(streams[0].behaviorHints.requestHeaders == ["Referer": "https://example.com"])
        #expect(streams[0].subtitles.map(\.language) == ["eng"])

        #expect(streams[1].source == .youTube(id: "abcdefghijk"))
        #expect(streams[1].details == "Trailer")
        #expect(streams[2].source == .torrent(infoHash: "abcdef0123456789abcdef0123456789abcdef01", fileIndex: 2))
        #expect(streams[2].peerSources.count == 2)
        #expect(try streams[3].source == .external(#require(URL(string: "https://example.com/watch"))))
    }

    @Test("Subtitles need an http(s) URL and default to an undetermined language")
    func subtitles() throws {
        let subtitle = try decode(SubtitleItem.self, #"{"url": "https://subs.example.com/a.vtt"}"#)
        #expect(subtitle.language == "und")
        #expect(subtitle.id == "https://subs.example.com/a.vtt")
        #expect(subtitle.releaseName == nil)

        // Not in the protocol, but widely sent: what release the subtitle was timed for.
        let named = try decode(SubtitleItem.self, #"""
        {"id": 7, "url": "https://subs.example.com/7", "lang": "pob", "movieReleaseName": " Film.1968.BluRay ", "subtitleFileName": "film.srt"}
        """#)
        #expect(named.id == "7" && named.language == "pob")
        #expect(named.releaseName == "Film.1968.BluRay")
        let fileNamed = try decode(SubtitleItem.self, #"{"url": "https://subs.example.com/8", "movieReleaseName": "", "subtitleFileName": "film.srt"}"#)
        #expect(fileNamed.releaseName == "film.srt")
        #expect(throws: (any Error).self) {
            try decode(SubtitleItem.self, #"{"id": "x", "lang": "eng"}"#)
        }
    }

    @Test("Dates parse with and without fractional seconds", arguments: [
        "2010-07-15T00:00:00.000Z",
        "2010-07-15T00:00:00Z",
        "2010-07-15",
    ])
    func dates(text: String) throws {
        let date = try #require(LenientDate.parse(text))
        let year = Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: date).year
        #expect(year == 2010)
        #expect(LenientDate.parse("yesterday") == nil)
    }
}
