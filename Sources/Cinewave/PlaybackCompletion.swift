/// mpv keeps the last frame open at EOF. Both the property and lifecycle event
/// may report completion; consume it once, and rearm after a seek or a new load.
struct PlaybackCompletion {
    private var loaded = false
    private var completed = false

    mutating func beginLoad() {
        loaded = false
        completed = false
    }

    mutating func fileLoaded() {
        loaded = true
        completed = false
    }

    mutating func observe(eofReached: Bool) -> Bool {
        guard loaded else { return false }
        if !eofReached {
            completed = false
            return false
        }
        guard !completed else { return false }
        completed = true
        return true
    }
}
