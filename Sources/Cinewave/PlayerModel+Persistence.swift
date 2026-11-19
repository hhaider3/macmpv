import Foundation

extension PlayerModel {
    struct PlaybackMarkers: Codable {
        var introEnd: Double?
        var outroStart: Double?
    }

    /// A resume point plus when it was last written, so the store can drop the
    /// least recently watched entries instead of growing forever.
    struct RememberedPosition: Codable, Equatable {
        var seconds: Double
        var updatedAt: Date
    }

    /// The subtitle a video should open with.
    enum SubtitleChoice: Codable, Equatable {
        case off
        /// A track inside the video, by mpv track ID.
        case embedded(id: String)
        /// A subtitle file on disk, added by the user or auto-loaded beside the video.
        case external(path: String)
    }

    /// Per-video track choices, restored each time that video loads.
    struct RememberedTracks: Codable, Equatable {
        var audioID: String?
        var subtitle: SubtitleChoice?
        var subtitleDelay: Double?
        var updatedAt: Date

        var isEmpty: Bool {
            audioID == nil && subtitle == nil && subtitleDelay == nil
        }
    }

    /// The 1.9 development store held only external subtitle paths.
    struct LegacyRememberedSubtitle: Codable {
        var path: String
        var updatedAt: Date
    }

    struct QueuePersistence: Codable {
        var items: [MediaItem]
        var expandedGroupIDs: [UUID]
        var isSidebarVisible: Bool
    }

    func rememberCurrentProgress(saveImmediately: Bool) {
        // Torrent entries use the source and original file index, not the
        // temporary HTTP URL, so their saved playback position is stable too.
        guard let currentItem else { return }
        let key = persistenceKey(for: currentItem)
        var didFinishEntry = false
        if position >= 5, duration <= 0 || position < duration - 10 {
            rememberedPositions[key] = RememberedPosition(seconds: position, updatedAt: Date())
        } else if duration > 0, position >= duration - 10 {
            didFinishEntry = rememberedPositions.removeValue(forKey: key) != nil
        }

        if saveImmediately {
            lastPersistedPosition = position
            persistPositions()
        } else if didFinishEntry {
            // Deletions happen once per file end — persist them now instead of
            // through the 1-second gate, so a crash cannot resurrect a stale
            // end-of-file resume position before completion is processed.
            lastPersistedPosition = position
            persistPositions()
        } else {
            // Snapshots arrive many times per second. A debounce task never fired
            // during playback (each snapshot cancelled the pending wait), so
            // persist directly, but only once per second of playback progress —
            // a mid-playback crash then costs at most one second of resume data.
            guard lastPersistedPosition.map({ abs(position - $0) >= 1 }) ?? true else { return }
            lastPersistedPosition = position
            persistPositions()
        }
    }

    func saveCurrentMarkers() {
        guard let currentItem else { return }
        rememberedMarkers[persistenceKey(for: currentItem)] = PlaybackMarkers(
            introEnd: introEndMarker,
            outroStart: outroStartMarker
        )
        persistMarkers()
    }

    /// Applies a change to the current video's remembered tracks and saves it.
    func updateRememberedTracks(_ change: (inout RememberedTracks) -> Void) {
        guard let currentItem else { return }
        let key = persistenceKey(for: currentItem)
        var tracks = rememberedTracks[key] ?? RememberedTracks(updatedAt: Date())
        let before = tracks
        change(&tracks)
        guard tracks.audioID != before.audioID
            || tracks.subtitle != before.subtitle
            || tracks.subtitleDelay != before.subtitleDelay
        else { return }
        tracks.updatedAt = Date()
        rememberedTracks[key] = tracks.isEmpty ? nil : tracks
        persistTracks()
    }

    func rememberSubtitleChoice(_ track: MPVEngine.MediaTrack?) {
        let choice: SubtitleChoice
        if let track {
            choice = track.externalFilename.map {
                .external(path: URL(fileURLWithPath: $0).standardizedFileURL.path)
            } ?? .embedded(id: track.id)
        } else {
            choice = .off
        }
        updateRememberedTracks { $0.subtitle = choice }
    }

