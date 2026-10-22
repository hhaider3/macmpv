import Foundation

extension PlayerModel {
    func finderURL(for item: MediaItem) -> URL? {
        if MediaSupport.isTorrentSource(item.url) {
            guard let file = item.torrentFile,
                  let directory = TorrentStorage.downloadDirectory(
                    for: item.url, under: magnetStream.downloadDirectory
                  ),
                  let url = TorrentStorage.downloadedFileURL(for: file, in: directory),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        return item.url.isFileURL ? item.url : nil
    }

    func torrentDownloadState(for item: MediaItem) -> TorrentDownloadState? {
        guard let file = item.torrentFile,
              let hash = torrentInfoHashes[item.url],
              let saved = torrentProgress[hash]?.files[String(file.index)] else { return nil }
        if saved.done { return .local }
        // 100% is reserved for verified files, which show as local instead.
        let percent = file.length > 0 ? Int(saved.downloaded * 100 / file.length) : 0
        return .downloading(percent: min(max(percent, 0), 99))
    }

    /// A torrent file the helper verified as fully saved, which can play from
    /// disk without the helper re-verifying the whole torrent first.
    func verifiedDownloadURL(for item: MediaItem) -> URL? {
        guard let file = item.torrentFile,
              let hash = torrentInfoHashes[item.url],
              let saved = torrentProgress[hash]?.files[String(file.index)],
              saved.done, !saved.measuredOnDisk,
              let url = finderURL(for: item) else { return nil }
        return url
    }

    var queueGroups: [MediaQueueGroup] {
        var groups: [MediaQueueGroup] = []
        var groupIndexes: [UUID: Int] = [:]

        for item in queue {
            if let index = groupIndexes[item.groupID] {
                groups[index].items.append(item)
            } else {
                groupIndexes[item.groupID] = groups.count
                groups.append(
                    MediaQueueGroup(
                        id: item.groupID,
                        title: item.groupTitle ?? item.title,
                        kind: item.groupKind,
                        items: [item]
                    )
                )
            }
        }
        return groups
    }

    func enqueue(_ urls: [URL], playFirst: Bool) {
        let playable = urls.filter(MediaSupport.isPlayable)
        guard !playable.isEmpty else {
            errorMessage = "No supported media files were found."
            return
        }

        var added: [MediaItem] = []
        var regularURLs: [URL] = []

        for url in playable {
            if MediaSupport.isPlaylistSource(url), let playlistURLs = playlistEntries(from: url), !playlistURLs.isEmpty {
                let groupID = UUID()
                let title = url.deletingPathExtension().lastPathComponent
                expandedQueueGroupIDs.insert(groupID)
                for playlistURL in playlistURLs {
                    if let item = appendQueueItem(
                        url: playlistURL,
                        groupID: groupID,
                        groupTitle: title.isEmpty ? "Playlist" : title,
                        groupKind: .playlist
                    ) {
                        added.append(item)
                    }
                }
                continue
            }

            if MediaSupport.isTorrentSource(url) {
                if let existing = queue.first(where: { sameMediaSource($0.url, url) }) {
                    added.append(existing)
                    continue
                }
                let groupID = UUID()
                let container = MediaItem(
                    url: url,
                    groupID: groupID,
                    groupTitle: sourceDisplayTitle(url),
                    groupKind: .torrent
                )
                queue.append(container)
                expandedQueueGroupIDs.insert(groupID)
                added.append(container)
            } else {
                regularURLs.append(url)
            }
        }

        if !regularURLs.isEmpty {
            let isPlaylist = regularURLs.count > 1
            let groupID = UUID()
            let groupTitle = isPlaylist ? selectionPlaylistTitle(for: regularURLs) : nil
            for url in regularURLs {
                if let item = appendQueueItem(
                    url: url,
                    groupID: groupID,
                    groupTitle: groupTitle,
                    groupKind: isPlaylist ? .playlist : .standalone
                ) {
                    added.append(item)
                }
            }
            if isPlaylist, added.contains(where: { $0.groupID == groupID }) {
                expandedQueueGroupIDs.insert(groupID)
            }
        }

        persistQueueState()

        if currentID == nil || playFirst, let first = added.first {
            play(first)
        }
    }

    private func appendQueueItem(
        url: URL,
        groupID: UUID,
        groupTitle: String?,
        groupKind: MediaGroupKind
    ) -> MediaItem? {
        if let existing = queue.first(where: { sameMediaSource($0.url, url) }) {
            return existing
        }

        let item = MediaItem(
            url: url,
            groupID: groupID,
            groupTitle: groupTitle,
            groupKind: groupKind
        )
        queue.append(item)
        inspect(item)
        return item
    }

    private func playlistEntries(from playlistURL: URL) -> [URL]? {
        guard let contents = try? String(contentsOf: playlistURL, encoding: .utf8) else { return nil }
        // An HLS manifest is a stream description, not a user playlist. Leave it
        // intact for mpv instead of turning its transport segments into queue rows.
        let uppercaseContents = contents.uppercased()
        guard !uppercaseContents.contains("#EXT-X-TARGETDURATION"),
              !uppercaseContents.contains("#EXT-X-MEDIA-SEQUENCE"),
              !uppercaseContents.contains("#EXT-X-STREAM-INF") else { return nil }
        let baseURL = playlistURL.deletingLastPathComponent()
        var seen: Set<String> = []

        return contents
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> URL? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

                let resolved: URL
                if let absolute = URL(string: line), absolute.scheme != nil {
                    resolved = absolute
                } else {
                    resolved = URL(fileURLWithPath: line, relativeTo: baseURL).standardizedFileURL
                }

                guard MediaSupport.isPlayable(resolved), !MediaSupport.isPlaylistSource(resolved) else { return nil }
                let identity = persistenceKey(for: resolved)
                guard seen.insert(identity).inserted else { return nil }
                return resolved
            }
    }

