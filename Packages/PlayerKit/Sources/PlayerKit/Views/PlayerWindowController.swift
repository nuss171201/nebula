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
    private static let initialSize = NSSize(width: 1280, height: 720)
    private static let minimumSize = NSSize(width: 640, height: 360)

    public let model: PlayerModel
    /// Called after the window has closed and the player has been told to shut down.
    public var onClose: (@MainActor () -> Void)?

    let window: PlayerWindow
    /// Which of the window's controls and panels are showing.
    public let chrome = PlayerChromeModel()
    private let bindings: KeyBindings
    private var sizedForVideo: CGSize?

    public init(model: PlayerModel, bindings: KeyBindings = .standard) {
        self.model = model
        self.bindings = bindings
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
        window.contentView = NSHostingView(rootView: PlayerView(model: model, chrome: chrome) { [weak self] in
            self?.toggleFullScreen()
        })
        window.setContentSize(Self.initialSize)
        window.center()
        window.onKeyDown = { [weak self] chord in
            self?.handle(chord) ?? false
        }
        followModel()
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
            toggleFullScreen()
            return true
        case .exitFullScreen:
            // Escape closes the settings panel first, then leaves full screen.
            if chrome.isSettingsPanelVisible {
                chrome.isSettingsPanelVisible = false
                return true
            }
            guard isFullScreen else { return false }
            toggleFullScreen()
            return true
        case let .toggleSettings(tab):
            chrome.toggleSettingsPanel(tab)
            return true
        default:
            return model.perform(command)
        }
    }

    private func handle(_ chord: KeyChord) -> Bool {
        guard let command = bindings.command(for: chord) else { return false }
        chrome.userDidInteract()
        return perform(command)
    }

    /// Updates the window whenever the media's title or picture size changes.
    private func followModel() {
        let (title, videoSize) = withObservationTracking {
            (model.title, model.displayedVideoSize)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followModel()
            }
        }
        window.title = title
        if let videoSize, videoSize != sizedForVideo {
            sizedForVideo = videoSize
            fitWindow(toVideoOf: videoSize)
        }
    }

    /// Gives the window the video's proportions, at one point per video pixel but never
    /// more than most of the screen, keeping it centred where it was.
    private func fitWindow(toVideoOf videoSize: CGSize) {
        window.contentAspectRatio = videoSize
        guard !isFullScreen else { return }
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? Self.initialSize
        // One video pixel per point: on a Retina screen a 720p video at one pixel per screen
        // pixel would be a very small window.
        let natural = videoSize
        let fit = min(1, available.width * 0.8 / natural.width, available.height * 0.8 / natural.height)
        let size = NSSize(
            width: max((natural.width * fit).rounded(), Self.minimumSize.width),
            height: max((natural.height * fit).rounded(), Self.minimumSize.height)
        )
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: center.x - window.frame.width / 2, y: center.y - window.frame.height / 2))
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_: Notification) {
        model.shutdown()
        onClose?()
        onClose = nil
    }
}
