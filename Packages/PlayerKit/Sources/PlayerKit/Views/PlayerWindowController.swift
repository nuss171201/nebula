import AppKit
import Observation
import SwiftUI

public extension KeyChord {
    /// Translates a key-down into a chord. `nil` for keys the player has no name for.
    init?(keyCode: UInt16, characters: String?, modifierFlags: NSEvent.ModifierFlags) {
        let key: Key
        switch keyCode {
        case 49: key = .space
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        case 125: key = .downArrow
        case 126: key = .upArrow
        case 53: key = .escape
        case 36, 76: key = .returnKey
        default:
            guard let character = characters?.lowercased().first,
                  character.isLetter || character.isNumber || character.isPunctuation || character.isSymbol
            else { return nil }
            key = .character(character)
        }
        var modifiers: Modifiers = []
        if modifierFlags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if modifierFlags.contains(.control) {
            modifiers.insert(.control)
        }
        if modifierFlags.contains(.option) {
            modifiers.insert(.option)
        }
        if modifierFlags.contains(.command) {
            modifiers.insert(.command)
        }
        self.init(key, modifiers)
    }
}

/// The player's window. Key presses that match a binding become player commands.
final class PlayerWindow: NSWindow {
    var onKeyDown: ((KeyChord) -> Bool)?
    /// Scrolling and pinching that no view under the pointer wanted (the panels' lists take their own).
    var onScroll: ((NSEvent) -> Void)?
    var onMagnify: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let chord = KeyChord(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ), onKeyDown?(chord) == true {
            return
        }
        super.keyDown(with: event)
    }
}

/// Owns the player window: builds it around a `PlayerModel`, keeps its title and
/// proportions in step with the media, routes keys, and shuts the player down on close.
@MainActor
public final class PlayerWindowController: NSObject, NSWindowDelegate {
    static let initialSize = NSSize(width: 1280, height: 720)
    static let minimumSize = PlayerWindowLayout.standardMinimum

    public let model: PlayerModel
    /// Called after the window has closed and the player has been told to shut down.
    public var onClose: (@MainActor () -> Void)?
    /// Called with files and folders dropped on the player.
    public var onOpenURLs: (@MainActor ([URL]) -> Void)?
    /// Called with the user's answer to an "up next" offer: `true` to play it now.
    public var onUpNextDecision: (@MainActor (Bool) -> Void)?

    let window: PlayerWindow
    /// Which of the window's controls and panels are showing.
    public let chrome = PlayerChromeModel()
    /// Finds subtitles on the network; `nil` when the app provides no service for it.
    public let onlineSubtitles: OnlineSubtitlesModel?
    let bindings: KeyBindings
    var sizedForVideo: CGSize?
    private var screenObserver: (any NSObjectProtocol)?
    /// Where the normal window was before it became a small one.
    var standardFrame: NSRect?
    /// A mode asked for while in full screen, applied once full screen has been left.
    var pendingMode: PlayerWindowMode?
    /// Whether the mini player came up by itself for a file without a picture.
    var enteredMiniAutomatically = false
    var scrolling = ScrollInterpreter()
    var pinching = PinchInterpreter()
    var nowPlaying: NowPlayingSession?

