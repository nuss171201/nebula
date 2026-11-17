import SwiftUI

struct VideoSettingsTab: View {
    @Bindable var model: PlayerModel

    var body: some View {
        if model.state.tracks(of: .video).count > 1 {
            SettingsSection(title: "Video Track") {
                TrackList(model: model, kind: .video)
            }
        }

        SettingsSection(title: "Speed", reset: model.speed == .normal ? nil : { model.speed = .normal }) {
            Picker("Speed", selection: speedBinding) {
                ForEach(PlaybackSpeed.menuChoices, id: \.self) { value in
                    Text(PlaybackSpeed(value).label).tag(value)
                }
                if !PlaybackSpeed.menuChoices.contains(model.speed.value) {
                    Text(model.speed.label).tag(model.speed.value)
                }
            }
            .labelsHidden()
        }

        SettingsSection(
            title: "Picture",
            reset: model.video.hasGeometryAdjustments ? { model.video.resetGeometry() } : nil
        ) {
            Picker("Aspect ratio", selection: $model.video.aspect) {
                ForEach(VideoSettings.Aspect.presets, id: \.self) { aspect in
                    Text(aspect.label).tag(aspect)
                }
            }
            Picker("Crop", selection: $model.video.crop) {
                ForEach(VideoSettings.Aspect.presets, id: \.self) { aspect in
                    Text(aspect == .source ? "None" : aspect.label).tag(aspect)
                }
            }
            HStack {
                Text("Rotate")
                    .font(.callout)
                Spacer()
                Button {
                    model.video.rotation = model.video.rotation.counterclockwise
                } label: {
                    Image(systemName: "rotate.left")
                }
                .accessibilityLabel("Rotate left")
                Text("\(model.video.rotation.rawValue)°")
                    .monospacedDigit()
                    .frame(minWidth: 40)
                Button {
                    model.video.rotation = model.video.rotation.clockwise
                } label: {
                    Image(systemName: "rotate.right")
                }
                .accessibilityLabel("Rotate right")
            }
            Toggle("Mirror horizontally", isOn: $model.video.isMirrored)
            Toggle("Flip vertically", isOn: $model.video.isFlipped)
            LabelledSlider(
                label: "Zoom",
                value: $model.video.zoom,
                range: VideoSettings.zoomRange,
                valueText: "\(Int((pow(2, model.video.zoom) * 100).rounded())) %"
            )
            LabelledSlider(
                label: "Move horizontally",
                value: $model.video.panX,
                range: VideoSettings.panRange,
                valueText: "\(Int((model.video.panX * 100).rounded())) %"
            )
            LabelledSlider(
                label: "Move vertically",
                value: $model.video.panY,
                range: VideoSettings.panRange,
                valueText: "\(Int((model.video.panY * 100).rounded())) %"
            )
        }

        SettingsSection(title: "Colour", reset: model.video.hasColorAdjustments ? { model.video.resetColor() } : nil) {
            adjustment("Brightness", \.brightness)
            adjustment("Contrast", \.contrast)
            adjustment("Saturation", \.saturation)
            adjustment("Gamma", \.gamma)
            adjustment("Hue", \.hue)
        }

        SettingsSection(title: "Decoding") {
            Toggle("Hardware decoding", isOn: $model.video.usesHardwareDecoding)
            Toggle("Deinterlace", isOn: $model.video.isDeinterlacing)
            if let decoder = model.state.hardwareDecoder {
                Text("Decoding with \(decoder)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.state.hasMedia {
                Text("Decoding in software")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func adjustment(_ label: String, _ keyPath: WritableKeyPath<VideoSettings, Int>) -> some View {
        LabelledSlider(
            label: label,
            value: Binding {
                Double(model.video[keyPath: keyPath])
            } set: { value in
                model.video[keyPath: keyPath] = Int(value.rounded())
            },
            range: Double(VideoSettings.adjustmentRange.lowerBound) ... Double(VideoSettings.adjustmentRange.upperBound),
            step: 1,
            valueText: String(model.video[keyPath: keyPath])
        )
    }

    private var speedBinding: Binding<Double> {
        Binding {
            model.speed.value
        } set: { value in
            model.speed = PlaybackSpeed(value)
        }
    }
}
