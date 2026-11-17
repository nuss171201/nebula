import AppKit

/// The kinds of window the player can be in.
public enum PlayerWindowMode: String, Sendable, CaseIterable {
    /// The normal window, with all controls. Can go full screen.
    case standard
    /// A small window in a corner of the screen that floats above other apps, on every Space.
    case pictureInPicture
    /// A compact window with a title, a seek bar and transport controls, and no picture.
    case mini
}

/// Sizes and positions of the player's windows. Pure, so it can be tested without a screen.
enum PlayerWindowLayout {
    static let standardMinimum = CGSize(width: 640, height: 360)
    static let pictureInPictureMinimum = CGSize(width: 240, height: 135)
    static let pictureInPictureWidth: CGFloat = 420
    static let miniSize = CGSize(width: 460, height: 124)
    static let miniWidthRange: ClosedRange<CGFloat> = 380 ... 900
    static let margin: CGFloat = 20

    /// The picture-in-picture window's content frame: `width` wide (less on a small screen),
    /// shaped like the video, in the bottom right corner of the usable part of the screen.
    static func pictureInPictureFrame(video: CGSize?, visibleFrame: CGRect, width: CGFloat = pictureInPictureWidth) -> CGRect {
        let aspect = video.flatMap { $0.width > 0 && $0.height > 0 ? $0.width / $0.height : nil } ?? 16 / 9
        var size = CGSize(width: width, height: (width / aspect).rounded())
        let available = CGSize(width: visibleFrame.width - margin * 2, height: visibleFrame.height - margin * 2)
        let fit = min(1, available.width / size.width, available.height / size.height)
        if fit < 1, fit > 0 {
            size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        }
        return CGRect(
            x: visibleFrame.maxX - margin - size.width,
            y: visibleFrame.minY + margin,
            width: size.width,
            height: size.height
        )
    }

    /// Keeps a picture-in-picture window where it is when its video changes shape: same width,
    /// same corner nearest the screen edge it was put against.
    static func reshapedPictureInPictureFrame(current: CGRect, video: CGSize?, visibleFrame: CGRect) -> CGRect {
        let aspect = video.flatMap { $0.width > 0 && $0.height > 0 ? $0.width / $0.height : nil } ?? 16 / 9
        let size = CGSize(width: current.width, height: (current.width / aspect).rounded())
        // Grow from whichever of top and bottom is nearer the screen's edge.
        let isNearTop = visibleFrame.maxY - current.maxY < current.minY - visibleFrame.minY
        return CGRect(x: current.minX, y: isNearTop ? current.maxY - size.height : current.minY, width: size.width, height: size.height)
    }

    /// The mini player's content frame, keeping the top left corner of the window it replaces.
    static func miniFrame(replacing current: CGRect) -> CGRect {
        CGRect(x: current.minX, y: current.maxY - miniSize.height, width: miniSize.width, height: miniSize.height)
    }
}
