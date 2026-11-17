#!/usr/bin/env swift
// Prints the window id of the largest normal window owned by a process.
// Usage: swift Scripts/window-id.swift <pid>

import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-id.swift <pid>\n".utf8))
    exit(64)
}

let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let candidates = windows.compactMap { window -> (id: Int, area: Double)? in
    guard window[kCGWindowOwnerPID as String] as? Int == pid,
          window[kCGWindowLayer as String] as? Int == 0,
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
          width > 200, height > 200
    else { return nil }
    return (id, width * height)
}

guard let largest = candidates.max(by: { $0.area < $1.area }) else {
    FileHandle.standardError.write(Data("no window found for pid \(pid)\n".utf8))
    exit(1)
}

print(largest.id)
