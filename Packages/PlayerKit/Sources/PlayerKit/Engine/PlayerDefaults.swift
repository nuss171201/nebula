import Foundation

/// The choices in the player's panel that carry over from one video to the next and from one
/// launch to the next: how subtitles look, how sound is shaped, and how HDR and decoding are
/// handled. Things that belong to one file (delays, crop, rotation, colour corrections,
/// whether subtitles are showing) are not part of it.
///
/// Stored as JSON; every field is optional on reading, so a file written by an older or newer
/// version is read as far as it goes.
public struct PlayerDefaults: Sendable, Equatable, Codable {
    public var subtitleScale = 1.0
    public var subtitlePosition = 100
    public var subtitleFontName: String?
    /// `#RRGGBB`.
    public var subtitleTextColor = "#FFFFFF"
    public var subtitleBorderColor = "#000000"
    public var subtitleBorderSize = 1.65
    public var subtitlesOverrideEmbeddedStyle = false

    public var equalizerIsEnabled = false
    public var equalizerGains = AudioSettings.Equalizer().gains
    public var normalizesLoudness = false
    public var downmixesToStereo = false
    public var keepsPitch = true

    public var hdrOutput = VideoSettings.HDROutput.automatic.rawValue
    public var toneMapping = VideoSettings.ToneMapping.automatic.rawValue
    public var usesHardwareDecoding = true

    public init() {}

    /// What the panel's settings come to as defaults.
    public init(video: VideoSettings, audio: AudioSettings, subtitles: SubtitleSettings) {
        subtitleScale = subtitles.scale
        subtitlePosition = subtitles.position
        subtitleFontName = subtitles.fontName
        subtitleTextColor = subtitles.textColor.engineValue
        subtitleBorderColor = subtitles.borderColor.engineValue
        subtitleBorderSize = subtitles.borderSize
        subtitlesOverrideEmbeddedStyle = subtitles.overridesEmbeddedStyle
        equalizerIsEnabled = audio.equalizer.isEnabled
        equalizerGains = audio.equalizer.gains
        normalizesLoudness = audio.isNormalizingLoudness
        downmixesToStereo = audio.isDownmixingToStereo
        keepsPitch = audio.keepsPitch
        hdrOutput = video.hdrOutput.rawValue
        toneMapping = video.toneMapping.rawValue
        usesHardwareDecoding = video.usesHardwareDecoding
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) -> Value {
            (try? container.decodeIfPresent(Value.self, forKey: key)) ?? fallback
        }
        let defaults = PlayerDefaults()
        subtitleScale = read(.subtitleScale, defaults.subtitleScale)
        subtitlePosition = read(.subtitlePosition, defaults.subtitlePosition)
        subtitleFontName = try? container.decodeIfPresent(String.self, forKey: .subtitleFontName)
        subtitleTextColor = read(.subtitleTextColor, defaults.subtitleTextColor)
        subtitleBorderColor = read(.subtitleBorderColor, defaults.subtitleBorderColor)
        subtitleBorderSize = read(.subtitleBorderSize, defaults.subtitleBorderSize)
        subtitlesOverrideEmbeddedStyle = read(.subtitlesOverrideEmbeddedStyle, defaults.subtitlesOverrideEmbeddedStyle)
        equalizerIsEnabled = read(.equalizerIsEnabled, defaults.equalizerIsEnabled)
        // Padded or cut to the number of bands, and brought into range.
        equalizerGains = AudioSettings.Equalizer(isEnabled: true, gains: read(.equalizerGains, defaults.equalizerGains)).gains
        normalizesLoudness = read(.normalizesLoudness, defaults.normalizesLoudness)
        downmixesToStereo = read(.downmixesToStereo, defaults.downmixesToStereo)
        keepsPitch = read(.keepsPitch, defaults.keepsPitch)
        hdrOutput = read(.hdrOutput, defaults.hdrOutput)
        toneMapping = read(.toneMapping, defaults.toneMapping)
        usesHardwareDecoding = read(.usesHardwareDecoding, defaults.usesHardwareDecoding)
    }

    /// The panel's settings a new player starts with. Values out of range are brought back in
    /// by the settings themselves when they are written to the engine.
    public func settings() -> (video: VideoSettings, audio: AudioSettings, subtitles: SubtitleSettings) {
        var video = VideoSettings()
        video.hdrOutput = VideoSettings.HDROutput(rawValue: hdrOutput) ?? .automatic
        video.toneMapping = VideoSettings.ToneMapping(rawValue: toneMapping) ?? .automatic
        video.usesHardwareDecoding = usesHardwareDecoding

        var audio = AudioSettings()
        audio.equalizer = AudioSettings.Equalizer(isEnabled: equalizerIsEnabled, gains: equalizerGains)
        audio.isNormalizingLoudness = normalizesLoudness
        audio.isDownmixingToStereo = downmixesToStereo
        audio.keepsPitch = keepsPitch

        var subtitles = SubtitleSettings()
        subtitles.scale = subtitleScale
        subtitles.position = subtitlePosition
        subtitles.fontName = subtitleFontName
        subtitles.textColor = SubtitleSettings.Color(hex: subtitleTextColor) ?? .white
        subtitles.borderColor = SubtitleSettings.Color(hex: subtitleBorderColor) ?? .black
        subtitles.borderSize = subtitleBorderSize
        subtitles.overridesEmbeddedStyle = subtitlesOverrideEmbeddedStyle
        return (video, audio, subtitles)
    }
}

public extension SubtitleSettings.Color {
    /// Reads `#RRGGBB` (the `#` is optional).
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }
}

public extension PlayerModel {
    /// Starts the panel's settings at the stored defaults. A method, so that the settings'
    /// observers run and the engine is told (they do not run for assignments in `init`).
    internal func applyDefaults(_ defaults: PlayerDefaults) {
        let settings = defaults.settings()
        video = settings.video
        audio = settings.audio
        subtitles = settings.subtitles
    }

    /// The panel's settings as defaults for the next video. Changes when the user changes
    /// something that carries over.
    var currentDefaults: PlayerDefaults {
        PlayerDefaults(video: video, audio: audio, subtitles: subtitles)
    }
}
