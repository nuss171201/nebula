import AppKit
import SwiftUI

/// The player's content, in whichever of its three forms the window is in: the video with
/// a status overlay and controls that fade away, a bare picture for picture in picture, or
/// the mini player's controls without a picture.
public struct PlayerView: View {
    private let model: PlayerModel
    @Bindable private var chrome: PlayerChromeModel
    private let onlineSubtitles: OnlineSubtitlesModel?
    private let perform: (PlayerCommand) -> Void

    /// - Parameter perform: Runs a command through the window, which handles the ones that
    ///   concern it (full screen, window modes) and passes the rest to the player.
    public init(
        model: PlayerModel,
        chrome: PlayerChromeModel,
        onlineSubtitles: OnlineSubtitlesModel? = nil,
        perform: @escaping (PlayerCommand) -> Void
    ) {
        self.model = model
        self.chrome = chrome
        self.onlineSubtitles = onlineSubtitles
        self.perform = perform
    }

    public var body: some View {
        Group {
            switch chrome.windowMode {
            case .standard:
                standard
            case .pictureInPicture:
                PictureInPictureView(model: model, chrome: chrome, perform: perform)
            case .mini:
                MiniPlayerView(model: model, chrome: chrome, perform: perform)
            }
        }
        // The content runs under the title bar.
        .ignoresSafeArea()
        .onContinuousHover { phase in
            if case .active = phase {
                chrome.userDidInteract()
            }
        }
        .onChange(of: model.state.isAdvancing, initial: true) { _, isAdvancing in
            chrome.playbackChanged(isPlaying: isAdvancing)
        }
        .onChange(of: chrome.isVisible) { _, isVisible in
            if !isVisible, chrome.windowMode != .mini {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chrome.isVisible)
        .preferredColorScheme(.dark)
    }

    private var standard: some View {
        ZStack {
            Color.black
            if let surface = model.surface {
                PlayerSurface(surface: surface)
            }
            PlayerStatusOverlay(state: model.state)

            VStack {
                Spacer()
                if chrome.isVisible {
                    PlayerControls(model: model, chrome: chrome, perform: perform)
                        .onHover { chrome.pointerIsOnControls($0) }
                        .transition(.opacity)
                }
            }
            .padding(.trailing, chrome.isSidePanelVisible ? PlayerSettingsPanel.width : 0)

            if let notice = model.notice {
                PlayerNoticeView(model: model, notice: notice)
                    // Below the title bar's buttons.
                    .padding(.top, 44)
                    .padding(.leading, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if chrome.isSettingsPanelVisible {
                PlayerSettingsPanel(model: model, chrome: chrome, onlineSubtitles: onlineSubtitles)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing))
            } else if chrome.isQueueVisible {
                PlayerQueuePanel(model: model, chrome: chrome)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chrome.isSidePanelVisible)
        .animation(.easeInOut(duration: 0.15), value: model.notice)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            perform(.toggleFullScreen)
        }
    }
}

/// A busy indicator while opening or stalled, and the message when playback fails.
struct PlayerStatusOverlay: View {
    let state: PlaybackState

    var body: some View {
        if case let .failed(message) = state.phase {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                Text(message)
                    .font(.title3)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: 520)
            .accessibilityElement(children: .combine)
        } else if state.isBusy {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(state.phase == .loading ? "Opening" : "Buffering")
        }
    }
}
