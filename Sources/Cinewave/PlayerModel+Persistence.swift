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

    /// An external subtitle file the user attached to a video, restored each
    /// time that video loads.
    struct RememberedSubtitle: Codable, Equatable {
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

    func rememberSubtitle(_ url: URL) {
        guard let currentItem else { return }
        rememberedSubtitles[persistenceKey(for: currentItem)] = RememberedSubtitle(
            path: url.standardizedFileURL.path,
            updatedAt: Date()
        )
        persistSubtitles()
    }

    func forgetSubtitle() {
        guard let currentItem,
              rememberedSubtitles.removeValue(forKey: persistenceKey(for: currentItem)) != nil
        else { return }
        persistSubtitles()
    }

    /// Re-attaches the current video's remembered subtitle file after it loads.
    /// mpv may already have auto-loaded the same file (sub-auto), so select that
    /// track instead of adding a duplicate. A missing file is kept in the store,
    /// since it may live on a drive that is not mounted right now. Returns true
    /// when a subtitle file was added, so the caller can refresh tracks again.
    @discardableResult
    func restoreRememberedSubtitle() -> Bool {
        guard let currentItem,
              let saved = rememberedSubtitles[persistenceKey(for: currentItem)],
              FileManager.default.fileExists(atPath: saved.path)
        else { return false }
        let alreadyLoaded = engine.availableTracks(kind: .subtitle).first { track in
            track.externalFilename.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == saved.path
        }
        if let alreadyLoaded {
            engine.selectTrack(alreadyLoaded)
            return false
        }
        return engine.addExternalSubtitle(URL(fileURLWithPath: saved.path))
    }

    /// Capped to the most recently attached entries, like resume positions.
    func persistSubtitles() {
        let overflow = rememberedSubtitles.count - Self.maximumRememberedSubtitles
        if overflow > 0 {
            let oldest = rememberedSubtitles
                .sorted { $0.value.updatedAt < $1.value.updatedAt }
                .prefix(overflow)
                .map(\.key)
            for key in oldest {
                rememberedSubtitles.removeValue(forKey: key)
            }
        }
        if let data = try? JSONEncoder().encode(rememberedSubtitles) {
            defaults.set(data, forKey: Self.subtitleFilesDefaultsKey)
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
