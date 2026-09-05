import Foundation

extension PlayerModel {
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
        guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
        let wasCurrent = item.id == currentID
        if wasCurrent {
            rememberCurrentProgress(saveImmediately: true)
        }
        queue.remove(at: index)
        if !queue.contains(where: { $0.groupID == item.groupID }) {
            expandedQueueGroupIDs.remove(item.groupID)
        }
        persistQueueState()
        guard wasCurrent else { return }

        if queue.isEmpty {
            clearCurrentPlayback()
        } else {
            play(queue[min(index, queue.count - 1)])
        }
    }

    func removeQueueGroup(_ groupID: UUID) {
        guard let firstIndex = queue.firstIndex(where: { $0.groupID == groupID }) else { return }
        let wasCurrent = currentItem?.groupID == groupID
        if wasCurrent {
            rememberCurrentProgress(saveImmediately: true)
        }
        queue.removeAll { $0.groupID == groupID }
        expandedQueueGroupIDs.remove(groupID)
        persistQueueState()

        guard wasCurrent else { return }
        if queue.isEmpty {
            clearCurrentPlayback()
        } else {
            play(queue[min(firstIndex, queue.count - 1)])
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