    private func sourceDisplayTitle(_ url: URL) -> String {
        MediaItem(url: url).title
    }

    private func selectionPlaylistTitle(for urls: [URL]) -> String {
        let localParents = urls.filter(\.isFileURL).map { $0.deletingLastPathComponent().standardizedFileURL }
        if localParents.count == urls.count,
           let first = localParents.first,
           localParents.allSatisfy({ $0 == first }),
           !first.lastPathComponent.isEmpty {
            return first.lastPathComponent
        }
        return "Playlist"
    }

    private func sameMediaSource(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.isFileURL, rhs.isFileURL {
            return lhs.standardizedFileURL == rhs.standardizedFileURL
        }
        return lhs.absoluteString == rhs.absoluteString
    }

    func moveQueueItem(id: UUID, before destinationID: UUID) {
        guard id != destinationID,
              let sourceIndex = queue.firstIndex(where: { $0.id == id }),
              let originalDestination = queue.first(where: { $0.id == destinationID }) else { return }

        let source = queue[sourceIndex]
        if source.groupID != originalDestination.groupID {
            if source.groupKind == .standalone, originalDestination.groupKind == .standalone {
                moveQueueGroup(id: source.groupID, before: originalDestination.groupID)
            }
            return
        }

        let item = queue.remove(at: sourceIndex)
        guard let destinationIndex = queue.firstIndex(where: { $0.id == destinationID }) else {
            queue.insert(item, at: min(sourceIndex, queue.count))
            return
        }
        queue.insert(item, at: destinationIndex)
        persistQueueState()
    }

    func moveQueueGroup(id: UUID, before destinationID: UUID) {
        guard id != destinationID,
              queue.contains(where: { $0.groupID == id }),
              queue.contains(where: { $0.groupID == destinationID }) else { return }

        let movingItems = queue.filter { $0.groupID == id }
        queue.removeAll { $0.groupID == id }
        guard let destinationIndex = queue.firstIndex(where: { $0.groupID == destinationID }) else {
            queue.append(contentsOf: movingItems)
            return
        }
        queue.insert(contentsOf: movingItems, at: destinationIndex)
        persistQueueState()
    }

    func toggleQueueGroup(_ id: UUID) {
        if expandedQueueGroupIDs.contains(id) {
            expandedQueueGroupIDs.remove(id)
        } else {
            expandedQueueGroupIDs.insert(id)
        }
        persistQueueState()
    }

    func remove(_ item: MediaItem) {
        guard let queuedItem = queue.first(where: { $0.id == item.id }) else { return }
        removeItems([queuedItem], removingGroup: false)
    }

    func removeQueueGroup(_ groupID: UUID) {
        removeItems(queue.filter { $0.groupID == groupID }, removingGroup: true)
    }

