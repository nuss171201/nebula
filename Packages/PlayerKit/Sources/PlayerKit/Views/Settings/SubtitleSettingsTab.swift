import AppKit
import SwiftUI

extension SubtitleSettings.Color {
    init(_ color: Color) {
        let components = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        self.init(red: byte(components.redComponent), green: byte(components.greenComponent), blue: byte(components.blueComponent))
    }

    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

struct SubtitleSettingsTab: View {
    @Bindable var model: PlayerModel

    /// Font families are listed once; there can be several hundred.
    private static let fontFamilies = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

    var body: some View {
        SettingsSection(title: "Subtitle Track") {
            TrackList(model: model, kind: .subtitle, allowsNone: true)
            Toggle("Show subtitles", isOn: $model.subtitles.isVisible)
        }

        SettingsSection(title: "Timing") {
            DelayControl(label: "Delay", delay: $model.subtitles.delay, range: SubtitleSettings.delayRange)
        }

        SettingsSection(title: "Appearance", reset: hasCustomAppearance ? { resetAppearance() } : nil) {
            LabelledSlider(
                label: "Size",
                value: $model.subtitles.scale,
                range: SubtitleSettings.scaleRange,
                valueText: "\(Int((model.subtitles.scale * 100).rounded())) %"
            )
            LabelledSlider(
                label: "Position",
                value: positionBinding,
                range: Double(SubtitleSettings.positionRange.lowerBound) ... Double(SubtitleSettings.positionRange.upperBound),
                step: 1,
                valueText: "\(model.subtitles.position) %"
            )
            Picker("Font", selection: $model.subtitles.fontName) {
                Text("System").tag(String?.none)
                Divider()
                ForEach(Self.fontFamilies, id: \.self) { family in
                    Text(family).tag(Optional(family))
                }
            }
            ColorPicker("Text colour", selection: colorBinding(\.textColor), supportsOpacity: false)
            ColorPicker("Outline colour", selection: colorBinding(\.borderColor), supportsOpacity: false)
            LabelledSlider(
                label: "Outline width",
                value: $model.subtitles.borderSize,
                range: SubtitleSettings.borderRange,
                valueText: String(format: "%.1f", model.subtitles.borderSize)
            )
            Toggle("Use this style for styled subtitles too", isOn: $model.subtitles.overridesEmbeddedStyle)
        }
    }

    private var hasCustomAppearance: Bool {
        var defaults = SubtitleSettings()
        defaults.isVisible = model.subtitles.isVisible
        defaults.delay = model.subtitles.delay
        return model.subtitles != defaults
    }

    private func resetAppearance() {
        var defaults = SubtitleSettings()
        defaults.isVisible = model.subtitles.isVisible
        defaults.delay = model.subtitles.delay
        model.subtitles = defaults
    }

    private var positionBinding: Binding<Double> {
        Binding {
            Double(model.subtitles.position)
        } set: { value in
            model.subtitles.position = Int(value.rounded())
        }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<SubtitleSettings, SubtitleSettings.Color>) -> Binding<Color> {
        Binding {
            model.subtitles[keyPath: keyPath].color
        } set: { color in
            model.subtitles[keyPath: keyPath] = SubtitleSettings.Color(color)
        }
    }
}
