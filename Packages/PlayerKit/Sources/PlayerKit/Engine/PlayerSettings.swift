import CoreGraphics
import Foundation

/// One engine property write.
struct EngineWrite: Equatable, Sendable {
    var name: String
    var value: MPVValue

    init(_ name: String, _ value: MPVValue) {
        self.name = name
        self.value = value
    }
}

/// Picture adjustments. Changing a value on the player's `video` applies it at once.
public struct VideoSettings: Sendable, Equatable {
    public enum Aspect: Sendable, Hashable {
        /// As the file says.
        case source
        case ratio(width: Int, height: Int)

        public static let presets: [Aspect] = [
            .source, .ratio(width: 16, height: 9), .ratio(width: 4, height: 3), .ratio(width: 16, height: 10),
            .ratio(width: 21, height: 9), .ratio(width: 1, height: 1),
        ]

        public var label: String {
            switch self {
            case .source: "Original"
            case let .ratio(width, height): "\(width):\(height)"
            }
        }

        var engineValue: String {
            switch self {
            case .source: "-1"
            case let .ratio(width, height): "\(width):\(height)"
            }
        }
    }

    public enum Rotation: Int, Sendable, Hashable, CaseIterable {
        case none = 0, quarter = 90, half = 180, threeQuarters = 270

        /// The next quarter turn clockwise.
        public var clockwise: Rotation {
            Rotation(rawValue: (rawValue + 90) % 360) ?? .none
        }

        public var counterclockwise: Rotation {
            Rotation(rawValue: (rawValue + 270) % 360) ?? .none
        }

        /// Whether width and height trade places.
        public var swapsDimensions: Bool {
            self == .quarter || self == .threeQuarters
        }
    }

    public static let adjustmentRange = -100 ... 100
    public static let zoomRange = -2.0 ... 3.0
    public static let panRange = -1.0 ... 1.0

    /// Each −100…100, 0 meaning unchanged.
    public var brightness = 0
    public var contrast = 0
    public var saturation = 0
    public var gamma = 0
    public var hue = 0

    public var aspect: Aspect = .source
    /// Trims the picture to these proportions, centred. `.source` means no crop.
    public var crop: Aspect = .source
    public var rotation: Rotation = .none
    /// Left and right swapped.
    public var isMirrored = false
    /// Top and bottom swapped.
    public var isFlipped = false
    /// Magnification in powers of two: 0 is fit, 1 is twice the size.
    public var zoom = 0.0
    /// Offset of the picture as a fraction of its size.
    public var panX = 0.0
    public var panY = 0.0
    public var isDeinterlacing = false
    public var usesHardwareDecoding = true

    public init() {}

    /// Whether anything about colour differs from the defaults.
    public var hasColorAdjustments: Bool {
        brightness != 0 || contrast != 0 || saturation != 0 || gamma != 0 || hue != 0
    }

    /// Whether anything about geometry differs from the defaults.
    public var hasGeometryAdjustments: Bool {
        aspect != .source || crop != .source || rotation != .none || isMirrored || isFlipped
            || zoom != 0 || panX != 0 || panY != 0
    }

    public mutating func resetColor() {
        (brightness, contrast, saturation, gamma, hue) = (0, 0, 0, 0, 0)
    }

    public mutating func resetGeometry() {
        (aspect, crop, rotation, isMirrored, isFlipped) = (.source, .source, .none, false, false)
        (zoom, panX, panY) = (0, 0, 0)
    }

    /// The crop rectangle (`WxH+X+Y`) for a source of the given pixel size, or an empty string for no crop.
    static func cropValue(_ crop: Aspect, sourceSize: CGSize?) -> String {
        guard case let .ratio(width, height) = crop, let sourceSize, sourceSize.width > 0, sourceSize.height > 0 else { return "" }
        let target = Double(width) / Double(height)
        let current = sourceSize.width / sourceSize.height
        var size = sourceSize
        if target < current {
            size.width = (sourceSize.height * target / 2).rounded() * 2
        } else if target > current {
            size.height = (sourceSize.width / target / 2).rounded() * 2
        }
        let x = Int(((sourceSize.width - size.width) / 2).rounded())
        let y = Int(((sourceSize.height - size.height) / 2).rounded())
        return "\(Int(size.width))x\(Int(size.height))+\(x)+\(y)"
    }

