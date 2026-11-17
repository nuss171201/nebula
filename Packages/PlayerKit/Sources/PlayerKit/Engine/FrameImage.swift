import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns the engine's raw frame captures into images. This engine build has no image
/// encoders of its own, so encoding is done here with ImageIO.
enum FrameImage {
    /// Builds an image from a `screenshot-raw` result: 8-bit BGRX rows of `stride` bytes.
    static func make(from node: MPVNode) -> CGImage? {
        guard node["format"]?.text == "bgr0",
              let width = node["w"]?.integer, let height = node["h"]?.integer, let stride = node["stride"]?.integer,
              let data = node["data"]?.data
        else { return nil }
        return make(bgrx: data, width: width, height: height, bytesPerRow: stride)
    }

    static func make(bgrx data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard width > 0, height > 0, bytesPerRow >= width * 4, data.count >= bytesPerRow * height,
              let provider = CGDataProvider(data: data as CFData)
        else { return nil }
        // Little-endian 32-bit with the alpha byte ignored is B, G, R, X in memory order.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