    private func removeItems(_ items: [MediaItem], removingGroup: Bool) {
        guard let firstItem = items.first,
              let firstIndex = queue.firstIndex(where: { $0.id == firstItem.id }) else { return }

        let selectedIDs = Set(items.map(\.id))
        var targetByID: [UUID: URL] = [:]
        var extraTargets: Set<URL> = []
        var invalidIDs: Set<UUID> = []
        var issues: [String] = []
        var torrentDirectories: [URL: URL] = [:]

        for item in items {
            if MediaSupport.isTorrentSource(item.url) {
                let directory: URL
                if let cached = torrentDirectories[item.url] {
                    directory = cached
                } else if let resolved = TorrentStorage.downloadDirectory(
                    for: item.url, under: magnetStream.downloadDirectory
                ) {
                    torrentDirectories[item.url] = resolved
                    directory = resolved
                } else {
                    invalidIDs.insert(item.id)
                    issues.append("Could not locate downloads for \(item.title).")
                    continue
                }

                let removesLastItem = !queue.contains {
                    $0.groupID == item.groupID && !selectedIDs.contains($0.id)
                }
                if removingGroup || removesLastItem {
                    targetByID[item.id] = directory
                    extraTargets.insert(magnetStream.downloadDirectory
                        .appendingPathComponent(".metadata", isDirectory: true)
                        .appendingPathComponent("\(directory.lastPathComponent).torrent"))
                    extraTargets.insert(TorrentStorage.progressURL(
                        forInfoHash: directory.lastPathComponent, under: magnetStream.downloadDirectory
                    ))
                    if item.url.isFileURL {
                        extraTargets.insert(item.url.standardizedFileURL)
                    }
                } else if let file = item.torrentFile,
                          let fileURL = TorrentStorage.downloadedFileURL(for: file, in: directory) {
                    targetByID[item.id] = fileURL
                } else {
                    invalidIDs.insert(item.id)
                    issues.append("Could not locate downloaded file \(item.title).")
                }
            } else if item.url.isFileURL {
                targetByID[item.id] = item.url.standardizedFileURL
            }
        }

        let stoppedCurrentTorrent = currentItem.map { current in
            MediaSupport.isTorrentSource(current.url) && torrentDirectories[current.url] != nil
        } ?? false
        if stoppedCurrentTorrent {
            rememberCurrentProgress(saveImmediately: true)
            engine.stop()
            magnetStream.stopAndWait()
            isPlaying = false
            isLoading = false
        }

        var failedTargets: Set<URL> = []
        for url in Set(targetByID.values).union(extraTargets).sorted(by: { $0.path < $1.path }) {
            do {
                try moveFileToTrash(url)
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain,
                   [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
                    continue
                }
                failedTargets.insert(url)
                issues.append("Could not move \(url.lastPathComponent) to Trash: \(error.localizedDescription)")
            }
        }
        let removed = items.filter { item in
            !invalidIDs.contains(item.id) &&
                (targetByID[item.id].map { !failedTargets.contains($0) } ?? true)
        }
        let removedIDs = Set(removed.map(\.id))
        let wasCurrent = currentID.map(removedIDs.contains) ?? false
        if wasCurrent && !stoppedCurrentTorrent {
            rememberCurrentProgress(saveImmediately: true)
        }
        queue.removeAll { removedIDs.contains($0.id) }
        expandedQueueGroupIDs.formIntersection(Set(queue.map(\.groupID)))
        for item in removed where targetByID[item.id] != nil {
            let key = persistenceKey(for: item)
            rememberedPositions.removeValue(forKey: key)
            rememberedMarkers.removeValue(forKey: key)
        }
        persistStores()
        persistQueueState()

        if wasCurrent {
            if queue.isEmpty {
                clearCurrentPlayback()
            } else {
                play(queue[min(firstIndex, queue.count - 1)])
            }
        } else if stoppedCurrentTorrent, let currentItem {
            play(currentItem)
        }
        if let firstIssue = issues.first {
            let more = issues.count > 1 ? " (and \(issues.count - 1) more)" : ""
            errorMessage = firstIssue + more
        }
    }

    func clearQueue() {
        rememberCurrentProgress(saveImmediately: true)
        queue.removeAll()
        expandedQueueGroupIDs.removeAll()
        clearCurrentPlayback()
        persistQueueState()
    }

}
