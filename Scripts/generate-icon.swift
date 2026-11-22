#!/usr/bin/env swift
// Draws the app icon (a nebula: clouds of coloured light and stars) and writes a complete
// AppIcon.appiconset. Original artwork, generated from code; replace it freely.
//
// Usage: swift Scripts/generate-icon.swift App/Assets.xcassets/AppIcon.appiconset

import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-icon.swift <path-to-AppIcon.appiconset>\n".utf8))
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

/// Renders the icon at `pixels` × `pixels`. All geometry is in a 1024-unit design space.
func renderIcon(pixels: Int) -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Background: macOS-style rounded square with the standard 100-unit margin, deep space inside.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.10, 0.07, 0.26), color(0.02, 0.02, 0.08)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The nebula: clouds of light laid over one another, each fading to nothing at its edge.
    func cloud(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) {
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [color(red, green, blue, alpha), color(red, green, blue, alpha * 0.45), color(red, green, blue, 0)] as CFArray,
            locations: [0, 0.45, 1]
        )!
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: x, y: y), startRadius: 0,
            endCenter: CGPoint(x: x, y: y), endRadius: radius,
            options: []
        )
    }
    context.setBlendMode(.screen)
    cloud(380, 600, 380, 0.55, 0.30, 1.00, 0.85) // violet
    cloud(650, 470, 340, 0.98, 0.30, 0.72, 0.80) // magenta
    cloud(560, 700, 260, 0.25, 0.70, 1.00, 0.60) // blue
    cloud(430, 380, 240, 0.20, 0.85, 0.85, 0.40) // teal
    cloud(520, 540, 150, 1.00, 0.85, 0.75, 0.85) // the bright heart

    // Stars: the same ones every time, a few of them large enough to read at small sizes.
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> CGFloat {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(seed >> 33) / CGFloat(1 << 31)
    }
    context.setBlendMode(.normal)
    for index in 0 ..< 70 {
        let x = 110 + next() * 804
        let y = 110 + next() * 804
        let size = index < 6 ? 9 + next() * 7 : 2 + next() * 4
        context.setFillColor(color(1, 1, 1, index < 6 ? 0.95 : 0.35 + next() * 0.5))
        context.fillEllipse(in: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
    }

    // One star with rays, where the clouds are brightest.
    context.translateBy(x: 600, y: 610)
    context.setFillColor(color(1, 1, 1, 0.95))
    for turn in 0 ..< 2 {
        context.saveGState()
        context.rotate(by: CGFloat(turn) * .pi / 2)
        let ray = CGMutablePath()
        ray.move(to: CGPoint(x: 0, y: 92))
        ray.addQuadCurve(to: CGPoint(x: 0, y: -92), control: CGPoint(x: 13, y: 0))
        ray.addQuadCurve(to: CGPoint(x: 0, y: 92), control: CGPoint(x: -13, y: 0))
        context.addPath(ray)
        context.fillPath()
        context.restoreGState()
    }
    context.restoreGState()

    let image = context.makeImage()!
    let representation = NSBitmapImageRep(cgImage: image)
    return representation.representation(using: .png, properties: [:])!
}

struct Slot {
    let points: Int
    let scale: Int
    var pixels: Int { points * scale }
    var fileName: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
}

let slots = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }

var rendered: [Int: Data] = [:]
for slot in slots {
    let data = rendered[slot.pixels] ?? renderIcon(pixels: slot.pixels)
    rendered[slot.pixels] = data
    try data.write(to: outputDirectory.appendingPathComponent(slot.fileName))
}

let images = slots.map { slot in
    """
        {
          "filename" : "\(slot.fileName)",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.points)x\(slot.points)"
        }
    """
}.joined(separator: ",\n")

let contents = """
{
  "images" : [
\(images)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try Data(contents.utf8).write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(slots.count) icon images to \(outputDirectory.path)")
