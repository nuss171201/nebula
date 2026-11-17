import Foundation

/// Track switching, automatic selection when a file opens, and what is remembered between sessions.
extension PlayerModel {
    /// Switches to a track, or turns that kind of track off with `nil`. This is the user's
    /// choice, so it is remembered for this title.
    public func selectTrack(_ kind: MediaTrack.Kind, number: Int?) {
        applyTrack(kind, number: number)
        let track = state.tracks.first { $0.kind == kind && $0.number == number }
        switch kind {
        case .audio:
            guard let track else { return }
            rememberedForCurrentFile.audio = TrackDescriptor(track)
        case .subtitle:
            rememberedForCurrentFile.subtitle = track.map { .track(TrackDescriptor($0)) } ?? .off
        case .video:
            return
        }
        let (choice, keys) = (rememberedForCurrentFile, currentMemoryKeys)
        Task { [memory] in
            await memory?.remember(choice, for: keys)
        }
    }

    /// Loads a subtitle file into the open video and switches to it. Returns whether the
    /// engine could read it.
    ///
    /// - Parameters:
    ///   - title: Shown in the track list; the file name when `nil`.
    ///   - language: A language tag for the track, when known.
    @discardableResult
    public func addSubtitle(fileURL: URL, title: String? = nil, language: String? = nil) async -> Bool {
        guard state.hasMedia, fileURL.isFileURL else { return false }
        // The engine takes title and language by position, so a language needs a title before it.
        var arguments = ["sub-add", fileURL.path, "select"]
        if title != nil || language != nil {
            arguments.append(title ?? fileURL.lastPathComponent)
        }
        if let language {
            arguments.append(language)
        }
        let (client, generation) = (client, fileGeneration)
        let result = await Task.detached(priority: .userInitiated) {
            client.commandResult(arguments)
        }.value
        guard result != nil, generation == fileGeneration else {
            if generation == fileGeneration {
                announce("Could Not Read the Subtitle File")
            }
            return false
        }
        // Someone who adds subtitles wants to see them.
        subtitles.isVisible = true
        if let language {
            // Remember the language, so the next episode picks it if it has it.
            rememberedForCurrentFile.subtitle = .track(TrackDescriptor(language: language))
            let (choice, keys) = (rememberedForCurrentFile, currentMemoryKeys)
            Task { [memory] in
                await memory?.remember(choice, for: keys)
            }
        }
        return true
    }

    func applyTrack(_ kind: MediaTrack.Kind, number: Int?) {
        let property = switch kind {
        case .video: "vid"
        case .audio: "aid"
        case .subtitle: "sid"
        }
        if kind == .audio, let number {
            audioFallback.wantedTrack = number
        }
        client.set(property, to: .string(number.map(String.init) ?? "no"))
    }

    /// The names the open file's choices are remembered under.
    var currentMemoryKeys: [String] {
        guard let source else { return [] }
        return explicitMemoryKeys[source.engineArgument] ?? source.memoryKeys
    }

    /// When a file has loaded: look up what is remembered for it and pick its tracks.
    func selectTracksForLoadedFile() {
        fileGeneration += 1
        let generation = fileGeneration
        let keys = currentMemoryKeys
        rememberedForCurrentFile = RememberedTracks()
        selectionTask = Task { [weak self, memory] in
            let remembered = await memory?.rememberedTracks(forAnyOf: keys)
            guard let self, generation == fileGeneration else { return }
            rememberedForCurrentFile = remembered ?? RememberedTracks()
            let selection = TrackSelector.selection(tracks: state.tracks, preferences: trackPreferences, remembered: remembered)
            // A track that would not decode is not asked for again.
            if let audio = selection.audio, state.selectedTrack(of: .audio)?.number != audio, !audioFallback.failedTracks.contains(audio) {
                applyTrack(.audio, number: audio)
            }
            switch selection.subtitle {
            case .off where state.selectedTrack(of: .subtitle) != nil:
                applyTrack(.subtitle, number: nil)
            case let .track(number) where state.selectedTrack(of: .subtitle)?.number != number:
                applyTrack(.subtitle, number: number)
            default:
                break
            }
        }
    }

    /// Waits for the automatic track selection of the open file. For tests.
    func waitForTrackSelection() async {
        await selectionTask?.value
    }

    func restore(_ volume: RememberedVolume) {
        let level = min(max(volume.level, 0), 100)
        state.volume = level
        state.isMuted = volume.isMuted
        client.set("volume", to: .double(level))
        client.set("mute", to: .flag(volume.isMuted))
    }

    /// Saves the volume a moment after the last change, so dragging the slider writes once.
    func rememberVolumeSoon() {
        guard let memory else { return }
        volumeSaveTask?.cancel()
        let volume = RememberedVolume(level: state.volume, isMuted: state.isMuted)
        volumeSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await memory.remember(volume)
        }
    }

    /// Waits for a pending volume save. For tests.
    func waitForVolumeSave() async {
        await volumeSaveTask?.value
    }

    /// Selects the next track of a kind, wrapping round; subtitles also pass through "off".
    func cycleTrack(_ kind: MediaTrack.Kind) {
        let name = switch kind {
        case .video: "Video"
        case .audio: "Audio"
        case .subtitle: "Subtitles"
        }
        let tracks = state.tracks(of: kind)
        guard !tracks.isEmpty else {
            announce("\(name): None in This File")
            return
        }
        let current = tracks.firstIndex { $0.isSelected }
        let next: MediaTrack? = switch (kind, current) {
        case (_, nil): tracks[0]
        case let (.subtitle, index?) where index == tracks.count - 1: nil
        case let (_, index?): tracks[(index + 1) % tracks.count]
        }
        selectTrack(kind, number: next?.number)
        announce("\(name): \(next?.displayName() ?? "Off")")
    }
}
