import AppKit
import SwiftUI

/// The app's look in one place: the colours that go with the accent, the shapes, and the few
/// building blocks every screen is made of.
enum Theme {
    /// Cards, rows and panels.
    static let cardRadius: CGFloat = 12
    /// Posters and other artwork.
    static let artworkRadius: CGFloat = 10
    /// Space between the window's edge and a screen's content.
    static let gutter: CGFloat = 28

    /// The accent's warmer companion, for the far end of a gradient.
    static let accentWarm = Color(red: 0.93, green: 0.36, blue: 0.78)
    /// The accent's cooler companion.
    static let accentCool = Color(red: 0.30, green: 0.62, blue: 1.0)

    /// What marks the one thing on a screen that is meant to be pressed, and anything filling up.
    static let accentGradient = LinearGradient(
        colors: [Color.accentColor, accentWarm],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// The fill of a card at rest and under the pointer. Follows light and dark by itself.
    static func cardFill(isHovered: Bool = false) -> Color {
        Color.primary.opacity(isHovered ? 0.10 : 0.055)
    }

    static func cardStroke(isHovered: Bool = false) -> Color {
        Color.primary.opacity(isHovered ? 0.22 : 0.08)
    }

    /// How things move when they answer the pointer.
    static let hover = Animation.spring(response: 0.28, dampingFraction: 0.78)
}

/// What every screen sits on: the window's own colour with a breath of the accent in the top
/// corners, so that the dark is not flat. Drawn once; nothing in it moves.
struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 1.0 : 0.55
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Color.accentColor.opacity(0.20 * strength), .clear],
                center: UnitPoint(x: 0.08, y: -0.05),
                startRadius: 0,
                endRadius: 620
            )
            RadialGradient(
                colors: [Theme.accentWarm.opacity(0.11 * strength), .clear],
                center: UnitPoint(x: 1.0, y: 0.0),
                startRadius: 0,
                endRadius: 560
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// The one button on a screen that is meant to be pressed: Play.
struct ProminentPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 11)
                .background(Theme.accentGradient, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(isHovered ? 0.45 : 0.18), lineWidth: 1))
                .shadow(color: Color.accentColor.opacity(isHovered ? 0.65 : 0.35), radius: isHovered ? 16 : 9, y: 4)
                .scaleEffect(configuration.isPressed ? 0.96 : (isHovered ? 1.035 : 1))
                .saturation(isEnabled ? 1 : 0.2)
                .opacity(isEnabled ? 1 : 0.6)
                .animation(Theme.hover, value: isHovered)
                .animation(Theme.hover, value: configuration.isPressed)
                .onHover { isHovered = $0 }
                .contentShape(Capsule())
        }
    }
}

/// The buttons beside it: Watch Trailer, Add to Library, Download.
struct PillButtonStyle: ButtonStyle {
    /// Filled with the accent: the thing it switches is on.
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isOn: isOn)
    }

    private struct Styled: View {
        let configuration: Configuration
        let isOn: Bool
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.callout.weight(.medium))
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .background(
                    isOn ? AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.28 : 0.18)) : AnyShapeStyle(Theme.cardFill(isHovered: isHovered)),
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.5) : Theme.cardStroke(isHovered: isHovered), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Theme.hover, value: isHovered)
                .animation(Theme.hover, value: configuration.isPressed)
                .onHover { isHovered = $0 }
                .contentShape(Capsule())
        }
    }
}

/// A button that sits on a picture: frosted, so that it reads on any backdrop.
struct BannerPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(isHovered ? 0.5 : 0.18), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.96 : (isHovered ? 1.03 : 1))
                .animation(Theme.hover, value: isHovered)
                .animation(Theme.hover, value: configuration.isPressed)
                .onHover { isHovered = $0 }
                .contentShape(Capsule())
        }
    }
}

/// A round button that is only a symbol: pause, reveal, remove.
struct IconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, diameter: diameter)
    }

    private struct Styled: View {
        let configuration: Configuration
        let diameter: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: diameter * 0.43, weight: .semibold))
                .frame(width: diameter, height: diameter)
                .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background(Theme.cardFill(isHovered: isHovered), in: Circle())
                .overlay(Circle().strokeBorder(Theme.cardStroke(isHovered: isHovered), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(Theme.hover, value: isHovered)
                .animation(Theme.hover, value: configuration.isPressed)
                .onHover { isHovered = $0 }
                .contentShape(Circle())
        }
    }
}

/// A whole row or card that is pressed: it lights up under the pointer and gives a little
/// when pressed.
struct CardButtonStyle: ButtonStyle {
    var radius = Theme.cardRadius
    /// Outlined in the accent: the row that is selected, or pointed out.
    var isHighlighted = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, radius: radius, isHighlighted: isHighlighted)
    }

    private struct Styled: View {
        let configuration: Configuration
        let radius: CGFloat
        let isHighlighted: Bool
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .background(Theme.cardFill(isHovered: isHovered), in: shape)
                .overlay(shape.strokeBorder(
                    isHighlighted ? Color.accentColor.opacity(isHovered ? 0.9 : 0.55) : Theme.cardStroke(isHovered: isHovered),
                    lineWidth: 1
                ))
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .animation(Theme.hover, value: isHovered)
                .animation(Theme.hover, value: configuration.isPressed)
                .onHover { isHovered = $0 }
                .contentShape(shape)
        }
    }
}

// MARK: - Small pieces

/// A fact in a capsule: a year, a running time, a genre.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint ?? .secondary)
            }
            Text(text)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.cardStroke(), lineWidth: 1))
    }
}

/// A bar that fills from the left in the accent's colours.
struct GradientProgressBar: View {
    /// 0 to 1; `nil` while there is nothing to measure, shown as an empty bar.
    let fraction: Double?
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: max(geometry.size.width * min(max(fraction ?? 0, 0), 1), fraction == nil ? 0 : height))
                    .animation(.easeOut(duration: 0.5), value: fraction)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded(.down))) percent" } ?? "Not known yet")
    }
}

/// A screen's heading row: a title with whatever goes at its trailing end.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.title2.weight(.bold))
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .accessibilityElement(children: .contain)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A choice between a few things, as capsules in a row; the chosen one is filled and slides.
struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    let selection: Value?
    let title: (Value) -> String
    let select: (Value) -> Void
    /// What VoiceOver calls the group.
    var label = "Show"

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    select(option)
                } label: {
                    Text(title(option))
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.accentGradient)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.cardFill(), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.cardStroke(), lineWidth: 1))
        .animation(Theme.hover, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