    /// - Parameters:
    ///   - subtitleService: Where to look for subtitles on the network, if anywhere.
    ///   - nowPlaying: The system's Now Playing display and media keys; `nil` keeps the player to itself.
    public init(
        model: PlayerModel,
        bindings: KeyBindings = .standard,
        subtitleService: (any OnlineSubtitleService)? = nil,
        nowPlaying center: (any NowPlayingCenter)? = nil
    ) {
        self.model = model
        self.bindings = bindings
        onlineSubtitles = subtitleService.map { service in
            let preferences = model.trackPreferences
            return OnlineSubtitlesModel(
                player: model,
                service: service,
                preferredLanguages: preferences.subtitleLanguages + preferences.audioLanguages
            )
        }
        window = PlayerWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = Self.minimumSize
        window.delegate = self
        window.contentView = NSHostingView(rootView: PlayerView(
            model: model,
            chrome: chrome,
            onlineSubtitles: onlineSubtitles,
            openURLs: { [weak self] in self?.onOpenURLs?($0) },
            perform: { [weak self] in self?.perform($0) }
        ))
        window.setContentSize(Self.initialSize)
        window.center()
        connectInput(nowPlaying: center)
        followModel()
        updateDisplayCapabilities()
        // The display's abilities change with its settings too, not only when the window moves.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDisplayCapabilities()
            }
        }
    }

    /// Tells the player whether the screen the window is on can show HDR.
    private func updateDisplayCapabilities() {
        let screen = window.screen ?? NSScreen.main
        model.displaySupportsHDR = (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    }

    public var isFullScreen: Bool {
        window.styleMask.contains(.fullScreen)
    }

    /// Brings the window forward. It becomes the key window if the app is active;
    /// it does not activate the app by itself.
    public func show() {
        window.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window.close()
    }

    public func toggleFullScreen() {
        window.toggleFullScreen(nil)
    }

    /// Runs a command, whether it concerns playback or the window. Returns whether it was handled.
    @discardableResult
    public func perform(_ command: PlayerCommand) -> Bool {
        switch command {
        case .toggleFullScreen:
            // Only the normal window goes full screen.
            setMode(.standard)
            toggleFullScreen()
        case .exitFullScreen:
            return escape()
        case let .toggleSettings(tab):
            setMode(.standard)
            chrome.toggleSettingsPanel(tab)
        case .togglePictureInPicture:
            setMode(mode == .pictureInPicture ? .standard : .pictureInPicture)
        case .toggleMiniPlayer:
            setMode(mode == .mini ? .standard : .mini)
        case .closePlayer:
            close()
        case .acceptUpNext, .declineUpNext:
            guard model.upNext != nil else { return false }
            onUpNextDecision?(command == .acceptUpNext)
        case .toggleAlwaysOnTop:
            chrome.isAlwaysOnTop.toggle()
            applyWindowLevel()
            model.announce(chrome.isAlwaysOnTop ? "Always on Top" : "Not Always on Top")
        default:
            return model.perform(command)
        }
        return true
    }

    /// Escape undoes one thing: closes a side panel, else leaves full screen, else returns a
    /// small window to the normal one. Returns `false` when there was nothing to undo.
    private func escape() -> Bool {
        if model.upNext != nil {
            onUpNextDecision?(false)
        } else if chrome.isSidePanelVisible {
            chrome.isSettingsPanelVisible = false
            chrome.isQueueVisible = false
        } else if isFullScreen {
            toggleFullScreen()
        } else if mode != .standard {
            setMode(.standard)
        } else {
            return false
        }
        return true
    }

    /// Updates the window whenever the media's title or picture size changes.
    private func followModel() {
        let (title, videoSize, hasMedia, isAudioOnly) = withObservationTracking {
            (model.title, model.displayedVideoSize, model.state.hasMedia, model.state.isAudioOnly)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followModel()
            }
        }
        window.title = title
        if hasMedia {
            followKind(isAudioOnly: isAudioOnly)
        }
        if let videoSize, videoSize != sizedForVideo || mode == .pictureInPicture {
            switch mode {
            case .standard:
                sizedForVideo = videoSize
                fitWindow(toVideoOf: videoSize)
            case .pictureInPicture:
                reshapePictureInPicture(for: videoSize)
            case .mini:
                break
            }
        }
    }

    // MARK: - NSWindowDelegate

    public func windowDidChangeScreen(_: Notification) {
        updateDisplayCapabilities()
    }

    public func windowDidExitFullScreen(_: Notification) {
        if let pendingMode {
            self.pendingMode = nil
            applyMode(pendingMode)
        }
    }

    public func windowWillClose(_: Notification) {
        nowPlaying?.stop()
        nowPlaying = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        model.shutdown()
        onClose?()
        onClose = nil
    }
}
