import Darwin
import Foundation
import os

/// Measures cold-launch time: from the kernel creating the process to the first
/// screen appearing. Logged so `Scripts/measure-launch.sh` can read it back.
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

    /// Logs the launch duration under the given subsystem and returns it.
    @discardableResult
    public static func reportFirstScreen(subsystem: String) -> TimeInterval? {
        guard let elapsed = secondsSinceProcessStart() else { return nil }
        let milliseconds = Int((elapsed * 1000).rounded())
        Logger(subsystem: subsystem, category: logCategory)
            .notice("first-screen-ms=\(milliseconds, privacy: .public)")
        return elapsed
    }
}
