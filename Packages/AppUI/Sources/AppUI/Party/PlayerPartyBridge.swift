import Foundation
import PlayerKit
import WatchParty

/// The app's player, as a watch party sees it: what it is doing, a way to steer it, and word of
/// what the person at this Mac does with it. There is one bridge for the app; the player behind
/// it comes and goes as its window is opened and closed.
@MainActor
final class PlayerPartyBridge: PartyPlayback {
    var onIntent: (@MainActor (LocalIntent) -> Void)?

    private let coordinator: PlayerCoordinator
    private let streamPlayer: StreamPlayer?
    private weak var hooked: PlayerModel?

    init(coordinator: PlayerCoordinator, streamPlayer: StreamPlayer?) {
        self.coordinator = coordinator
        self.streamPlayer = streamPlayer
    }

    var snapshot: PlaybackSnapshot {
        guard let player = coordinator.player, let source = player.source else { return .none }
        hook(player)
        let state = player.state
        return PlaybackSnapshot(
            content: content(of: source, in: player),
            hasMedia: state.hasMedia,
            isPaused: state.isPaused,
            isStalled: state.hasMedia && Self.isStalled(state, isLocalFile: source.isLocalFile),
            hasPendingJump: player.hasPendingUserSeek,
            hasEnded: state.phase == .ended,
            position: state.position,
            duration: state.duration,
            rate: player.speed.value
        )
    }

    /// Whether the picture cannot advance right now. A stream that is paused with next to nothing
    /// buffered counts too: it would stall the moment it was resumed, and a party that is waiting
    /// for someone should wait until they can really play.
    static func isStalled(_ state: PlaybackState, isLocalFile: Bool) -> Bool {
        if state.isWaitingForData || state.isSeeking {
            return true
        }
        guard state.isPaused, !isLocalFile, state.phase == .playing, let buffered = state.bufferedAhead else { return false }
        let remaining = state.duration.map { $0 - state.position } ?? .greatestFiniteMagnitude
        return buffered < 2 && remaining > 3
    }

    /// What the player has open: the catalog's video if it was played from a title's page,
    /// otherwise the file by its name. Never where it is played from.
    private func content(of source: PlayableSource, in player: PlayerModel) -> PartyContent {
        if let streamPlayer, let video = streamPlayer.nowPlaying, streamPlayer.nowPlayingURL == source.url {
            return PartyContent(
                key: WatchKey.make(type: video.type, videoID: video.videoID),
                title: video.title,
                catalog: .init(type: video.type.rawValue, titleID: video.titleID, videoID: video.videoID)
            )
        }
        return PartyContent(key: "file:" + source.displayName.lowercased(), title: source.isLocalFile ? source.displayName : player.title)
    }

    private func hook(_ player: PlayerModel) {
        guard hooked !== player else { return }
        hooked?.onPlaybackIntent = nil
        hooked = player
        player.onPlaybackIntent = { [weak self] intent in
            guard let self else { return }
            switch intent {
            case let .setPaused(isPaused): onIntent?(.setPaused(isPaused))
            case let .seeked(position): onIntent?(.seeked(to: position))
            case let .speed(rate): onIntent?(.rate(rate))
            }
        }
    }

    func apply(_ directive: PlayerDirective) {
        guard let player = coordinator.player else { return }
        player.followingExternal {
            switch directive {
            case let .setPaused(isPaused):
                player.setPaused(isPaused)
            case let .seek(to: position):
                player.seek(to: position)
            case let .setRate(rate):
                player.speed = PlaybackSpeed(rate)
            case let .adjustRate(factor):
                player.speedAdjustment = factor
            }
        }
    }

    func showNotice(_ text: String) {
        coordinator.player?.announce(text)
    }
}
