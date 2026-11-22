import Foundation

/// Loudness, and closing what is open.
public extension PlayerModel {
    /// Sets the volume, 0–100.
    func setVolume(_ volume: Double) {
        let clamped = min(max(volume, 0), 100)
        state.volume = clamped
        client.set("volume", to: .double(clamped))
        if clamped > 0, state.isMuted {
            setMuted(false)
        }
        rememberVolumeSoon()
    }

    func setMuted(_ isMuted: Bool) {
        state.isMuted = isMuted
        client.set("mute", to: .flag(isMuted))
        rememberVolumeSoon()
    }

    func toggleMute() {
        setMuted(!state.isMuted)
    }

    /// Closes the current file but keeps the player ready for another.
    func stop() {
        client.command(["stop"])
    }
}
