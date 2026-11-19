import Foundation
import Testing
@testable import macmpv

struct PlaybackTests {
    @Test @MainActor func torrentTitleUsesFilenameAcrossPlaybackUpdatesAndFileSwitches() throws {
        let suite = "macmpv-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerModel(defaults: defaults)
        let source = URL(string: "magnet:?xt=urn:btih:0123456789012345678901234567890123456789")!
        let files = [
            TorrentFile(index: 0, name: "Episode 01 [DD+].mkv", path: "Series/Episode 01 [DD+].mkv", length: 100),
            TorrentFile(index: 7, name: "Episode 02 [日本語].mkv", path: "Series/Episode 02 [日本語].mkv", length: 100)
        ]
        let items = files.map { MediaItem(url: source, torrentFile: $0, groupKind: .torrent) }
        let ordinary = MediaItem(url: URL(fileURLWithPath: "/tmp/movie.mkv"))
        player.queue = items + [ordinary]
        player.bindEngineCallbacks()
        for item in items {
            player.currentID = item.id
            // The title must be right even before the new stream's snapshot,
            // while the engine may still report the previous file's index.
            #expect(player.displayTitle == item.title)
            for title in [nil, "\(item.torrentFile!.index)", "Embedded video title"] as [String?] {
                player.engine.onSnapshot?(.init(position: 0, duration: 60, paused: false, muted: false, volume: 80, speed: 1, eofReached: false, title: title))
                #expect(player.displayTitle == item.title)
            }
        }
        player.currentID = ordinary.id
        player.engineTitle = "Embedded movie title"
        #expect(player.displayTitle == "Embedded movie title")
        player.engineTitle = nil
        #expect(player.displayTitle == ordinary.title)
        player.currentID = nil
        #expect(player.displayTitle == "macmpv")
    }

    @Test @MainActor func resumePositionsMigrateAndKeepOnlyTheMostRecent() throws {
        let suite = "macmpv-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = ["/tmp/old.mkv": 120.0]
        defaults.set(try JSONEncoder().encode(legacy), forKey: PlayerModel.legacyPositionsDefaultsKey)

        let player = PlayerModel(defaults: defaults)
        #expect(player.rememberedPositions["/tmp/old.mkv"]?.seconds == 120)
        #expect(defaults.object(forKey: PlayerModel.legacyPositionsDefaultsKey) == nil)

        let limit = PlayerModel.maximumRememberedPositions
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<(limit + 10) {
            player.rememberedPositions["/tmp/\(index).mkv"] = .init(
                seconds: 60,
                updatedAt: start.addingTimeInterval(Double(index))
            )
        }
        player.persistPositions()

        let reloaded = PlayerModel(defaults: defaults)
        #expect(reloaded.rememberedPositions.count == limit)
        // The migrated entry and the ten oldest dated entries are dropped first.
        #expect(reloaded.rememberedPositions["/tmp/old.mkv"] == nil)
        #expect(reloaded.rememberedPositions["/tmp/9.mkv"] == nil)
        #expect(reloaded.rememberedPositions["/tmp/11.mkv"] != nil)
        #expect(reloaded.rememberedPositions["/tmp/\(limit + 9).mkv"] != nil)
    }

