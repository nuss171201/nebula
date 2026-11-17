import Foundation
import MediaCore
import MediaLibrary
import Observation
import PlayerKit

/// When an episode ends, offers the next one in the player and starts it after a countdown.
///
/// The next episode is only offered when it has aired and one of its streams is like the
/// one that was being watched (same add-on and release group, or same add-on and quality):
/// carrying on should not mean ending up on a different kind of source without being asked.
@MainActor
@Observable
public final class NextEpisodeController {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Whether episodes follow one another by themselves. A setting, from Stage 7.
    public var isEnabled = true
    /// Seconds between an episode ending and the next one starting.
    public var countdown = 10

    @ObservationIgnored private let coordinator: PlayerCoordinator
    @ObservationIgnored private let streamPlayer: StreamPlayer
    @ObservationIgnored private let client: AddonClient
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var addons: [InstalledAddon] = []
    /// Episode lists already fetched, by series id.
    @ObservationIgnored private var episodes: [String: [MetaVideo]] = [:]
    @ObservationIgnored private var offerTask: Task<Void, Never>?
    /// The video the standing offer (or the search for one) follows.
    @ObservationIgnored private var offeredAfter: String?
    @ObservationIgnored private var pending: (choice: StreamChoice, video: StreamVideo)?

    public init(
        coordinator: PlayerCoordinator,
        streamPlayer: StreamPlayer,
        client: AddonClient,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.coordinator = coordinator
        self.streamPlayer = streamPlayer
        self.client = client
        self.sleep = sleep
        coordinator.onUpNextDecision = { [weak self] isAccepted in
            self?.decide(isAccepted)
        }
        watch()
    }

    public func update(addons: [InstalledAddon]) {
        self.addons = addons
    }

    /// Waits for the search or countdown in flight. For tests.
    func waitForOffer() async {
        await offerTask?.value
    }

    // MARK: - Following the player

    private func watch() {
        let (hasEnded, playing) = withObservationTracking {
            (coordinator.player?.state.phase == .ended, streamPlayer.nowPlaying?.videoID)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.watch()
            }
        }
        if hasEnded, let playing, isEnabled {
            if offeredAfter != playing {
                offeredAfter = playing
                startOffer()
            }
        } else if offeredAfter != nil {
            // Seeked back from the end, opened something else, or closed the player.
            withdraw()
        }
    }

    private func startOffer() {
        guard let current = streamPlayer.nowPlaying, let lastChoice = streamPlayer.nowPlayingChoice else { return }
        offerTask?.cancel()
        offerTask = Task { [weak self] in
            guard let self, let next = await findNext(after: current, like: lastChoice), !Task.isCancelled,
                  offeredAfter == current.videoID, let player = coordinator.player
            else { return }
            pending = next
            let title = ContinueItem(video: next.video.watchVideo, kind: .nextEpisode).episodeLine ?? next.video.title
            for remaining in stride(from: countdown, through: 1, by: -1) {
                player.upNext = UpNextOffer(title: title, detail: next.video.titleName, secondsRemaining: remaining)
                do {
                    try await sleep(.seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled, pending != nil else { return }
            }
            playPending()
        }
    }

    /// The next episode and the stream to play it from, or `nil` if there is no next episode
    /// that has aired, or none of its streams is like the last one.
    private func findNext(after current: StreamVideo, like lastChoice: StreamChoice) async -> (choice: StreamChoice, video: StreamVideo)? {
        guard let videos = await episodeList(of: current),
              let next = ContinueWatching.nextEpisode(after: current.watchVideo, in: videos)
        else { return nil }

        let providers = addons.serving(resource: ManifestResource.stream, type: current.type, id: next.id)
        var choices: [StreamChoice] = []
        await withTaskGroup(of: (Int, [StreamItem]).self) { group in
            for (index, addon) in providers.enumerated() {
                group.addTask { [client] in
                    await (index, (try? client.streams(type: current.type, videoID: next.id, from: addon.address)) ?? [])
                }
            }
            var answers: [Int: [StreamItem]] = [:]
            for await (index, streams) in group {
                answers[index] = streams
            }
            for index in answers.keys.sorted() {
                let addon = providers[index]
                choices += (answers[index] ?? []).enumerated().map { position, stream in
                    StreamChoice(stream: stream, addonID: addon.id, addonName: addon.manifest.name, position: position)
                }
            }
        }
        guard let choice = LastStreamChoice(lastChoice).bestMatch(in: choices) else { return nil }
        let video = StreamVideo(
            type: current.type,
            videoID: next.id,
            titleID: current.titleID,
            title: "\(current.titleName) — \(next.numberedTitle)",
            titleName: current.titleName,
            poster: current.poster,
            season: next.season,
            episode: next.episode,
            episodeTitle: next.title
        )
        return (choice, video)
    }

    private func episodeList(of video: StreamVideo) async -> [MetaVideo]? {
        if let known = episodes[video.titleID] {
            return known
        }
        for provider in addons.serving(resource: ManifestResource.meta, type: video.type, id: video.titleID) {
            if let meta = try? await client.meta(type: video.type, id: video.titleID, from: provider.address) {
                episodes[video.titleID] = meta.videos
                return meta.videos
            }
        }
        return nil
    }

    // MARK: - Answers

    /// The user's answer in the player: play it now, or leave it.
    private func decide(_ isAccepted: Bool) {
        if isAccepted {
            offerTask?.cancel()
            playPending()
        } else {
            // Declined for this episode: it is not offered again unless the episode ends again.
            offerTask?.cancel()
            pending = nil
            coordinator.player?.upNext = nil
        }
    }

    private func playPending() {
        guard let next = pending else { return }
        pending = nil
        coordinator.player?.upNext = nil
        // `offeredAfter` stays until the player has moved on: a torrent takes a moment to
        // start, and the finished episode must not be offered a second time meanwhile.
        streamPlayer.play(next.choice, for: next.video)
    }

    private func withdraw() {
        offerTask?.cancel()
        offerTask = nil
        pending = nil
        offeredAfter = nil
        coordinator.player?.upNext = nil
    }
}
