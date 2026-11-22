import AppKit
import SwiftUI

/// The player's content, in whichever of its three forms the window is in: the video with
/// a status overlay and controls that fade away, a bare picture for picture in picture, or
/// the mini player's controls without a picture.
public struct PlayerView: View {
    private let model: PlayerModel
    @Bindable private var chrome: PlayerChromeModel
    private let onlineSubtitles: OnlineSubtitlesModel?
    private let openURLs: ([URL]) -> Void
    private let perform: (PlayerCommand) -> Void
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    /// Side panels slide in from the edge, or fade where the user has asked for less motion.
    private var panelTransition: AnyTransition {
        reducesMotion ? .opacity : .move(edge: .trailing)
    }

    /// - Parameters:
    ///   - openURLs: Called with files and folders dropped on the player.
    ///   - perform: Runs a command through the window, which handles the ones that concern it
    ///     (full screen, window modes) and passes the rest to the player.
    public init(
        model: PlayerModel,
        chrome: PlayerChromeModel,
        onlineSubtitles: OnlineSubtitlesModel? = nil,
        openURLs: @escaping ([URL]) -> Void = { _ in },
        perform: @escaping (PlayerCommand) -> Void
    ) {
        self.model = model
        self.chrome = chrome
        self.onlineSubtitles = onlineSubtitles
        self.openURLs = openURLs
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
        // Media dropped here plays; a subtitle file is added to what is playing.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            openURLs(files)
            return true
        }
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
            PlayerStatusOverlay(state: model.state, note: model.waitingNote, progress: model.waitingProgress)

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

            if let offer = model.upNext {
                UpNextCard(offer: offer, perform: perform)
                    .padding(.trailing, 24 + (chrome.isSidePanelVisible ? PlayerSettingsPanel.width : 0))
                    // Above the control bar.
                    .padding(.bottom, 118)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
            }

            if chrome.isSettingsPanelVisible {
                PlayerSettingsPanel(model: model, chrome: chrome, onlineSubtitles: onlineSubtitles)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(panelTransition)
            } else if chrome.isQueueVisible {
                PlayerQueuePanel(model: model, chrome: chrome)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(panelTransition)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chrome.isSidePanelVisible)
        .animation(.easeInOut(duration: 0.15), value: model.notice)
        .animation(.easeInOut(duration: 0.2), value: model.upNext != nil)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            perform(.toggleFullScreen)
        }
    }
}
