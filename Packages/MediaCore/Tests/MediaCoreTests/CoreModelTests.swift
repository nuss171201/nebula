import Foundation
@testable import MediaCore
import Testing

@Suite("Core models")
struct CoreModelTests {
    @Test("Media types decode from plain strings, including unknown ones")
    func mediaTypeCoding() throws {
        let json = Data(#"["movie","series","anime","events"]"#.utf8)
        let types = try JSONDecoder().decode([MediaType].self, from: json)
        #expect(types == [.movie, .series, .anime, MediaType(rawValue: "events")])
        #expect(types[0].isWellKnown && types[2].isWellKnown)
        #expect(!types[3].isWellKnown)

        let encoded = try JSONEncoder().encode(types)
        #expect(String(bytes: encoded, encoding: .utf8) == #"["movie","series","anime","events"]"#)
    }

    @Test("User agent is built from the branding values")
    func userAgent() {
        let branding = AppBranding(name: "Sample", bundleIdentifier: "test.sample", version: "1.2.3", build: "45")
        #expect(branding.userAgent == "Sample/1.2.3 (macOS; build 45)")
    }

    @Test("Branding falls back to neutral values when the bundle has no Info.plist keys")
    func brandingFallback() {
        let branding = AppBranding(bundle: Bundle(for: BundleAnchor.self))
        #expect(!branding.name.isEmpty)
        #expect(!branding.version.isEmpty)
    }

    @Test("Process start time is in the past and recent")
    func processStart() throws {
        let elapsed = try #require(LaunchMetrics.secondsSinceProcessStart())
        #expect(elapsed >= 0)
        #expect(elapsed < 3600)
        #expect(LaunchMetrics.report(.homeContent, subsystem: "test.metrics") != nil)
        #expect(LaunchMetrics.Milestone.allCases.map(\.rawValue) == ["first-screen", "home-content"])
    }
}

private final class BundleAnchor {}
