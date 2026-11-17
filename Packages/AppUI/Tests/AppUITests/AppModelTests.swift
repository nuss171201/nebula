@testable import AppUI
import Foundation
import MediaCore
import Testing

@MainActor
@Suite("App navigation model")
struct AppModelTests {
    private let branding = AppBranding(name: "Sample", bundleIdentifier: "test.sample", version: "1", build: "1")

    @Test("Starts on Home")
    func initialSelection() {
        let model = AppModel(branding: branding, reportLaunch: { nil })
        #expect(model.selection == .home)
        #expect(model.currentSection == .home)
    }

    @Test("Clearing the selection keeps showing the last section")
    func clearedSelection() {
        let model = AppModel(branding: branding, reportLaunch: { nil })
        model.selection = .library
        #expect(model.currentSection == .library)
        model.selection = nil
        #expect(model.currentSection == .library)
    }

    @Test("Launch time is recorded once, on the first appearance only")
    func launchRecordedOnce() {
        var calls = 0
        let model = AppModel(branding: branding, reportLaunch: {
            calls += 1
            return 0.25
        })
        #expect(model.launchDuration == nil)
        model.firstScreenDidAppear()
        model.firstScreenDidAppear()
        #expect(calls == 1)
        #expect(model.launchDuration == 0.25)
    }

    @Test("Every section has distinct, non-empty sidebar content")
    func sectionMetadata() {
        let sections = AppSection.allCases
        #expect(Set(sections.map(\.title)).count == sections.count)
        #expect(Set(sections.map(\.systemImage)).count == sections.count)
        #expect(sections.allSatisfy { !$0.emptyStateMessage.isEmpty })
    }
}
