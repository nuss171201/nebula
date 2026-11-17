#!/usr/bin/env swift
// Prints the ids of a process's normal windows, largest first, one per line as "<id> <width>x<height>".
// Usage: swift Scripts/window-id.swift <pid>

import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-id.swift <pid>\n".utf8))
    exit(64)
}

let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let candidates = windows.compactMap { window -> (id: Int, width: Double, height: Double)? in
    guard window[kCGWindowOwnerPID as String] as? Int == pid,
          window[kCGWindowLayer as String] as? Int == 0,
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
          width > 200, height > 200
    else { return nil }
    return (id, width, height)
}

guard !candidates.isEmpty else {
    FileHandle.standardError.write(Data("no window found for pid \(pid)\n".utf8))
    exit(1)
}

for window in candidates.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
    print("\(window.id) \(Int(window.width))x\(Int(window.height))")
}
