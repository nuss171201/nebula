import SwiftUI

/// The tabs of the player's quick-settings panel.
public enum PlayerSettingsTab: String, CaseIterable, Identifiable, Sendable {
    case video, audio, subtitles

    public var id: Self { self }

    var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .subtitles: "Subtitles"
        }
    }
}

/// The side panel with everything that can be adjusted while watching.
struct PlayerSettingsPanel: View {
    @Bindable var model: PlayerModel
    @Bindable var chrome: PlayerChromeModel

    static let width: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Section", selection: $chrome.settingsTab) {
                    ForEach(PlayerSettingsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button {
                    chrome.isSettingsPanelVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close Settings")
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch chrome.settingsTab {
                    case .video: VideoSettingsTab(model: model)
                    case .audio: AudioSettingsTab(model: model)
                    case .subtitles: SubtitleSettingsTab(model: model)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .controlSize(.small)
    }
}

// MARK: - Building blocks shared by the tabs

/// A titled group of controls.
struct SettingsSection<Content: View>: View {
    let title: String
    var reset: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let reset {
                    Button("Reset", action: reset)
                        .buttonStyle(.borderless)
                }
            }
            content
        }
    }
}

/// A labelled slider with its current value on the right.
struct LabelledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let valueText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            if let step {
                Slider(value: $value, in: range, step: step)
                    .accessibilityLabel(label)
                    .accessibilityValue(valueText)
            } else {
                Slider(value: $value, in: range)
                    .accessibilityLabel(label)
                    .accessibilityValue(valueText)
            }
        }
    }
}

/// A delay with nudge buttons either side.
struct DelayControl: View {
    let label: String
    @Binding var delay: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            Button {
                nudge(-0.1)
            } label: {
                Image(systemName: "minus")
            }
            .accessibilityLabel("\(label) earlier")
            Text(formattedDelay(delay))
                .monospacedDigit()
                .frame(minWidth: 64)
            Button {
                nudge(0.1)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("\(label) later")
            Button("Reset") {
                delay = 0
            }
            .buttonStyle(.borderless)
            .disabled(delay == 0)
        }
    }

    private func nudge(_ amount: Double) {
        let moved = ((delay + amount) * 1000).rounded() / 1000
        delay = min(max(moved, range.lowerBound), range.upperBound)
    }
}

/// A list of tracks of one kind, one of which (or none) is selected.
struct TrackList: View {
    let model: PlayerModel
    let kind: MediaTrack.Kind
    /// Whether "Off" is offered.
    var allowsNone = false

    var body: some View {
        let tracks = model.state.tracks(of: kind)
        VStack(alignment: .leading, spacing: 2) {
            if allowsNone {
                row(title: "Off", detail: "", isSelected: !tracks.contains(where: \.isSelected)) {
                    model.selectTrack(kind, number: nil)
                }
            }
            ForEach(tracks) { track in
                row(title: track.displayName(), detail: track.detail, isSelected: track.isSelected) {
                    model.selectTrack(kind, number: track.number)
                }
            }
            if tracks.isEmpty, !allowsNone {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(title: String, detail: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .opacity(isSelected ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([title, detail].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
