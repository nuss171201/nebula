import SwiftUI

struct AudioSettingsTab: View {
    @Bindable var model: PlayerModel

    var body: some View {
        SettingsSection(title: "Audio Track") {
            TrackList(model: model, kind: .audio)
            if let problem = model.audioProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        SettingsSection(title: "Timing") {
            DelayControl(label: "Delay", delay: $model.audio.delay, range: AudioSettings.delayRange)
        }

        SettingsSection(title: "Equaliser") {
            Toggle("Enabled", isOn: $model.audio.equalizer.isEnabled)
            Picker("Preset", selection: presetBinding) {
                Text("Custom").tag(String?.none)
                ForEach(AudioSettings.Equalizer.presets) { preset in
                    Text(preset.name).tag(Optional(preset.name))
                }
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(AudioSettings.Equalizer.frequencies.indices, id: \.self) { index in
                    EqualizerBand(
                        gain: $model.audio.equalizer.gains[index],
                        frequency: AudioSettings.Equalizer.frequencies[index]
                    )
                }
            }
            .disabled(!model.audio.equalizer.isEnabled)
            .opacity(model.audio.equalizer.isEnabled ? 1 : 0.5)
        }

        SettingsSection(title: "Loudness") {
            Toggle("Even out loud and quiet passages", isOn: $model.audio.isNormalizingLoudness)
        }

        SettingsSection(title: "Output") {
            Toggle("Mix surround sound down to stereo", isOn: $model.audio.isDownmixingToStereo)
            Toggle("Keep the pitch when changing speed", isOn: $model.audio.keepsPitch)
        }
    }

    /// The preset whose gains match the current ones, if any.
    private var presetBinding: Binding<String?> {
        Binding {
            AudioSettings.Equalizer.presets.first { $0.gains == model.audio.equalizer.gains }?.name
        } set: { name in
            guard let preset = AudioSettings.Equalizer.presets.first(where: { $0.name == name }) else { return }
            model.audio.equalizer.gains = preset.gains
            if preset.gains.contains(where: { $0 != 0 }) {
                model.audio.equalizer.isEnabled = true
            }
        }
    }
}

/// One vertical band of the equaliser.
private struct EqualizerBand: View {
    @Binding var gain: Double
    let frequency: Int

    private var frequencyLabel: String {
        frequency >= 1000 ? "\(frequency / 1000)k" : "\(frequency)"
    }

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: $gain, in: AudioSettings.Equalizer.gainRange, step: 0.5)
                .rotationEffect(.degrees(-90))
                .frame(width: 96, height: 22)
                .frame(width: 22, height: 96)
                .accessibilityLabel("\(frequencyLabel) hertz")
                .accessibilityValue(String(format: "%+.1f decibels", gain))
            Text(frequencyLabel)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
