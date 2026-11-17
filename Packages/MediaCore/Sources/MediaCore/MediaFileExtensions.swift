/// File name extensions (lower case, no dot) by what the file holds. Shared by the player,
/// which decides what can be opened, and the stream engine, which picks the video out of a torrent.
public enum MediaFileExtensions {
    public static let video: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts", "mpg", "mpeg", "wmv", "flv", "ogv", "3gp", "vob", "rmvb", "divx",
    ]
    public static let audio: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "oga", "opus", "mka", "wma", "ac3", "eac3", "dts", "alac", "ape", "wv",
    ]
    /// Formats the playback engine reads as subtitles.
    public static let subtitles: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "smi", "lrc", "ttml", "mks"]
}
