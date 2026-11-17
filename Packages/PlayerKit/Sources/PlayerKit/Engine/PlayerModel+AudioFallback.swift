import Foundation

/// Recovering when the engine cannot decode an audio track.
///
/// The engine decodes nearly everything itself, so this rarely runs. When a decoder will not
/// start, the engine deselects the track and plays on in silence; this notices and tries, in
/// order: another track in the same language, converting the track to AAC (if an ffmpeg
/// program is available), any other track. It says what it did.
extension PlayerModel {
    /// Called whenever the track list changes or a frame appears.
    func checkAudioDecoding() {
        if let selected = state.selectedTrack(of: .audio) {
            if !selected.isExternal {
                audioFallback.wantedTrack = selected.number
            }
            return
        }
        guard state.phase == .playing, audioFallback.task == nil,
              let wanted = audioFallback.wantedTrack,
              let failed = state.tracks.first(where: { $0.kind == .audio && $0.number == wanted && !$0.isExternal })
        else { return }

        let generation = fileGeneration
        audioFallback.task = Task { [weak self] in
            // The list is briefly without a selection while the engine switches tracks; only a
            // track that is still not playing a moment later has really failed.
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, generation == fileGeneration else { return }
            if state.selectedTrack(of: .audio) == nil {
                await recover(from: failed, generation: generation)
            }
            audioFallback.task = nil
            // Whatever was switched to may fail too.
            checkAudioDecoding()
        }
    }

    /// Forgets the previous file's failures and removes what was converted for it.
    func resetAudioFallback() {
        audioFallback.task?.cancel()
        let files = Array(audioFallback.convertedFiles.values)
        audioFallback = AudioFallbackState()
        audioProblem = nil
        if !files.isEmpty {
            Task.detached(priority: .utility) {
                for file in files {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    private func recover(from failed: MediaTrack, generation: Int) async {
        audioFallback.failedTracks.insert(failed.number)
        let codec = MediaTrack.codecName(failed.codec) ?? "This audio format"
        logger.error("audio track \(failed.number, privacy: .public) (\(failed.codec ?? "?", privacy: .public)) could not be decoded")

        let step = AudioFallbackState.nextStep(
            failed: failed,
            tracks: state.tracks,
            failedTracks: audioFallback.failedTracks,
            canConvert: audioTranscoder != nil && source != nil
        )
        switch step {
        case let .switchTo(number):
            switchAfterFailure(to: number, codec: codec)
        case .convert:
            if await convert(failed, codec: codec, generation: generation) {
                return
            }
            guard generation == fileGeneration, !Task.isCancelled else { return }
            // Converting did not work either: any other track is better than silence.
            let fallback = AudioFallbackState.nextStep(
                failed: failed, tracks: state.tracks, failedTracks: audioFallback.failedTracks, canConvert: false
            )
            if case let .switchTo(number) = fallback {
                switchAfterFailure(to: number, codec: codec)
            } else {
                giveUp(codec: codec)
            }
        case .giveUp:
            giveUp(codec: codec)
        }
    }

    private func switchAfterFailure(to number: Int, codec: String) {
        let name = state.tracks.first { $0.kind == .audio && $0.number == number }?.displayName() ?? "another track"
        audioProblem = "\(codec) sound cannot be played on this Mac. Playing \(name) instead."
        announce("\(codec) Cannot Be Played: Switched to \(name)")
        audioFallback.wantedTrack = number
        applyTrack(.audio, number: number)
    }

    private func giveUp(codec: String) {
        audioProblem = "\(codec) sound cannot be played on this Mac, and this file has no other sound."
        announce("\(codec) Sound Cannot Be Played")
    }

    /// Converts the track and plays the result as an extra track. Returns whether it worked.
    private func convert(_ failed: MediaTrack, codec: String, generation: Int) async -> Bool {
        guard let audioTranscoder, let source else { return false }
        let internalTracks = state.tracks.filter { $0.kind == .audio && !$0.isExternal }
        guard let index = internalTracks.firstIndex(where: { $0.number == failed.number }) else { return false }

        audioProblem = "\(codec) sound cannot be played directly. Converting it…"
        announce("Converting \(codec) Sound…")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("converted-audio-\(UUID().uuidString)")
            .appendingPathExtension("mka")
        do {
            try await audioTranscoder.transcode(source: source, audioIndex: index, to: output)
        } catch {
            logger.error("audio conversion failed: \(String(describing: error), privacy: .public)")
            return false
        }
        guard generation == fileGeneration, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: output)
            return false
        }
        audioFallback.convertedFiles[failed.number] = output

        let title = "\(failed.displayName()) (converted from \(codec))"
        var arguments = ["audio-add", output.path, "select", title]
        if let language = failed.language {
            arguments.append(language)
        }
        let client = client
        let added = await Task.detached(priority: .userInitiated) {
            client.commandResult(arguments) != nil
        }.value
        guard added, generation == fileGeneration else { return false }
        audioProblem = "\(codec) sound cannot be played directly, so it was converted."
        announce("Playing Converted Sound")
        return true
    }
}
