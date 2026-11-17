import Darwin
import Foundation
import os

/// Measures launch time: from the kernel creating the process to named milestones.
/// Logged so `Scripts/measure-launch.sh` can read the values back.
public enum LaunchMetrics {
    public static let logCategory = "launch"

    /// Wall-clock time at which the kernel created this process.
    public static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Seconds elapsed since the process started, or `nil` if the start time is unavailable.
    public static func secondsSinceProcessStart(now: Date = Date()) -> TimeInterval? {
        processStartDate().map { now.timeIntervalSince($0) }
    }

    /// Points during launch worth timing.
    public enum Milestone: String, Sendable, CaseIterable {
        /// The main window's first frame.
        case firstScreen = "first-screen"
        /// The first catalog row on Home has its data.
        case homeContent = "home-content"
    }

    /// Logs the time since process start for a milestone, as `<milestone>-ms=<n>`, and returns it in seconds.
    @discardableResult
    public static func report(_ milestone: Milestone, subsystem: String) -> TimeInterval? {
        guard let elapsed = secondsSinceProcessStart() else { return nil }
        let milliseconds = Int((elapsed * 1000).rounded())
        Logger(subsystem: subsystem, category: logCategory)
            .notice("\(milestone.rawValue, privacy: .public)-ms=\(milliseconds, privacy: .public)")
        return elapsed
    }
}
