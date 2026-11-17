import Foundation
import MediaCore
import Observation

/// Finding subtitles on the network for what is playing: say what the file is (the name is
/// guessed from the file name), pick the title, then pick a subtitle, which is downloaded and shown.
@MainActor
@Observable
public final class OnlineSubtitlesModel {
    public enum TitlePhase: Sendable, Equatable {
        case idle
        case searching
        case results([SubtitleTitleMatch])
        case failed(String)
    }

    public enum SubtitlePhase: Sendable, Equatable {
        case idle
        case searching
        case results([SubtitleLanguageGroup])
        case failed(String)
    }

    /// What to look the file up as. Filled in from the file name; the user can correct it.
    public var query = ""
    public private(set) var titlePhase = TitlePhase.idle
    /// The title the user picked; `nil` while still searching for it.
    public private(set) var chosenTitle: SubtitleTitleMatch?
    /// For series. Changing either looks for that episode's subtitles.
    public var season = 1 {
        didSet { episodeDidChange(from: oldValue, to: season) }
    }

    public var episode = 1 {
        didSet { episodeDidChange(from: oldValue, to: episode) }
    }

    public private(set) var subtitlePhase = SubtitlePhase.idle
    /// The subtitle being fetched, if any.
    public private(set) var downloadingID: String?
    /// Subtitles already added to the open file.
    public private(set) var addedIDs: Set<String> = []
    /// Why the last download failed.
    public private(set) var downloadError: String?

    @ObservationIgnored private weak var player: PlayerModel?
    @ObservationIgnored private let service: any OnlineSubtitleService
    @ObservationIgnored private let preferredLanguages: [String]
    @ObservationIgnored private var preparedFor: PlayableSource?
    @ObservationIgnored private var hints = SubtitleFileHints()
    @ObservationIgnored private var hintsTask: Task<SubtitleFileHints, Never>?
    @ObservationIgnored private var titleTask: Task<Void, Never>?
    @ObservationIgnored private var subtitleTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var isSettingEpisode = false

    /// - Parameter preferredLanguages: Languages to list first, most wanted first.
    public init(player: PlayerModel, service: any OnlineSubtitleService, preferredLanguages: [String]) {
        self.player = player
        self.service = service
        self.preferredLanguages = preferredLanguages
    }

    /// Gets ready for a file: forgets the previous file's results and guesses the title,
    /// season and episode from the name. Does nothing if this file is already prepared.
    public func prepare(for source: PlayableSource?) {
        guard source != preparedFor else { return }
        preparedFor = source
        [titleTask, subtitleTask, downloadTask].forEach { $0?.cancel() }
        titlePhase = .idle
        subtitlePhase = .idle
        chosenTitle = nil
        downloadingID = nil
        addedIDs = []
        downloadError = nil

        let guess = MediaNameGuess(fileName: source?.displayName ?? "")
        query = guess.title
        setEpisode(season: guess.season ?? 1, episode: guess.episode ?? 1)

        hints = SubtitleFileHints(fileName: source?.displayName)
        hintsTask = nil
        if let source, source.isLocalFile {
            // Reading the ends of the file takes a moment; done once, off the main thread.
            let (url, name) = (source.url, source.displayName)
            hintsTask = Task.detached(priority: .utility) {
                SubtitleFileHints(fileName: name, fingerprint: VideoFileHash.fingerprint(ofFileAt: url))
            }
        }
    }

    /// Looks up films and series named like `query`.
    public func searchTitles() {
        titleTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            titlePhase = .idle
            return
        }
        titlePhase = .searching
        titleTask = Task { [service] in
            do throws(OnlineSubtitleError) {
                let titles = try await service.titles(matching: text)
                guard !Task.isCancelled else { return }
                titlePhase = .results(titles)
            } catch {
                guard !Task.isCancelled, error != .cancelled else { return }
                titlePhase = .failed(error.userMessage)
            }
        }
    }

    /// Picks the title and looks for its subtitles straight away.
    public func choose(_ title: SubtitleTitleMatch) {
        chosenTitle = title
        findSubtitles()
    }

    /// Goes back to choosing a title.
    public func clearTitle() {
        subtitleTask?.cancel()
        chosenTitle = nil
        subtitlePhase = .idle
        downloadError = nil
    }

    /// Looks for subtitles for the chosen title (and episode).
    public func findSubtitles() {
        subtitleTask?.cancel()
        guard let title = chosenTitle else { return }
        let video = SubtitleVideo(title: title, season: season, episode: episode)
        subtitlePhase = .searching
        downloadError = nil
        subtitleTask = Task { [service, preferredLanguages] in
            if let hintsTask {
                hints = await hintsTask.value
            }
            guard !Task.isCancelled else { return }
            do throws(OnlineSubtitleError) {
                let found = try await service.subtitles(for: video, file: hints)
                guard !Task.isCancelled else { return }
                subtitlePhase = .results(SubtitleLanguageGroup.groups(of: found, preferredLanguages: preferredLanguages))
            } catch {
                guard !Task.isCancelled, error != .cancelled else { return }
                subtitlePhase = .failed(error.userMessage)
            }
        }
    }

    /// Downloads a subtitle, adds it to the open file and switches to it.
    public func use(_ subtitle: OnlineSubtitle) {
        guard downloadingID == nil else { return }
        downloadingID = subtitle.id
        downloadError = nil
        let source = preparedFor
        downloadTask = Task { [service] in
            defer { downloadingID = nil }
            do throws(OnlineSubtitleError) {
                let file = try await service.download(subtitle)
                // The file may have been replaced while this one was on its way.
                guard !Task.isCancelled, let player, player.source == source else { return }
                let language = LanguageMatcher.canonical(subtitle.language) ?? subtitle.language
                if await player.addSubtitle(fileURL: file, title: subtitle.releaseName ?? subtitle.providerName, language: language) {
                    addedIDs.insert(subtitle.id)
                } else {
                    downloadError = "The subtitle was downloaded but could not be read."
                }
            } catch {
                guard !Task.isCancelled, error != .cancelled else { return }
                downloadError = error.userMessage
            }
        }
    }

    /// Waits for whatever is in flight. For tests.
    func waitUntilIdle() async {
        await titleTask?.value
        await subtitleTask?.value
        await downloadTask?.value
    }

    private func setEpisode(season: Int, episode: Int) {
        isSettingEpisode = true
        self.season = season
        self.episode = episode
        isSettingEpisode = false
    }

    private func episodeDidChange(from old: Int, to new: Int) {
        guard old != new, !isSettingEpisode, chosenTitle?.type == .series else { return }
        findSubtitles()
    }
}
