import Foundation
import MediaCore

/// Synthetic add-on responses, shaped like real ones but with invented content.
public enum AddonFixtures {
    /// A metadata add-on with two movie catalogs, one series catalog and a `meta` resource.
    public static func manifestJSON(id: String = "test.catalog", name: String = "Test Catalog") -> String {
        """
        {
          "id": "\(id)",
          "version": "1.2.3",
          "name": "\(name)",
          "description": "Synthetic add-on for tests",
          "resources": ["catalog", "meta"],
          "types": ["movie", "series"],
          "idPrefixes": ["tt"],
          "catalogs": [
            {
              "type": "movie", "id": "top", "name": "Popular",
              "extra": [
                {"name": "genre", "options": ["Action", "Drama", "Sci-Fi"]},
                {"name": "search"},
                {"name": "skip"}
              ]
            },
            {
              "type": "movie", "id": "year", "name": "New",
              "extra": [
                {"name": "genre", "isRequired": true, "options": ["2026", "2025", "2024"]},
                {"name": "skip"}
              ]
            },
            {
              "type": "series", "id": "top", "name": "Popular",
              "extra": [{"name": "genre", "options": ["Comedy", "Drama"]}, {"name": "search"}, {"name": "skip"}]
            },
            {
              "type": "series", "id": "calendar-videos", "name": "Calendar videos",
              "extra": [{"name": "calendarVideosIds", "isRequired": true, "optionsLimit": 100}]
            }
          ]
        }
        """
    }

    /// A catalog page of `count` items numbered from `offset + 1`.
    public static func catalogJSON(
        type: String = "movie",
        titlePrefix: String = "Title",
        count: Int,
        offset: Int = 0,
        hasMore: Bool? = nil
    ) -> String {
        let items = (offset + 1 ... max(offset + count, offset + 1)).prefix(count).map { number in
            """
            {"id": "tt\(String(format: "%07d", number))", "type": "\(type)", "name": "\(titlePrefix) \(number)",
             "poster": "https://images.example.com/poster/\(number).jpg", "releaseInfo": "\(2000 + number % 25)",
             "imdbRating": "\(Double(number % 90) / 10 + 1)"}
            """
        }
        let more = hasMore.map { ", \"hasMore\": \($0)" } ?? ""
        return "{\"metas\": [\(items.joined(separator: ","))]\(more)}"
    }

    /// Full metadata for a series with two seasons and a special.
    public static func seriesMetaJSON(id: String = "tt0000042", name: String = "Example Show") -> String {
        """
        {"meta": {
          "id": "\(id)", "type": "series", "name": "\(name)",
          "poster": "https://images.example.com/poster/42.jpg",
          "background": "https://images.example.com/background/42.jpg",
          "description": "An invented series used in tests.",
          "releaseInfo": "2019–2021", "imdbRating": "8.1", "runtime": "45 min",
          "genres": ["Drama", "Mystery"],
          "cast": ["Ada Example", "Bo Sample"], "director": ["Cy Placeholder"],
          "trailerStreams": [{"title": "\(name)", "ytId": "abcdefghijk"}],
          "videos": [
            {"id": "\(id):0:1", "name": "Behind the Scenes", "season": 0, "number": 1, "firstAired": "2019-01-01T00:00:00.000Z"},
            {"id": "\(id):1:1", "name": "Pilot", "season": 1, "episode": 1, "released": "2019-03-01T00:00:00.000Z",
             "overview": "It begins.", "thumbnail": "https://images.example.com/ep/1-1.jpg"},
            {"id": "\(id):1:2", "name": "Second", "season": 1, "episode": 2, "released": "2019-03-08T00:00:00.000Z"},
            {"id": "\(id):2:1", "name": "Return", "season": 2, "episode": 1, "released": "2021-05-01T00:00:00.000Z"}
          ]
        }}
        """
    }

    /// Full metadata for a movie.
    public static func movieMetaJSON(id: String = "tt0000001", name: String = "Example Movie") -> String {
        """
        {"meta": {
          "id": "\(id)", "type": "movie", "name": "\(name)",
          "poster": "https://images.example.com/poster/1.jpg",
          "background": "https://images.example.com/background/1.jpg",
          "description": "An invented movie used in tests.",
          "releaseInfo": "2001", "released": "2001-06-15T00:00:00.000Z",
          "imdbRating": "7.4", "runtime": "118 min",
          "genre": ["Adventure"],
          "links": [
            {"name": "Ada Example", "category": "Cast", "url": "stremio:///search?search=Ada%20Example"},
            {"name": "Cy Placeholder", "category": "Directors", "url": "stremio:///search?search=Cy%20Placeholder"},
            {"name": "7.4", "category": "imdb", "url": "https://imdb.com/title/\(id)"}
          ],
          "trailers": [{"source": "zyxwvutsrqp", "type": "Trailer"}, {"source": "clipclipcli", "type": "Clip"}],
          "behaviorHints": {"defaultVideoId": "\(id)"}
        }}
        """
    }
}
