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
            .padding(.trailing, chrome.isSettingsPanelVisible ? PlayerSettingsPanel.width : 0)

            if chrome.isSettingsPanelVisible {
                PlayerSettingsPanel(model: model, chrome: chrome)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chrome.isSettingsPanelVisible)
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

/// Play/pause, the seek bar with times, volume, and full screen.
private struct PlayerControls: View {
    let model: PlayerModel
    let chrome: PlayerChromeModel
    let toggleFullScreen: () -> Void

    private var state: PlaybackState {
        model.state
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: model.togglePause) {
                Image(systemName: playSymbol)
                    .font(.title2)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(state.isAdvancing ? "Pause" : "Play")
            .disabled(!state.hasMedia)

            Text(PlaybackTime.format(model.displayPosition))
                .monospacedDigit()
                .fixedSize()

            SeekBar(model: model, chrome: chrome)

            Text(state.duration.map(PlaybackTime.format) ?? "--:--")
                .monospacedDigit()
                .fixedSize()

            Button(action: model.toggleMute) {
                Image(systemName: volumeSymbol)
                    .frame(width: 22)
            }
            .accessibilityLabel(state.isMuted ? "Unmute" : "Mute")

            Slider(value: volumeBinding, in: 0 ... 100)
                .frame(width: 84)
                .accessibilityLabel("Volume")

            Button {
                chrome.toggleSettingsPanel(chrome.settingsTab)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Video, Audio and Subtitle Settings")

            Button(action: toggleFullScreen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel("Toggle Full Screen")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 780)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    private var playSymbol: String {
        if state.phase == .ended {
            "arrow.counterclockwise"
        } else {
            state.isPaused ? "play.fill" : "pause.fill"
        }
    }

    private var volumeSymbol: String {
        if state.isMuted || state.volume == 0 {
            "speaker.slash.fill"
        } else if state.volume < 34 {
            "speaker.wave.1.fill"
        } else if state.volume < 67 {
            "speaker.wave.2.fill"
        } else {
            "speaker.wave.3.fill"
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding {
            state.isMuted ? 0 : state.volume
        } set: { volume in
            model.setVolume(volume)
        }
    }
}