    /// Every engine property this struct controls, with its value. `sourceSize` is the
    /// video track's size in pixels, needed to turn a crop ratio into a rectangle.
    func engineWrites(sourceSize: CGSize?) -> [EngineWrite] {
        func clamped(_ value: Int) -> MPVValue {
            .int(Int64(min(max(value, Self.adjustmentRange.lowerBound), Self.adjustmentRange.upperBound)))
        }
        func clamped(_ value: Double, to range: ClosedRange<Double>) -> MPVValue {
            .double(min(max(value, range.lowerBound), range.upperBound))
        }
        let filters = [isMirrored ? "hflip" : nil, isFlipped ? "vflip" : nil].compactMap(\.self).joined(separator: ",")
        return [
            EngineWrite("brightness", clamped(brightness)),
            EngineWrite("contrast", clamped(contrast)),
            EngineWrite("saturation", clamped(saturation)),
            EngineWrite("gamma", clamped(gamma)),
            EngineWrite("hue", clamped(hue)),
            EngineWrite("video-aspect-override", .string(aspect.engineValue)),
            EngineWrite("video-crop", .string(Self.cropValue(crop, sourceSize: sourceSize))),
            EngineWrite("video-rotate", .int(Int64(rotation.rawValue))),
            EngineWrite("vf", .string(filters)),
            EngineWrite("video-zoom", clamped(zoom, to: Self.zoomRange)),
            EngineWrite("video-pan-x", clamped(panX, to: Self.panRange)),
            EngineWrite("video-pan-y", clamped(panY, to: Self.panRange)),
            EngineWrite("deinterlace", .string(isDeinterlacing ? "yes" : "no")),
            EngineWrite("hwdec", .string(usesHardwareDecoding ? "videotoolbox" : "no")),
        ]
    }
}

/// Sound adjustments.
public struct AudioSettings: Sendable, Equatable {
    /// A ten-band graphic equaliser. Gains are in decibels.
    public struct Equalizer: Sendable, Equatable {
        public static let frequencies: [Int] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        public static let gainRange = -12.0 ... 12.0

        public var isEnabled = false
        public var gains = [Double](repeating: 0, count: frequencies.count)

        public init() {}

        public init(isEnabled: Bool, gains: [Double]) {
            self.isEnabled = isEnabled
            let padded = gains + [Double](repeating: 0, count: max(0, Self.frequencies.count - gains.count))
            self.gains = padded.prefix(Self.frequencies.count).map { min(max($0, Self.gainRange.lowerBound), Self.gainRange.upperBound) }
        }

        public struct Preset: Sendable, Equatable, Identifiable {
            public var name: String
            public var gains: [Double]
            public var id: String { name }
        }

        public static let presets: [Preset] = [
            Preset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            Preset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
            Preset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]),
            Preset(name: "Vocal", gains: [-3, -2, 0, 2, 4, 4, 3, 1, 0, -1]),
            Preset(name: "Loudness", gains: [5, 3, 0, 0, -1, 0, -1, 0, 3, 5]),
        ]

        /// Whether the equaliser changes the sound at all.
        var isActive: Bool {
            isEnabled && gains.contains { $0 != 0 }
        }

        /// The filter description: a smooth curve through the band gains.
        var filter: String? {
            guard isActive else { return nil }
            let entries = zip(Self.frequencies, gains)
                .map { "entry(\($0),\(String(format: "%.1f", $1)))" }
                .joined(separator: ";")
            return "lavfi=[firequalizer=gain_entry='\(entries)']"
        }
    }

    public static let delayRange = -10.0 ... 10.0

    /// Seconds the sound is shifted later (negative: earlier) relative to the picture.
    public var delay = 0.0
    public var equalizer = Equalizer()
    /// Evens out loud and quiet passages.
    public var isNormalizingLoudness = false

    public init() {}

    func engineWrites() -> [EngineWrite] {
        let filters = [equalizer.filter, isNormalizingLoudness ? "lavfi=[dynaudnorm]" : nil].compactMap(\.self).joined(separator: ",")
        return [
            EngineWrite("audio-delay", .double(min(max(delay, Self.delayRange.lowerBound), Self.delayRange.upperBound))),
            EngineWrite("af", .string(filters)),
        ]
    }
}

