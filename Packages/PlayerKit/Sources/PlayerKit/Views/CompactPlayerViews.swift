import SwiftUI

/// Picture in picture: just the picture. Moving the pointer over it brings up play/pause,
/// a thin seek bar, and buttons to return to the normal window or close.
struct PictureInPictureView: View {
    let model: PlayerModel
    let chrome: PlayerChromeModel
    let perform: (PlayerCommand) -> Void

    var body: some View {
        ZStack {
            Color.black
            if let surface = model.surface {
                PlayerSurface(surface: surface)
            }
            PlayerStatusOverlay(state: model.state, note: model.waitingNote)
                .scaleEffect(0.7)
            if chrome.isVisible {
                overlay
                    .transition(.opacity)
            }
            if let offer = model.upNext {
                UpNextCard(offer: offer, perform: perform)
                    .scaleEffect(0.8)
            }
        }
        .onHover { chrome.pointerIsOnControls($0) }
    }

    private var overlay: some View {
        ZStack {
            // Darkens the picture so the white controls can be seen on any content.
            Color.black.opacity(0.35)
                .allowsHitTesting(false)
            Button(action: model.togglePause) {
                Image(systemName: model.state.isPaused || model.state.phase == .ended ? "play.fill" : "pause.fill")
                    .font(.system(size: 30))
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(model.state.isAdvancing ? "Pause" : "Play")
            .disabled(!model.state.hasMedia)

            VStack {
                HStack {
                    Button {
                        perform(.togglePictureInPicture)
                    } label: {
                        Image(systemName: "pip.exit")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Return to the Player Window")
                    .help("Return to the Player Window")
                    Spacer()
                    Button {
                        perform(.closePlayer)
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close")
                    .help("Close")
                }
                Spacer()
                SeekBar(model: model, chrome: chrome, showsPreview: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .font(.title3)
        .foregroundStyle(.white)
    }
}

/// The mini player: what is playing, a seek bar and transport controls, and no picture.
struct MiniPlayerView: View {
    let model: PlayerModel
    let chrome: PlayerChromeModel
    let perform: (PlayerCommand) -> Void

    private var state: PlaybackState {
        model.state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(model.title.isEmpty ? "Nothing Playing" : model.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(PlaybackTime.format(model.displayPosition)) / \(state.duration.map(PlaybackTime.format) ?? "--:--")")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            // Clear of the window's close, minimise and zoom buttons.
            .padding(.leading, 62)

            SeekBar(model: model, chrome: chrome, showsPreview: false)

            HStack(spacing: 14) {
                if state.playlist.count > 1 {
                    Button(action: model.playPrevious) {
                        Image(systemName: "backward.end.fill")
                    }
                    .accessibilityLabel("Previous in Queue")
                    .disabled(state.playlist.first?.isCurrent ?? true)
                }
                Button(action: model.togglePause) {
                    Image(systemName: state.phase == .ended ? "arrow.counterclockwise" : (state.isPaused ? "play.fill" : "pause.fill"))
                        .font(.title2)
                        .frame(width: 26, height: 26)
                }
                .accessibilityLabel(state.isAdvancing ? "Pause" : "Play")
                .disabled(!state.hasMedia)
                if state.playlist.count > 1 {
                    Button(action: model.playNext) {
                        Image(systemName: "forward.end.fill")
                    }
                    .accessibilityLabel("Next in Queue")
                    .disabled(state.playlist.last?.isCurrent ?? true)
                }
                Button(action: model.toggleMute) {
                    Image(systemName: state.isMuted || state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 22)
                }
                .accessibilityLabel(state.isMuted ? "Unmute" : "Mute")
                Slider(value: Binding {
                    state.isMuted ? 0 : state.volume
                } set: { volume in
                    model.setVolume(volume)
                }, in: 0 ... 100)
                    .frame(width: 90)
                    .accessibilityLabel("Volume")
                Spacer(minLength: 8)
                Button {
                    perform(.toggleAlwaysOnTop)
                } label: {
                    Image(systemName: chrome.isAlwaysOnTop ? "pin.fill" : "pin")
                }
                .accessibilityLabel("Always on Top")
                .accessibilityAddTraits(chrome.isAlwaysOnTop ? .isSelected : [])
                .help("Always on Top")
                Button {
                    perform(.toggleMiniPlayer)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Return to the Player Window")
                .help("Return to the Player Window")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}
