import Foundation

extension PlayerModel {
    struct PlaybackMarkers: Codable {
        var introEnd: Double?
        var outroStart: Double?
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
            rememberedPositions[key] = position
        } else if duration > 0, position >= duration - 10 {
            didFinishEntry = rememberedPositions.removeValue(forKey: key) != nil
        }

        if saveImmediately {
            lastPersistedPosition = position
            persistStores()
        } else if didFinishEntry {
            // Deletions happen once per file end — persist them now instead of
            // through the 1-second gate, so a crash cannot resurrect a stale
            // end-of-file resume position before completion is processed.
            lastPersistedPosition = position
            persistStores()
        } else {
            // Snapshots arrive many times per second. A debounce task never fired
            // during playback (each snapshot cancelled the pending wait), so
            // persist directly, but only once per second of playback progress —
            // a mid-playback crash then costs at most one second of resume data.
            guard lastPersistedPosition.map({ abs(position - $0) >= 1 }) ?? true else { return }
            lastPersistedPosition = position
            persistStores()
        }
    }

    func saveCurrentMarkers() {
        guard let currentItem else { return }
        rememberedMarkers[persistenceKey(for: currentItem)] = PlaybackMarkers(
            introEnd: introEndMarker,
            outroStart: outroStartMarker
        )
        persistStores()
    }

    func persistStores() {
        if let positions = try? JSONEncoder().encode(rememberedPositions) {
            defaults.set(positions, forKey: Self.positionsDefaultsKey)
        }
        if let markers = try? JSONEncoder().encode(rememberedMarkers) {
            defaults.set(markers, forKey: Self.markersDefaultsKey)
        }
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
