import AppKit
import SwiftUI

/// The player's content: the video, a status overlay, and controls that fade away during playback.
public struct PlayerView: View {
    private let model: PlayerModel
    @Bindable private var chrome: PlayerChromeModel
    private let toggleFullScreen: () -> Void

    public init(model: PlayerModel, chrome: PlayerChromeModel, toggleFullScreen: @escaping () -> Void) {
        self.model = model
        self.chrome = chrome
        self.toggleFullScreen = toggleFullScreen
    }

    public var body: some View {
        ZStack {
            Color.black
            if let surface = model.surface {
                PlayerSurface(surface: surface)
            }
            PlayerStatusOverlay(state: model.state)

            VStack {
                Spacer()
                if chrome.isVisible {
                    PlayerControls(model: model, chrome: chrome, toggleFullScreen: toggleFullScreen)
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
                PlayerSettingsPanel(model: model, chrome: chrome)
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
        // The video runs under the title bar; the controls keep clear of it by sitting at the bottom.
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: toggleFullScreen)
        .onContinuousHover { phase in
            if case .active = phase {
                chrome.userDidInteract()
            }
        }
        .onChange(of: model.state.isAdvancing, initial: true) { _, isAdvancing in
            chrome.playbackChanged(isPlaying: isAdvancing)
        }
        .onChange(of: chrome.isVisible) { _, isVisible in
            if !isVisible {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chrome.isVisible)
        .preferredColorScheme(.dark)
    }
}

/// A busy indicator while opening or stalled, and the message when playback fails.
private struct PlayerStatusOverlay: View {
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
