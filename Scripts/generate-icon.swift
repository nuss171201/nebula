#!/usr/bin/env swift
// Draws the placeholder app icon (an abstract orbit ring) and writes a complete
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

    // Background: macOS-style rounded square with the standard 100-unit margin.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.16, 0.13, 0.36), color(0.04, 0.05, 0.13)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        background,
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )
    let glow = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.45, 0.40, 1.0, 0.35), color(0.45, 0.40, 1.0, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 512, y: 512),
        startRadius: 0,
        endCenter: CGPoint(x: 512, y: 512),
        endRadius: 420,
        options: []
    )
    context.restoreGState()

    let center = CGPoint(x: 512, y: 512)
    let ringRect = CGRect(x: -300, y: -118, width: 600, height: 236)
    let tilt: CGFloat = 24 * .pi / 180

    func strokeRing(clipToUpperHalf: Bool) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: tilt)
        // The far half of the ring passes behind the planet, the near half in front.
        let half = clipToUpperHalf
            ? CGRect(x: -400, y: 0, width: 800, height: 400)
            : CGRect(x: -400, y: -400, width: 800, height: 400)
        context.clip(to: half)
        context.setStrokeColor(color(0.78, 0.82, 1.0))
        context.setLineWidth(34)
        context.strokeEllipse(in: ringRect)
        context.restoreGState()
    }

    strokeRing(clipToUpperHalf: true)

    // Planet.
    let planetRadius: CGFloat = 150
    let planetRect = CGRect(
        x: center.x - planetRadius,
        y: center.y - planetRadius,
        width: planetRadius * 2,
        height: planetRadius * 2
    )
    context.saveGState()
    context.addEllipse(in: planetRect)
    context.clip()
    let planet = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(1.0, 0.78, 0.45), color(0.96, 0.36, 0.42), color(0.50, 0.20, 0.62)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawRadialGradient(
        planet,
        startCenter: CGPoint(x: center.x - 55, y: center.y + 65),
        startRadius: 0,
        endCenter: center,
        endRadius: planetRadius * 1.25,
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()

    strokeRing(clipToUpperHalf: false)

    // Small moon sitting on the ring.
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: tilt)
    context.setFillColor(color(1, 1, 1))
    context.fillEllipse(in: CGRect(x: 300 - 30, y: -30, width: 60, height: 60))
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
