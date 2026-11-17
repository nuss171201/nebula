#if DEBUG
    import AppKit
    import os
    import QuartzCore

    /// Scrolls the main window's list by itself and reports how well the main thread kept up.
    ///
    /// A check cannot touch the trackpad, so this stands in for the user's fingers: 120 times a
    /// second it moves the scroll position on, as a scroll gesture would, which makes the lazy
    /// stacks and grids build and drop rows exactly as they do under a real scroll. A tick that
    /// arrives late means the main thread was busy for that long, which is what a dropped frame
    /// is. The result is logged for `Scripts/measure-scroll.sh`.
    @MainActor
    final class DebugAutoscroll {
        private static var current: DebugAutoscroll?
        private static let interval = 1.0 / 120

        private let speed: CGFloat
        private let duration: Double
        private var timer: Timer?
        private var lastTick: CFTimeInterval = 0
        private var elapsed = 0.0
        private var travelled: CGFloat = 0
        /// How late each tick was, in milliseconds.
        private var lateness: [Double] = []
        /// When the ticks that were more than 8 ms late happened, in seconds from the start, with their lateness.
        private var stalls: [String] = []

        private init(speed: CGFloat, duration: Double) {
            self.speed = speed
            self.duration = duration
        }

        /// - Parameters:
        ///   - delay: Seconds to wait first, so that the screen has its content.
        ///   - speed: Points per second. A brisk two-finger flick is a few thousand.
        ///   - duration: Seconds to scroll for: down for the first two thirds, back up for the rest.
        static func start(after delay: Double, speed: CGFloat, duration: Double) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                let scroller = DebugAutoscroll(speed: speed, duration: duration)
                current = scroller
                scroller.begin()
            }
        }

        private static let logger = Logger(subsystem: Branding.current.bundleIdentifier, category: "autoscroll")

        private func begin() {
            guard let scrollView = Self.mainScrollView() else {
                Self.logger.notice("autoscroll found nothing to scroll")
                return
            }
            lastTick = CACurrentMediaTime()
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                // Timers on the main run loop fire on the main thread.
                MainActor.assumeIsolated {
                    self?.tick(scrollView)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick(_ scrollView: NSScrollView) {
            let now = CACurrentMediaTime()
            let step = now - lastTick
            lastTick = now
            elapsed += step
            let late = max(step - Self.interval, 0) * 1000
            lateness.append(late)
            if late > 8, stalls.count < 12 {
                stalls.append(String(format: "%.1fs:%.0fms", elapsed, late))
            }
            guard elapsed < duration, let document = scrollView.documentView else {
                finish()
                return
            }
            let clip = scrollView.contentView
            let range = max(document.frame.height - clip.bounds.height, 0)
            // "Down the page" is a growing offset in a flipped document and a shrinking one otherwise.
            let down: CGFloat = document.isFlipped ? 1 : -1
            let direction: CGFloat = elapsed < duration * 2 / 3 ? down : -down
            // A stalled tick must not turn into a jump the user's fingers could not make.
            let wanted = clip.bounds.origin.y + direction * speed * min(step, 0.05)
            let target = min(max(wanted, 0), range)
            travelled += abs(target - clip.bounds.origin.y)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
            scrollView.reflectScrolledClipView(clip)
        }

        private func finish() {
            timer?.invalidate()
            timer = nil
            let sorted = lateness.sorted()
            let over8 = lateness.count(where: { $0 > 8 })
            let over16 = lateness.count(where: { $0 > 16 })
            let longest = sorted.last ?? 0
            let p99 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 99 / 100)]
            let over4 = lateness.count(where: { $0 > 4 })
            // Time the main thread could not be reached at all, as a share of the scroll.
            let blocked = lateness.reduce(0, +) / (duration * 1000) * 100
            let line = "ticks=\(lateness.count) late>4ms=\(over4) late>8ms=\(over8) late>16ms=\(over16) "
                + "p99=\(String(format: "%.1f", p99))ms longest=\(String(format: "%.1f", longest))ms "
                + "blocked=\(String(format: "%.1f", blocked))% travelled=\(Int(travelled))pt stalls=[\(stalls.joined(separator: " "))]"
            Self.logger.notice("autoscroll \(line, privacy: .public)")
            Self.current = nil
        }

        /// The scroll view with the most to scroll, in the app's largest ordinary window.
        private static func mainScrollView() -> NSScrollView? {
            let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
            guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
            var found: [NSScrollView] = []
            func search(_ view: NSView) {
                if let scrollView = view as? NSScrollView, let document = scrollView.documentView,
                   document.frame.height - scrollView.contentView.bounds.height > 100 {
                    found.append(scrollView)
                }
                view.subviews.forEach(search)
            }
            window.contentView.map(search)
            return found.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
    }
#endif
