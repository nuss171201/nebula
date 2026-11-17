import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import Testing

@MainActor
@Suite("App navigation model")
struct AppModelTests {
    private func makeModel(
        reportMilestone: @escaping @MainActor (LaunchMetrics.Milestone) -> TimeInterval? = { _ in nil }
    ) -> AppModel {
        AppModel(
            dependencies: .ephemeral(http: StubHTTPClient(data: Data())),
            reportMilestone: reportMilestone
        )
    }

    /// Waits for main-actor work scheduled by observation callbacks to run.
    func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("Starts on Home")
    func initialSelection() {
        let model = makeModel()
        #expect(model.selection == .home)
        #expect(model.currentSection == .home)
    }

    @Test("Clearing the selection keeps showing the last section")
    func clearedSelection() {
        let model = makeModel()
        model.selection = .library
        #expect(model.currentSection == .library)
        model.selection = nil
        #expect(model.currentSection == .library)
    }

    @Test("Switching section returns to that section's root; re-selecting the same one does not")
    func pathReset() {
        let model = makeModel()
        let route = MediaRoute(type: .movie, id: "tt1")
        model.path = [route]
        model.selection = .home
        #expect(model.path == [route])
        model.selection = .discover
        #expect(model.path.isEmpty)
    }

    @Test("The first-screen time is recorded once, on the first appearance only")
    func launchRecordedOnce() {
        var calls: [LaunchMetrics.Milestone] = []
        let model = makeModel { milestone in
            calls.append(milestone)
            return 0.25
        }
        #expect(model.launchDurations.isEmpty)
        model.firstScreenDidAppear()
        model.firstScreenDidAppear()
        #expect(calls == [.firstScreen])
        #expect(model.launchDurations == [.firstScreen: 0.25])
    }

    @Test("Every section has distinct, non-empty sidebar content")
    func sectionMetadata() {
        let sections = AppSection.allCases
        #expect(Set(sections.map(\.title)).count == sections.count)
        #expect(Set(sections.map(\.systemImage)).count == sections.count)
    }

    @Test("Screens follow the installed add-ons, from first launch through later changes")
    func screensFollowAddons() async throws {
        let harness = try await AddonHarness.make()
        var milestones: [LaunchMetrics.Milestone] = []
        let model = try AppModel(
            dependencies: AppDependencies(
                branding: AppBranding(name: "Test", bundleIdentifier: "test.app", version: "1", build: "1"),
                addonClient: harness.client,
                database: harness.database,
                imagePipeline: ImagePipeline(http: StubHTTPClient(data: Data()), directory: nil),
                defaultAddonAddresses: [harness.address().manifestURL.absoluteString]
            ),
            reportMilestone: { milestone in
                milestones.append(milestone)
                return 1
            }
        )
        #expect(model.home.rows.isEmpty)

        await model.start()
        #expect(await eventually { model.home.rows.count == 2 })
        #expect(model.discover.types == [.movie, .series])

        // Home content is timed when the first row gets items, and only once.
        harness.server.respond(to: "/catalog/movie/top.json", with: .json(AddonFixtures.catalogJSON(count: 2)))
        harness.server.respond(to: "/catalog/series/top.json", with: .json(AddonFixtures.catalogJSON(count: 2)))
        #expect(model.launchDurations[.homeContent] == nil)
        await model.home.rows[0].loadIfNeeded()
        await model.home.rows[1].loadIfNeeded()
        #expect(milestones == [.homeContent])
        #expect(model.search.hasSearchableAddons)

        let addonID = try #require(model.registry.addons.first?.id)
        await model.registry.setEnabled(false, addonID: addonID)
        #expect(await eventually { model.home.rows.isEmpty })
        #expect(!model.discover.hasCatalogs)
        #expect(!model.search.hasSearchableAddons)

        await model.registry.setEnabled(true, addonID: addonID)
        #expect(await eventually { model.home.rows.count == 2 })
    }
}

extension AppModelTests {
    @Test("A later launch shows the stored add-ons on every screen")
    func laterLaunch() async throws {
        let harness = try await AddonHarness.make()
        let firstRun = try harness.registry(defaults: [harness.address().manifestURL.absoluteString])
        await firstRun.start()
        #expect(firstRun.addons.count == 1)

        let model = AppModel(
            dependencies: AppDependencies(
                branding: AppBranding(name: "Test", bundleIdentifier: "test.app", version: "1", build: "1"),
                addonClient: harness.client,
                database: harness.database,
                imagePipeline: ImagePipeline(http: StubHTTPClient(data: Data()), directory: nil),
                defaultAddonAddresses: []
            ),
            reportMilestone: { _ in nil }
        )
        await model.start()
        #expect(await eventually { model.home.rows.count == 2 })
        #expect(model.discover.hasCatalogs)
        #expect(model.search.hasSearchableAddons)
    }
}

@Suite("Presentation helpers")
struct PresentationTests {
    @Test("Only well-formed YouTube ids are accepted", arguments: [
        ("PLl99DlL6b4", true),
        ("abc_DEF-123", true),
        ("", false),
        ("short", false),
        ("has space 1", false),
        ("\"><script>x</script>", false),
        ("abcdefghijk?autoplay=0", false),
        ("waytoolongtobeayoutubevideoid", false),
    ])
    func youTubeIDs(text: String, isValid: Bool) {
        #expect((YouTubeVideoID(text) != nil) == isValid)
    }

    @Test("A valid id produces the watch and embed URLs")
    func youTubeURLs() throws {
        let video = try #require(YouTubeVideoID("PLl99DlL6b4"))
        #expect(video.watchURL?.absoluteString == "https://www.youtube.com/watch?v=PLl99DlL6b4")
        #expect(video.embedURL.hasPrefix("https://www.youtube-nocookie.com/embed/PLl99DlL6b4?"))
    }

    @Test("Episode dates are marked as upcoming when in the future")
    func releaseText() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let past = DetailModel.releaseText(for: now.addingTimeInterval(-86400 * 30), now: now)
        let future = DetailModel.releaseText(for: now.addingTimeInterval(86400 * 30), now: now)
        #expect(!past.hasPrefix("Airs"))
        #expect(future.hasPrefix("Airs "))
    }

    @Test("Types sort with the well-known ones first")
    func typeOrder() {
        let sorted = [MediaType(rawValue: "anime"), .tv, .series, .movie, MediaType(rawValue: "Anime2")]
            .sorted(by: MediaType.displayOrder)
        #expect(sorted.map(\.rawValue) == ["movie", "series", "tv", "Anime2", "anime"])
        #expect(MediaType(rawValue: "anime").pluralTitle == "Anime")
        #expect(MediaType.channel.pluralTitle == "Channels")
    }
}