    @Test @MainActor func trackChoicesAreRememberedPerVideoAcrossLaunches() throws {
        let suite = "macmpv-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerModel(defaults: defaults)
        let movie = MediaItem(url: URL(fileURLWithPath: "/tmp/movie.mkv"))
        let series = MediaItem(url: URL(fileURLWithPath: "/tmp/series.mkv"))
        let silent = MediaItem(url: URL(fileURLWithPath: "/tmp/silent.mkv"))
        player.queue = [movie, series, silent]
        let external = MPVEngine.MediaTrack(
            id: "3", kind: .subtitle, title: nil, language: nil, codec: "subrip",
            isSelected: false, externalFilename: "/tmp/subs/../subs/movie.en.srt"
        )
        let embedded = MPVEngine.MediaTrack(
            id: "2", kind: .subtitle, title: "English", language: "eng", codec: "ass", isSelected: false
        )
        let japanese = MPVEngine.MediaTrack(
            id: "2", kind: .audio, title: nil, language: "jpn", codec: "aac", isSelected: false
        )

        player.currentID = movie.id
        player.selectSubtitleTrack(external)
        player.currentID = series.id
        player.selectSubtitleTrack(embedded)
        player.selectAudioTrack(japanese)
        player.currentID = silent.id
        player.selectSubtitleTrack(nil)

        let reloaded = PlayerModel(defaults: defaults)
        let tracks = reloaded.rememberedTracks
        #expect(tracks["/tmp/movie.mkv"]?.subtitle == .external(path: "/tmp/subs/movie.en.srt"))
        #expect(tracks["/tmp/series.mkv"]?.subtitle == .embedded(id: "2"))
        #expect(tracks["/tmp/series.mkv"]?.audioID == "2")
        #expect(tracks["/tmp/silent.mkv"]?.subtitle == .off)
        #expect(tracks["/tmp/silent.mkv"]?.audioID == nil)
    }

    @Test @MainActor func subtitleDelayBelongsToEachVideo() throws {
        let suite = "macmpv-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // An app-wide delay saved by an older version is not applied to every video.
        var legacySettings = PlayerModel.SubtitleSettings()
        legacySettings.delay = 2
        defaults.set(try JSONEncoder().encode(legacySettings), forKey: PlayerModel.subtitleSettingsKey)

        let player = PlayerModel(defaults: defaults)
        #expect(player.subtitleSettings.delay == 0)
        let movie = MediaItem(url: URL(fileURLWithPath: "/tmp/movie.mkv"))
        let other = MediaItem(url: URL(fileURLWithPath: "/tmp/other.mkv"))
        player.queue = [movie, other]

        player.play(movie)
        player.subtitleSettings.delay = 1.5
        player.applySubtitleSettings()
        player.play(other)
        #expect(player.subtitleSettings.delay == 0)
        player.play(movie)
        #expect(player.subtitleSettings.delay == 1.5)

        let reloaded = PlayerModel(defaults: defaults)
        #expect(reloaded.rememberedTracks["/tmp/movie.mkv"]?.subtitleDelay == 1.5)
        #expect(reloaded.rememberedTracks["/tmp/other.mkv"] == nil)
        let saved = try #require(reloaded.load(PlayerModel.SubtitleSettings.self, key: PlayerModel.subtitleSettingsKey))
        #expect(saved.delay == 0)

        // Resetting to zero forgets the video's delay.
        reloaded.queue = [movie]
        reloaded.play(movie)
        reloaded.subtitleSettings.delay = 0
        reloaded.applySubtitleSettings()
        #expect(reloaded.rememberedTracks["/tmp/movie.mkv"] == nil)
    }