    /// Re-applies the current video's remembered audio and subtitle choices after
    /// it loads. Choices that no longer match a track are skipped. mpv may have
    /// auto-loaded a remembered file already (sub-auto), so that track is
    /// selected instead of adding a duplicate. A missing file is kept, since it
    /// may live on a drive that is not mounted right now. Returns true when a
    /// subtitle file was added, so the caller can refresh tracks again.
    @discardableResult
    func restoreRememberedTracks() -> Bool {
        guard let currentItem, let saved = rememberedTracks[persistenceKey(for: currentItem)] else {
            return false
        }
        if let audioID = saved.audioID,
           let track = engine.availableTracks(kind: .audio).first(where: { $0.id == audioID }) {
            engine.selectTrack(track)
        }
        let subtitles = engine.availableTracks(kind: .subtitle)
        switch saved.subtitle {
        case nil:
            return false
        case .off:
            engine.selectTrack(nil)
            return false
        case .embedded(let id):
            if let track = subtitles.first(where: { $0.id == id && $0.externalFilename == nil }) {
                engine.selectTrack(track)
            }
            return false
        case .external(let path):
            guard FileManager.default.fileExists(atPath: path) else { return false }
            let alreadyLoaded = subtitles.first { track in
                track.externalFilename.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path
            }
            if let alreadyLoaded {
                engine.selectTrack(alreadyLoaded)
                return false
            }
            return engine.addExternalSubtitle(URL(fileURLWithPath: path))
        }
    }

    /// Reads the tracks store, migrating the earlier subtitle-files store once.
    func loadRememberedTracks() -> [String: RememberedTracks] {
        if let tracks = load([String: RememberedTracks].self, key: Self.tracksDefaultsKey) {
            return tracks
        }
        guard let legacy = load([String: LegacyRememberedSubtitle].self, key: Self.legacySubtitleFilesDefaultsKey) else {
            return [:]
        }
        return legacy.mapValues {
            RememberedTracks(subtitle: .external(path: $0.path), updatedAt: $0.updatedAt)
        }
    }

    /// Capped to the most recently changed entries, like resume positions.
    func persistTracks() {
        let overflow = rememberedTracks.count - Self.maximumRememberedTracks
        if overflow > 0 {
            let oldest = rememberedTracks
                .sorted { $0.value.updatedAt < $1.value.updatedAt }
                .prefix(overflow)
                .map(\.key)
            for key in oldest {
                rememberedTracks.removeValue(forKey: key)
            }
        }
        if let data = try? JSONEncoder().encode(rememberedTracks) {
            defaults.set(data, forKey: Self.tracksDefaultsKey)
        }
    }

    func persistStores() {
        persistPositions()
        persistMarkers()
    }

    /// Runs about once per second during playback, so it writes only the
    /// positions store, capped to the most recently watched entries.
    func persistPositions() {
        let overflow = rememberedPositions.count - Self.maximumRememberedPositions
        if overflow > 0 {
            let oldest = rememberedPositions
                .sorted { $0.value.updatedAt < $1.value.updatedAt }
                .prefix(overflow)
                .map(\.key)
            for key in oldest {
                rememberedPositions.removeValue(forKey: key)
            }
        }
        if let positions = try? JSONEncoder().encode(rememberedPositions) {
            defaults.set(positions, forKey: Self.positionsDefaultsKey)
        }
    }

    /// Markers change only when the user sets or clears them.
    func persistMarkers() {
        if let markers = try? JSONEncoder().encode(rememberedMarkers) {
            defaults.set(markers, forKey: Self.markersDefaultsKey)
        }
    }

    /// Reads the dated positions store, migrating the original undated
    /// [path: seconds] store once. Migrated entries count as the oldest.
    func loadRememberedPositions() -> [String: RememberedPosition] {
        if let positions = load([String: RememberedPosition].self, key: Self.positionsDefaultsKey) {
            return positions
        }
        guard let legacy = load([String: Double].self, key: Self.legacyPositionsDefaultsKey) else {
            return [:]
        }
        return legacy.mapValues { RememberedPosition(seconds: $0, updatedAt: .distantPast) }
    }

    func persistQueueState() {
        let state = QueuePersistence(
            items: queue,
            expandedGroupIDs: Array(expandedQueueGroupIDs),
            isSidebarVisible: isSidebarVisible
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.queueDefaultsKey)
        }
    }

    func persistenceKey(for url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    func persistenceKey(for item: MediaItem) -> String {
        let sourceKey = persistenceKey(for: item.url)
        guard let torrentFile = item.torrentFile else { return sourceKey }
        return "\(sourceKey)#torrent-file=\(torrentFile.index)"
    }

    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func isRestorableQueueItem(_ item: MediaItem) -> Bool {
        !item.url.isFileURL || FileManager.default.fileExists(atPath: item.url.path)
    }

}
