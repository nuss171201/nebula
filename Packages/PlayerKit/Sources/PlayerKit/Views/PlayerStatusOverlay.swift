import SwiftUI

/// What the player shows while it has no picture to move: a ring that fills with a
/// percentage while opening or stalled, and the message when playback fails.
struct PlayerStatusOverlay: View {
    let state: PlaybackState
    /// What is being waited for, if whoever fetches the source has said.
    var note: String?
    /// How much of what is being waited for has arrived, 0 to 1, if whoever fetches the
    /// source can say.
    var progress: Double?

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
            let fraction = Self.shownProgress(state: state, sourceProgress: progress)
            VStack(spacing: 16) {
                LoadingRing(fraction: fraction)
                VStack(spacing: 5) {
                    Text(Self.headline(for: state, hasProgress: fraction != nil))
                        .font(.headline)
                        .foregroundStyle(.white)
                    if let note {
                        Text(note)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .shadow(color: .black.opacity(0.6), radius: 4)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            // Readable over a paused frame as well as over black.
            .background(.black.opacity(state.hasShownFirstFrame ? 0.45 : 0), in: RoundedRectangle(cornerRadius: 24))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.phase == .loading ? "Opening" : "Buffering")
            .accessibilityValue(Self.spokenValue(fraction: fraction, note: note))
        }
    }

    /// The fraction to show: what the source's fetcher reports where it can; else, once a file
    /// is open, how full the engine says its buffer is. `nil` shows a ring that only turns.
    nonisolated static func shownProgress(state: PlaybackState, sourceProgress: Double?) -> Double? {
        if let sourceProgress {
            return min(max(sourceProgress, 0), 1)
        }
        guard state.phase == .playing, let buffering = state.bufferingProgress else { return nil }
        return buffering
    }

    /// A whole percentage that only says 100 when there is nothing left to wait for; the
    /// last stretch otherwise reads "100 %" while the player still sits there.
    nonisolated static func percentage(for fraction: Double) -> Int {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        return fraction >= 1 ? 100 : min(percent, 99)
    }

    nonisolated static func headline(for state: PlaybackState, hasProgress: Bool) -> String {
        if state.phase == .loading || !state.hasShownFirstFrame {
            return hasProgress ? "Getting ready to play" : "Opening"
        }
        return "Buffering"
    }

    nonisolated static func spokenValue(fraction: Double?, note: String?) -> String {
        [fraction.map { "\(percentage(for: $0)) percent" }, note].compactMap(\.self).joined(separator: ", ")
    }
}

/// A ring that fills as something arrives, with the percentage in its middle; with nothing
/// to measure, a short arc that goes round.
struct LoadingRing: View {
    /// 0 to 1; `nil` when there is nothing to measure.
    var fraction: Double?
    var diameter: CGFloat = 92
    var lineWidth: CGFloat = 7

    @State private var isTurning = false

    private var gradient: AngularGradient {
        AngularGradient(
            colors: [Color.accentColor.opacity(0.55), Color.accentColor, .white.opacity(0.95)],
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360)
        )
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.14), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    // Never quite empty: a dot at the top says the ring is alive at 0 %.
                    .trim(from: 0, to: max(fraction, 0.004))
                    .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Color.accentColor.opacity(0.7), radius: 8)
                    .animation(.easeOut(duration: 0.6), value: fraction)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(PlayerStatusOverlay.percentage(for: fraction))")
                        .font(.system(size: diameter * 0.3, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: fraction))
                    Text("%")
                        .font(.system(size: diameter * 0.15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .animation(.easeOut(duration: 0.3), value: PlayerStatusOverlay.percentage(for: fraction))
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(isTurning ? 360 : 0))
                    .shadow(color: Color.accentColor.opacity(0.7), radius: 8)
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: isTurning)
                    .onAppear { isTurning = true }
                    .onDisappear { isTurning = false }
            }
        }
        .frame(width: diameter, height: diameter)
    }
}