    @Test @MainActor func earlierSubtitleFileStoreMigratesOnce() throws {
        let suite = "macmpv-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = ["/tmp/movie.mkv": PlayerModel.LegacyRememberedSubtitle(
            path: "/tmp/movie.srt", updatedAt: Date(timeIntervalSince1970: 1_000)
        )]
        defaults.set(try JSONEncoder().encode(legacy), forKey: PlayerModel.legacySubtitleFilesDefaultsKey)

        _ = PlayerModel(defaults: defaults)
        #expect(defaults.object(forKey: PlayerModel.legacySubtitleFilesDefaultsKey) == nil)
        let reloaded = PlayerModel(defaults: defaults)
        #expect(reloaded.rememberedTracks["/tmp/movie.mkv"]?.subtitle == .external(path: "/tmp/movie.srt"))
    }

    @Test func completionIsConsumedOnceAndRearmedAfterSeek() {
        var completion = PlaybackCompletion()
        var results: [Bool] = []
        results.append(completion.observe(eofReached: true))
        completion.fileLoaded()
        results.append(completion.observe(eofReached: true))
        results.append(completion.observe(eofReached: true))
        results.append(completion.observe(eofReached: false))
        results.append(completion.observe(eofReached: true))
        completion.beginLoad()
        results.append(completion.observe(eofReached: true))
        completion.fileLoaded()
        results.append(completion.observe(eofReached: true))
        #expect(results == [false, true, false, false, true, false, true])
    }

    @Test(arguments: ["off", "all", "one"]) @MainActor
    func eofSnapshotAppliesRepeatModeAndIgnoresStop(mode: String) throws {
        let suite = "macmpv-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerModel(defaults: defaults)
        let first = MediaItem(url: URL(fileURLWithPath: "/tmp/one.mp4"))
        let second = MediaItem(url: URL(fileURLWithPath: "/tmp/two.mp4"))
        player.queue = [first, second]
        player.repeatMode = PlayerModel.RepeatMode(rawValue: mode)!
        let start = mode == "all" ? second : first
        player.play(start)
        player.bindEngineCallbacks()
        player.engine.onEvent?(.endFile(reachedEOF: false, error: nil))
        #expect(player.currentID == start.id)
        player.engine.onEvent?(.fileLoaded)
        let eof = MPVEngine.Snapshot(position: 60, duration: 60, paused: true, muted: false, volume: 80, speed: 1, eofReached: true, title: nil)
        player.engine.onSnapshot?(eof)
        let expected = mode == "off" ? second.id : first.id
        #expect(player.currentID == expected)
        if mode == "one" { #expect(player.position == 0) }
        player.engine.onSnapshot?(eof)
        #expect(player.currentID == expected)
        player.clearQueue()
        #expect(!player.isLoading)
    }

    @Test @MainActor func failedReplacementAlwaysClearsLoading() throws {
        let suite = "macmpv-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerModel(defaults: defaults)
        player.bindEngineCallbacks()
        player.isLoading = true
        player.engine.onEvent?(.endFile(reachedEOF: false, error: "Unreadable file"))
        #expect(!player.isLoading)
        #expect(player.errorMessage == "Playback failed: Unreadable file")
    }

    @Test @MainActor func queueRoundTripPreservesGroupsOrderAndMetadata() throws {
        let suite = "macmpv-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerModel(defaults: defaults)
        let group = UUID()
        var first = MediaItem(url: URL(string: "https://example.com/one.mp4")!, groupID: group, groupTitle: "Episodes", groupKind: .playlist)
        var second = MediaItem(url: URL(string: "https://example.com/two.mp4")!, groupID: group, groupTitle: "Episodes", groupKind: .playlist)
        first.metadata = MediaMetadata(duration: 60)
        second.metadata = MediaMetadata(duration: 120)
        player.queue = [first, second]
        player.expandedQueueGroupIDs.insert(group)
        player.isSidebarVisible = true
        player.moveQueueItem(id: second.id, before: first.id)
        let restored = PlayerModel(defaults: defaults)
        #expect(restored.queue.map(\.id) == [second.id, first.id])
        #expect(restored.queueGroups.count == 1)
        #expect(restored.queueGroups.first?.title == "Episodes")
        #expect(restored.currentID == nil)
        #expect(restored.isSidebarVisible)
        #expect(restored.expandedQueueGroupIDs == [group])
        #expect(restored.queue.first?.metadata?.duration == 120)
        restored.clearQueue()
        #expect(PlayerModel(defaults: defaults).queue.isEmpty)
    }

    @Test @MainActor func restorationRemovesMissingFilesAndStaleGroups() throws {
        let suite = "macmpv-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerModel(defaults: defaults)
        let item = MediaItem(url: URL(fileURLWithPath: "/tmp/\(UUID()).mp4"))
        player.queue = [item]
        player.expandedQueueGroupIDs = [item.groupID]
        player.isSidebarVisible = true
        let restored = PlayerModel(defaults: defaults)
        #expect(restored.queue.isEmpty)
        #expect(restored.expandedQueueGroupIDs.isEmpty)
        #expect(!restored.isSidebarVisible)
    }
}
