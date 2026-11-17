@testable import AppUI
import Foundation
import Testing

private let repository = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

@Suite("Third-party software and its licences")
struct ThirdPartyCatalogTests {
    @Test("The shipped list reads, names a licence and a file for everything, and links only to web pages")
    func shippedList() throws {
        let catalog = try #require(ThirdPartyCatalog.load(from: repository.appending(path: "Config")))
        #expect(catalog.groups.map(\.title) == ["Playback engine", "Stream engine", "Audio conversion helper", "App"])
        #expect(!catalog.sourceNote.isEmpty)
        let components = catalog.groups.flatMap(\.components)
        #expect(components.count >= 25)
        for component in components {
            #expect(!component.name.isEmpty && !component.license.isEmpty, "\(component.name)")
            #expect(!component.files.isEmpty, "\(component.name) has no licence text")
            #expect(component.url?.scheme == "https", "\(component.name)")
        }
        // Two entries may share a text (OpenSSL is in both engines) but are still told apart.
        #expect(Set(components.map(\.id)).count == components.count)
    }

    @Test("Every licence text that is collected is listed, and every listed one is collected")
    func matchesLock() throws {
        let catalog = try #require(ThirdPartyCatalog.load(from: repository.appending(path: "Config")))
        let lock = try String(contentsOf: repository.appending(path: "Config/licenses.lock"), encoding: .utf8)
        let downloaded = lock.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("#") }
            .compactMap { $0.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) }
        // libtorrent's and Boost's come out of their source archives, not the lock.
        let collected = Set(downloaded + ["libtorrent-LICENSE.txt", "Boost-LICENSE_1_0.txt"])
        #expect(downloaded.count == Set(downloaded).count)
        #expect(Set(catalog.allFiles) == collected)
    }

    @Test("A list that is missing or broken is no list, not a crash")
    func missing() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "about-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ThirdPartyCatalog.load(from: folder) == nil)
        try Data("{\"groups\": 3}".utf8).write(to: folder.appending(path: "ThirdParty.json"))
        #expect(ThirdPartyCatalog.load(from: folder) == nil)
    }
}

@MainActor
@Suite("Acknowledgements window")
struct AcknowledgementsModelTests {
    private func makeResources() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "Licenses"), withIntermediateDirectories: true)
        try Data("""
        {"sourceNote": "Where the source is.", "groups": [{"title": "Engine", "note": "A library.", "components": [
          {"name": "One", "version": "1.0", "license": "MIT", "url": "https://one.example", "files": ["one.txt", "shared.txt"]},
          {"name": "Two", "version": "", "license": "BSD", "url": "https://two.example", "files": ["../secret.txt", "gone.txt"]}
        ]}]}
        """.utf8).write(to: folder.appending(path: "ThirdParty.json"))
        try Data("Licence of One".utf8).write(to: folder.appending(path: "Licenses/one.txt"))
        try Data("Shared text".utf8).write(to: folder.appending(path: "Licenses/shared.txt"))
        try Data("not a licence".utf8).write(to: folder.appending(path: "secret.txt"))
        return folder
    }

    @Test("The first component is shown to begin with; choosing another shows its texts in order")
    func selection() throws {
        let resources = try makeResources()
        defer { try? FileManager.default.removeItem(at: resources) }
        let model = AcknowledgementsModel(resources: resources)
        #expect(model.selectedComponent?.title == "One 1.0")
        #expect(model.texts.map(\.file) == ["one.txt", "shared.txt"])
        #expect(model.texts.map(\.text) == ["Licence of One", "Shared text"])

        let second = try #require(model.catalog?.groups.first?.components.last)
        #expect(second.title == "Two")
        model.selection = second.id
        // A name is only ever looked up inside the licences folder, and a missing text says where to find it.
        #expect(model.texts.count == 2)
        #expect(model.texts.allSatisfy { $0.text.hasPrefix("This licence text is missing") && $0.text.contains("https://two.example") })
    }

    @Test("Without resources there is nothing to show")
    func empty() {
        let model = AcknowledgementsModel(resources: nil)
        #expect(model.catalog == nil)
        #expect(model.texts.isEmpty)
        #expect(model.selectedComponent == nil)
    }
}

@Suite("Update configuration")
struct UpdateConfigurationTests {
    /// 32 bytes, as an Ed25519 public key is.
    private let key = Data(repeating: 7, count: 32).base64EncodedString()

    @Test("An https feed and a 32-byte key make an updater")
    func valid() throws {
        let configuration = try #require(UpdateConfiguration(feedURL: " https://updates.example.com/appcast.xml\n", publicKey: key))
        #expect(configuration.feedURL.absoluteString == "https://updates.example.com/appcast.xml")
        #expect(configuration.publicKey == key)
        #expect(UpdateConfiguration(infoDictionary: ["SUFeedURL": "https://u.example/a.xml", "SUPublicEDKey": key]) != nil)
    }

    @Test("Anything less means no updater", arguments: [
        (nil, nil), ("", ""), ("https://updates.example.com/appcast.xml", nil), ("https://updates.example.com/appcast.xml", ""),
        ("https://updates.example.com/appcast.xml", "not base64!"), ("https://updates.example.com/appcast.xml", "c2hvcnQ="),
        ("http://updates.example.com/appcast.xml", "KEY"), ("file:///tmp/appcast.xml", "KEY"), ("https:///appcast.xml", "KEY"),
        ("appcast.xml", "KEY"), (nil, "KEY"),
    ] as [(String?, String?)])
    func invalid(feed: String?, keyText: String?) {
        let publicKey = keyText == "KEY" ? key : keyText
        #expect(UpdateConfiguration(feedURL: feed, publicKey: publicKey) == nil)
    }

    @Test("An Info.plist without the keys, or with the wrong types, means no updater")
    func infoDictionary() {
        #expect(UpdateConfiguration(infoDictionary: nil) == nil)
        #expect(UpdateConfiguration(infoDictionary: [:]) == nil)
        #expect(UpdateConfiguration(infoDictionary: ["SUFeedURL": 3, "SUPublicEDKey": key]) == nil)
    }
}
