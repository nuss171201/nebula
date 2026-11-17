import AppKit
import Foundation
import Observation
import PlayerKit
import UniformTypeIdentifiers

/// Opens things in the player. There is one player window at a time: opening
/// something else while it is up replaces what is playing.
@MainActor
@Observable
public final class PlayerCoordinator {
    /// Whether the player window is currently open.
    public private(set) var isPlayerOpen = false
    /// Why the last attempt to open something failed, in words for the user.
    public var errorMessage: String?
    /// Drives the "Open Location" sheet.
    public var isOpenLocationPresented = false

    /// How new players are set up. The app updates this once stored preferences are loaded.
    @ObservationIgnored public var configuration: PlayerConfiguration
    @ObservationIgnored private let memory: (any PlayerMemory)?
    @ObservationIgnored private let subtitleService: (any OnlineSubtitleService)?
    @ObservationIgnored private let presentsWindow: Bool
    @ObservationIgnored private var controller: PlayerWindowController?

    /// - Parameters:
    ///   - memory: Where track choices and volume are remembered; `nil` remembers nothing.
    ///   - subtitleService: Where the player looks for subtitles on the network, if anywhere.
    ///   - presentsWindow: `false` keeps the player window off screen. For tests.
    public init(
        configuration: PlayerConfiguration,
        memory: (any PlayerMemory)? = nil,
        subtitleService: (any OnlineSubtitleService)? = nil,
        presentsWindow: Bool = true
    ) {
        self.configuration = configuration
        self.memory = memory
        self.subtitleService = subtitleService
        self.presentsWindow = presentsWindow
    }

    /// The model of the open player, if any.
    public var player: PlayerModel? {
        controller?.model
    }

    /// Plays a file path or web address typed by the user. Returns whether it was accepted.
    @discardableResult
    public func play(userInput: String) -> Bool {
        do {
            try play(PlayableSource(userInput: userInput))
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    @discardableResult
    public func play(fileURL: URL) -> Bool {
        do {
            try play(PlayableSource(url: fileURL))
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    public func play(_ source: PlayableSource) {
        errorMessage = nil
        if let controller {
            controller.model.open(source)
            show(controller)
            return
        }
        do {
            let model = try PlayerModel(configuration: configuration, memory: memory)
            let controller = PlayerWindowController(model: model, subtitleService: subtitleService)
            controller.onClose = { [weak self] in
                self?.controller = nil
                self?.isPlayerOpen = false
            }
            self.controller = controller
            isPlayerOpen = true
            model.open(source)
            show(controller)
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// Adds a file path or web address to the end of the queue; with no player open, plays it.
    /// Returns whether it was accepted.
    @discardableResult
    public func enqueue(userInput: String) -> Bool {
        do {
            let source = try PlayableSource(userInput: userInput)
            if let controller {
                errorMessage = nil
                controller.model.enqueue(source)
            } else {
                play(source)
            }
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    private func show(_ controller: PlayerWindowController) {
        if presentsWindow {
            controller.show()
        }
    }

    /// Opens the player's quick-settings panel on a tab, if a player is open.
    public func showPlayerSettings(_ tab: PlayerSettingsTab) {
        controller?.chrome.settingsTab = tab
        controller?.chrome.isSettingsPanelVisible = true
    }

    /// Opens the subtitle panel and looks a title up in it, as if typed into its search field.
    /// For checking the online subtitle search without the keyboard.
    public func searchSubtitleTitles(_ query: String) {
        guard let controller, let online = controller.onlineSubtitles else { return }
        showPlayerSettings(.subtitles)
        online.prepare(for: controller.model.source)
        online.query = query
        online.searchTitles()
    }

    /// Opens the player's queue panel, if a player is open.
    public func showQueue() {
        controller?.chrome.isQueueVisible = true
    }

    /// Types plain keys into the player window, as if on the keyboard. For checking key
    /// bindings and their on-screen notices without taking the keyboard.
    public func pressKeys(_ characters: String) {
        for character in characters.lowercased() {
            controller?.press(KeyChord(.character(character)))
        }
    }

    /// Shows the seek bar's hover preview at a fraction of the file, as if the pointer were there.
    /// For checking the preview without a pointer.
    public func showSeekPreview(atFraction fraction: Double) {
        // A pointer over the seek bar is also over the controls, which keeps them from hiding.
        controller?.chrome.userDidInteract()
        controller?.chrome.pointerIsOnControls(true)
        controller?.chrome.seekHoverFraction = min(max(fraction, 0), 1)
    }

    public func closePlayer() {
        controller?.close()
    }

    /// Shows the standard Open panel and plays the chosen file.
    public func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.playableTypes
        panel.message = "Choose a video or audio file to play."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.play(fileURL: url)
            }
        }
    }

    /// Video and audio in general, plus common containers the system has no type for.
    static let playableTypes: [UTType] = {
        let extras = ["mkv", "webm", "ts", "m2ts", "flv", "ogv", "ogg", "opus", "flac", "mka", "wmv", "rmvb"]
        return [.movie, .video, .audio, .audiovisualContent] + extras.compactMap { UTType(filenameExtension: $0) }
    }()
}
