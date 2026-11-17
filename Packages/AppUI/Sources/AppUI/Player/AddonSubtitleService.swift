import CryptoKit
import Foundation
import MediaCore
import os
import PlayerKit

/// Subtitles for the player, from the add-ons the user has installed: titles are looked up
/// in searchable catalogs, subtitles come from add-ons with a `subtitles` resource, and
/// downloads are kept in a cache folder so that a subtitle is fetched once.
public final class AddonSubtitleService: OnlineSubtitleService {
    /// Subtitle files are text and small; anything larger is not a subtitle.
    static let maximumFileSize = 10 * 1024 * 1024
    static let maximumTitles = 20
    /// Cached downloads older than this are removed when a new one is saved.
    static let cacheLifetime: TimeInterval = 30 * 24 * 3600

    private let client: AddonClient
    private let http: any HTTPClient
    private let directory: URL
    private let addons = OSAllocatedUnfairLock(initialState: [InstalledAddon]())
    /// Subtitles that came with the stream being played, and the video they belong to.
    private let attached = OSAllocatedUnfairLock(initialState: (videoID: "", items: [SubtitleItem]()))
    /// What attached subtitles are listed as coming from.
    static let attachedProviderName = "This stream"

    /// - Parameters:
    ///   - http: Used to download subtitle files.
    ///   - directory: Where downloads are kept. Created when first needed.
    public init(client: AddonClient, http: any HTTPClient, directory: URL) {
        self.client = client
        self.http = http
        self.directory = directory
    }

    /// Tells the service which add-ons are installed. Call whenever they change.
    public func update(addons installed: [InstalledAddon]) {
        addons.withLock { $0 = installed }
    }

    /// Subtitles an add-on sent along with the stream that is about to play. They are listed
    /// first for that video: they were made for this very file, so their timing is the likeliest to fit.
    public func setAttached(_ items: [SubtitleItem], forVideo videoID: String) {
        attached.withLock { $0 = (videoID, items) }
    }

    // MARK: - OnlineSubtitleService

    public func titles(matching query: String) async throws(OnlineSubtitleError) -> [SubtitleTitleMatch] {
        let sources = addons.withLock { $0 }.catalogSources.filter(\.catalog.isSearchable)
        guard !sources.isEmpty else { throw .noProvider }

        let answers = await collect(sources) { [client] source throws(AddonError) in
            let request = CatalogRequest(
                type: source.catalog.type,
                catalogID: source.catalog.id,
                extra: [.init(ManifestCatalog.searchExtra, query)]
            )
            return try await client.catalog(request, from: source.addon.address).items
        }
        let items = try Self.merged(answers)

        var seen = Set<String>()
        let matches = items
            .filter { seen.insert("\($0.type.rawValue)|\($0.id)").inserted }
            .map { SubtitleTitleMatch(id: $0.id, type: $0.type, name: $0.name, year: $0.releaseInfo) }
        // A title spelled exactly as asked comes first; otherwise the catalogs' own order stands.
        let exact = matches.filter { $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let others = matches.filter { !exact.contains($0) }
        return Array((exact + others).prefix(Self.maximumTitles))
    }

    public func subtitles(for video: SubtitleVideo, file: SubtitleFileHints) async throws(OnlineSubtitleError) -> [OnlineSubtitle] {
        let fromStream = attached.withLock { $0.videoID == video.videoID ? $0.items : [] }.map { item in
            OnlineSubtitle(
                id: "stream|\(item.id)|\(item.url.absoluteString)",
                url: item.url,
                language: item.language,
                releaseName: item.releaseName,
                providerName: Self.attachedProviderName
            )
        }
        let providers = addons.withLock { $0 }.serving(resource: ManifestResource.subtitles, type: video.type, id: video.videoID)
        guard !providers.isEmpty else {
            if fromStream.isEmpty {
                throw .noProvider
            }
            return fromStream
        }

        var extra: [AddonResourcePath.Extra] = []
        if let fingerprint = file.fingerprint {
            extra.append(.init("videoHash", fingerprint.hash))
            extra.append(.init("videoSize", String(fingerprint.size)))
        }
        if let fileName = file.fileName, !fileName.isEmpty {
            extra.append(.init("filename", fileName))
        }
        let answers = await collect(providers) { [client, extra] addon throws(AddonError) in
            try await client.subtitles(type: video.type, videoID: video.videoID, extra: extra, from: addon.address).map { item in
                OnlineSubtitle(
                    id: "\(addon.id)|\(item.id)",
                    url: item.url,
                    language: item.language,
                    releaseName: item.releaseName,
                    providerName: addon.manifest.name
                )
            }
        }
        var seen = Set<String>()
        do {
            return try (fromStream + Self.merged(answers)).filter { seen.insert($0.id).inserted }
        } catch {
            // The stream's own subtitles are still there when every add-on is down.
            guard !fromStream.isEmpty, error != .cancelled else { throw error }
            return fromStream
        }
    }

    public func download(_ subtitle: OnlineSubtitle) async throws(OnlineSubtitleError) -> URL {
        let file = cacheFile(for: subtitle.url)
        if FileManager.default.fileExists(atPath: file.path) {
            return file
        }
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: subtitle.url, timeout: .seconds(30)))
        } catch {
            throw error == .cancelled ? .cancelled : .failed("The subtitle could not be downloaded. \(error.userMessage)")
        }
        guard !response.data.isEmpty, response.data.count <= Self.maximumFileSize else {
            throw .failed("The add-on did not send a usable subtitle file.")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try response.data.write(to: file, options: .atomic)
        } catch {
            throw .failed("The subtitle could not be saved: \(error.localizedDescription)")
        }
        removeExpiredFiles(keeping: file)
        return file
    }

    // MARK: - Helpers

    /// Asks every source at once and returns the answers in the sources' order.
    private func collect<Source: Sendable, Value: Sendable>(
        _ sources: [Source],
        _ fetch: @escaping @Sendable (Source) async throws(AddonError) -> [Value]
    ) async -> [Result<[Value], AddonError>] {
        await withTaskGroup(of: (Int, Result<[Value], AddonError>).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do throws(AddonError) {
                        return try await (index, .success(fetch(source)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var answers = [Result<[Value], AddonError>?](repeating: nil, count: sources.count)
            for await (index, answer) in group {
                answers[index] = answer
            }
            return answers.compactMap(\.self)
        }
    }

    /// Everything that was found. Fails only if every source failed: one add-on being down
    /// should not hide what the others have.
    private static func merged<Value>(_ answers: [Result<[Value], AddonError>]) throws(OnlineSubtitleError) -> [Value] {
        var values: [Value] = []
        var firstError: AddonError?
        var succeeded = false
        for answer in answers {
            switch answer {
            case let .success(found):
                succeeded = true
                values += found
            case let .failure(error):
                firstError = firstError ?? error
            }
        }
        if !succeeded, let firstError {
            throw firstError.isCancellation ? .cancelled : .failed(firstError.userMessage)
        }
        return values
    }

    /// Named after the address, so the same subtitle is found again; the extension helps
    /// the player recognise the format, and it reads the contents when the extension is wrong.
    func cacheFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let given = url.pathExtension.lowercased()
        let known = ["srt", "ass", "ssa", "vtt", "sub", "smi", "ttml"]
        return directory.appendingPathComponent(digest).appendingPathExtension(known.contains(given) ? given : "srt")
    }

    private func removeExpiredFiles(keeping kept: URL) {
        let files = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.cacheLifetime)
        let contents = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in contents where file.lastPathComponent != kept.lastPathComponent {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? files.removeItem(at: file)
            }
        }
    }
}