/// Subtitle timing and appearance.
public struct SubtitleSettings: Sendable, Equatable {
    /// An opaque colour, stored as 8-bit red, green and blue.
    public struct Color: Sendable, Hashable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public static let white = Color(red: 255, green: 255, blue: 255)
        public static let black = Color(red: 0, green: 0, blue: 0)
        public static let yellow = Color(red: 255, green: 221, blue: 51)

        /// `#RRGGBB`.
        var engineValue: String {
            String(format: "#%02X%02X%02X", red, green, blue)
        }
    }

    public static let delayRange = -30.0 ... 30.0
    public static let scaleRange = 0.25 ... 4.0
    public static let positionRange = 0 ... 150
    public static let borderRange = 0.0 ... 10.0

    public var isVisible = true
    /// Seconds the subtitles are shifted later (negative: earlier).
    public var delay = 0.0
    /// Size multiplier; 1 is the default size.
    public var scale = 1.0
    /// Vertical position as a percentage of the picture height; 100 is the bottom edge.
    public var position = 100
    /// Font family for text subtitles; `nil` uses the system's default sans-serif.
    public var fontName: String?
    public var textColor = Color.white
    public var borderColor = Color.black
    public var borderSize = 1.65
    /// Apply the style above even to subtitles that carry their own styling.
    public var overridesEmbeddedStyle = false

    public init() {}

    func engineWrites() -> [EngineWrite] {
        func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            min(max(value, range.lowerBound), range.upperBound)
        }
        let position = min(max(position, Self.positionRange.lowerBound), Self.positionRange.upperBound)
        return [
            EngineWrite("sub-visibility", .flag(isVisible)),
            EngineWrite("sub-delay", .double(clamp(delay, Self.delayRange))),
            EngineWrite("sub-scale", .double(clamp(scale, Self.scaleRange))),
            EngineWrite("sub-pos", .double(Double(position))),
            EngineWrite("sub-font", .string(fontName ?? "sans-serif")),
            EngineWrite("sub-color", .string(textColor.engineValue)),
            EngineWrite("sub-border-color", .string(borderColor.engineValue)),
            EngineWrite("sub-border-size", .double(clamp(borderSize, Self.borderRange))),
            EngineWrite("sub-ass-override", .string(overridesEmbeddedStyle ? "force" : "scale")),
        ]
    }
}

/// Repeating a section of the file between two points.
public enum ABLoop: Sendable, Equatable {
    case off
    /// The start is marked; waiting for the end.
    case startMarked(Double)
    case looping(start: Double, end: Double)

    /// What pressing the A-B button does next at the given position: mark the start,
    /// mark the end (if it is after the start), then clear.
    public func advanced(at position: Double) -> ABLoop {
        switch self {
        case .off:
            .startMarked(position)
        case let .startMarked(start):
            position > start + 0.1 ? .looping(start: start, end: position) : .startMarked(position)
        case .looping:
            .off
        }
    }

    var engineWrites: [EngineWrite] {
        switch self {
        case .off:
            [EngineWrite("ab-loop-a", .string("no")), EngineWrite("ab-loop-b", .string("no"))]
        case let .startMarked(start):
            [EngineWrite("ab-loop-a", .double(start)), EngineWrite("ab-loop-b", .string("no"))]
        case let .looping(start, end):
            [EngineWrite("ab-loop-a", .double(start)), EngineWrite("ab-loop-b", .double(end))]
        }
    }
}
