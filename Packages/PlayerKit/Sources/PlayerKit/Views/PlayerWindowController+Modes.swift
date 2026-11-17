import AppKit

/// The window's three forms (normal, picture in picture, mini) and how it changes between them.
extension PlayerWindowController {
    public var mode: PlayerWindowMode {
        chrome.windowMode
    }

    /// Turns the window into a normal, picture-in-picture or mini window.
    public func setMode(_ newMode: PlayerWindowMode) {
        enteredMiniAutomatically = false
        applyMode(newMode)
    }

    func applyMode(_ newMode: PlayerWindowMode) {
        guard newMode != mode else { return }
        if isFullScreen {
            // The window cannot change shape until full screen has been left.
            pendingMode = newMode
            toggleFullScreen()
            return
        }
        if mode == .standard {
            standardFrame = window.frame
        } else if mode == .mini {
            model.setVideoEnabled(true)
        }
        chrome.isSettingsPanelVisible = false
        chrome.isQueueVisible = false
        chrome.windowMode = newMode

        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(origin: .zero, size: Self.initialSize)
        let content = window.contentRect(forFrameRect: window.frame)
        let video = model.displayedVideoSize
        switch newMode {
        case .standard:
            window.contentMinSize = Self.minimumSize
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            constrainProportions(to: video)
            setFrame(standardFrame ?? window.frameRect(forContentRect: NSRect(origin: content.origin, size: Self.initialSize)))
            if let video {
                // The video may have changed while the window was small.
                sizedForVideo = video
                fitWindow(toVideoOf: video)
            }
        case .pictureInPicture:
            window.contentMinSize = PlayerWindowLayout.pictureInPictureMinimum
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            constrainProportions(to: video ?? CGSize(width: 16, height: 9))
            setFrame(window.frameRect(forContentRect: PlayerWindowLayout.pictureInPictureFrame(video: video, visibleFrame: visibleFrame)))
        case .mini:
            // Nothing shows the picture, so it need not be decoded.
            model.setVideoEnabled(false)
            constrainProportions(to: nil)
            let height = PlayerWindowLayout.miniSize.height
            window.contentMinSize = NSSize(width: PlayerWindowLayout.miniWidthRange.lowerBound, height: height)
            window.contentMaxSize = NSSize(width: PlayerWindowLayout.miniWidthRange.upperBound, height: height)
            setFrame(window.frameRect(forContentRect: PlayerWindowLayout.miniFrame(replacing: content)))
        }
        applyWindowStyle()
    }

    /// Locks the window to the video's shape, or frees it.
    func constrainProportions(to size: CGSize?) {
        if let size, size.width > 0, size.height > 0 {
            window.contentAspectRatio = size
        } else {
            // Setting increments is how AppKit is told to forget an aspect ratio.
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
        }
    }

    /// Moves and resizes the window, animated when it is on screen.
    ///
    /// Through the animator rather than `setFrame(_:display:animate:)`: that one does not return
    /// until the animation is over, running the event loop (and SwiftUI layout) inside whatever
    /// called it, which is often a SwiftUI action.
    func setFrame(_ frame: NSRect) {
        guard window.isVisible else {
            window.setFrame(frame, display: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().setFrame(frame, display: true)
        }
    }

    /// Title bar, buttons and Spaces behaviour for the current mode.
    func applyWindowStyle() {
        let isPictureInPicture = mode == .pictureInPicture
        window.titleVisibility = mode == .standard ? .visible : .hidden
        // Picture in picture has its own close and return buttons, shown on hover.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = isPictureInPicture
        }
        window.standardWindowButton(.zoomButton)?.isEnabled = mode == .standard
        if isPictureInPicture {
            // On every Space, and over other apps' full-screen windows.
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        } else {
            window.collectionBehavior.subtract([.canJoinAllSpaces, .fullScreenAuxiliary])
            if mode == .standard {
                window.collectionBehavior.insert(.fullScreenPrimary)
            } else {
                window.collectionBehavior.remove(.fullScreenPrimary)
            }
        }
        applyWindowLevel()
    }

    func applyWindowLevel() {
        window.level = mode == .pictureInPicture || chrome.isAlwaysOnTop ? .floating : .normal
    }

    /// Sound without a picture gets the mini player by itself, and gives the normal window
    /// back when a video follows. A mode the user chose is left alone.
    func followKind(isAudioOnly: Bool) {
        if isAudioOnly, mode == .standard, !isFullScreen {
            applyMode(.mini)
            enteredMiniAutomatically = true
        } else if !isAudioOnly, mode == .mini, enteredMiniAutomatically {
            enteredMiniAutomatically = false
            applyMode(.standard)
        }
    }

    func reshapePictureInPicture(for videoSize: CGSize) {
        guard window.contentAspectRatio != videoSize else { return }
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let content = window.contentRect(forFrameRect: window.frame)
        window.contentAspectRatio = videoSize
        setFrame(window.frameRect(forContentRect: PlayerWindowLayout.reshapedPictureInPictureFrame(
            current: content, video: videoSize, visibleFrame: visibleFrame
        )))
    }

    /// Gives the window the video's proportions, at one point per video pixel but never
    /// more than most of the screen, keeping it centred where it was.
    func fitWindow(toVideoOf videoSize: CGSize) {
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
}
