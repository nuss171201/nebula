import SwiftUI

/// The bar at the bottom of the player: the seek bar with times on top; underneath, transport
/// and volume on the left, and speed, chapters, queue, extras, settings and full screen on the right.
struct PlayerControls: View {
    @Bindable var model: PlayerModel
    let chrome: PlayerChromeModel
    let perform: (PlayerCommand) -> Void

    private var state: PlaybackState {
        model.state
    }

    private var hasQueue: Bool {
        state.playlist.count > 1
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(PlaybackTime.format(model.displayPosition))
                    .monospacedDigit()
                    .fixedSize()
                SeekBar(model: model, chrome: chrome)
                Text(state.duration.map(PlaybackTime.format) ?? "--:--")
                    .monospacedDigit()
                    .fixedSize()
            }
            HStack(spacing: 14) {
                transport
                volume
                Spacer(minLength: 8)
                speedMenu
                if !state.chapters.isEmpty {
                    chapterMenu
                }
                Button {
                    chrome.isQueueVisible.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("Queue")
                .help("Queue")
                moreMenu
                Button {
                    chrome.toggleSettingsPanel(chrome.settingsTab)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Video, Audio and Subtitle Settings")
                .help("Video, Audio and Subtitle Settings")
                Button {
                    perform(.toggleFullScreen)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Toggle Full Screen")
                .help("Full Screen")
            }
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .font(.callout)
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .frame(maxWidth: 780)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    // MARK: - Left side

    @ViewBuilder private var transport: some View {
        if hasQueue {
            Button(action: model.playPrevious) {
                Image(systemName: "backward.end.fill")
            }
            .accessibilityLabel("Previous in Queue")
            .disabled(state.playlist.first?.isCurrent ?? true)
        }
        Button(action: model.togglePause) {
            Image(systemName: playSymbol)
                .font(.title3)
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(.white, in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(state.isAdvancing ? "Pause" : "Play")
        .disabled(!state.hasMedia)
        if hasQueue {
            Button(action: model.playNext) {
                Image(systemName: "forward.end.fill")
            }
            .accessibilityLabel("Next in Queue")
            .disabled(state.playlist.last?.isCurrent ?? true)
        }
    }

    @ViewBuilder private var volume: some View {
        Button(action: model.toggleMute) {
            Image(systemName: volumeSymbol)
                .frame(width: 22)
        }
        .accessibilityLabel(state.isMuted ? "Unmute" : "Mute")
        Slider(value: volumeBinding, in: 0 ... 100)
            .frame(width: 84)
            .accessibilityLabel("Volume")
    }

    // MARK: - Right side

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: speedBinding) {
                ForEach(PlaybackSpeed.menuChoices, id: \.self) { value in
                    Text(PlaybackSpeed(value).label).tag(value)
                }
                if !PlaybackSpeed.menuChoices.contains(model.speed.value) {
                    Text(model.speed.label).tag(model.speed.value)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(model.speed.label)
                .monospacedDigit()
                .fontWeight(model.speed == .normal ? .regular : .semibold)
        }
        .fixedSize()
        .accessibilityLabel("Speed")
        .accessibilityValue(model.speed.label)
        .help("Speed")
    }

    private var chapterMenu: some View {
        Menu {
            ForEach(state.chapters) { chapter in
                Button {
                    model.seek(toChapter: chapter.index)
                } label: {
                    // A check mark on the chapter being played, as menus do.
                    if chapter.index == state.currentChapter {
                        Label("\(chapter.title) — \(PlaybackTime.format(chapter.start))", systemImage: "checkmark")
                    } else {
                        Text("\(chapter.title) — \(PlaybackTime.format(chapter.start))")
                    }
                }
            }
        } label: {
            Image(systemName: "list.number")
        }
        .fixedSize()
        .accessibilityLabel("Chapters")
        .help("Chapters")
    }

    private var moreMenu: some View {
        Menu {
            Section("A-B Loop") {
                Button(loopActionTitle, action: model.cycleABLoop)
                    .disabled(!state.hasMedia)
            }
            Section("Frame by Frame") {
                Button("Next Frame", action: model.stepFrameForward)
                Button("Previous Frame", action: model.stepFrameBackward)
            }
            .disabled(!state.hasMedia)
            Section("Screenshot") {
                Button("Save Screenshot") {
                    Task { await model.saveScreenshot(includingSubtitles: true) }
                }
                Button("Save Screenshot Without Subtitles") {
                    Task { await model.saveScreenshot(includingSubtitles: false) }
                }
            }
            .disabled(!state.hasMedia || state.videoSize == nil)
            Picker("Repeat", selection: $model.repeatMode) {
                ForEach(RepeatMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Section("Window") {
                Button("Picture in Picture") {
                    perform(.togglePictureInPicture)
                }
                Button("Mini Player") {
                    perform(.toggleMiniPlayer)
                }
                Toggle("Always on Top", isOn: Binding {
                    chrome.isAlwaysOnTop
                } set: { _ in
                    perform(.toggleAlwaysOnTop)
                })
            }
        } label: {
            Image(systemName: model.abLoop == .off && model.repeatMode == .off ? "ellipsis.circle" : "ellipsis.circle.fill")
        }
        .fixedSize()
        .accessibilityLabel("More Playback Controls")
        .help("Loop, Frame Step, Screenshot, Repeat, Window")
    }

    private var loopActionTitle: String {
        switch model.abLoop {
        case .off: "Set Loop Start Here"
        case .startMarked: "Set Loop End Here"
        case .looping: "Clear Loop"
        }
    }

    // MARK: - Values

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

    private var speedBinding: Binding<Double> {
        Binding {
            model.speed.value
        } set: { value in
            model.speed = PlaybackSpeed(value)
        }
    }
}

/// The message that confirms a command, top left, for a moment.
struct PlayerNoticeView: View {
    let model: PlayerModel
    let notice: PlayerNotice

    var body: some View {
        Text(notice.text)
            .font(.title3.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .task(id: notice.id) {
                // Also read out, for people who cannot see it appear.
                AccessibilityNotification.Announcement(notice.text).post()
                try? await Task.sleep(for: .seconds(1.6))
                if !Task.isCancelled {
                    model.dismissNotice(notice.id)
                }
            }
    }
}

/// The offer to play the next thing, with its countdown and a way to take it or leave it.
struct UpNextCard: View {
    let offer: UpNextOffer
    let perform: (PlayerCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(offer.secondsRemaining > 0 ? "Up Next in \(offer.secondsRemaining)" : "Up Next")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(offer.title)
                .font(.headline)
                .lineLimit(2)
            if let detail = offer.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Button("Play Now") {
                    perform(.acceptUpNext)
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel") {
                    perform(.declineUpNext)
                }
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Up next: \(offer.title)")
    }
}
