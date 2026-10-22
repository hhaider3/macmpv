import CryptoKit
import Foundation
import Testing
@testable import macmpv

struct QueueRemovalTests {
    @Test @MainActor func removingLocalFileMovesItToTrash() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appendingPathComponent("movie.mp4")
        try Data("movie".utf8).write(to: file)
        let item = MediaItem(url: file)
        let player = PlayerModel(defaults: fixture.defaults)
        player.moveFileToTrash = fixture.moveToTrash
        player.queue = [item]
        #expect(player.finderURL(for: item) == file)

        player.remove(item)

        #expect(player.queue.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("movie.mp4").path))
    }

    @Test @MainActor func missingFileAndRemoteStreamCanLeaveTheQueue() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let missing = MediaItem(url: fixture.root.appendingPathComponent("missing.mp4"))
        let remote = MediaItem(url: URL(string: "https://example.com/stream.mp4")!)
        let player = PlayerModel(defaults: fixture.defaults)
        player.moveFileToTrash = fixture.moveToTrash
        player.queue = [missing, remote]

        player.remove(missing)
        player.remove(remote)

        #expect(player.queue.isEmpty)
        #expect(player.errorMessage == nil)
    }

    @Test @MainActor func removingCollectionTrashesFilesAndKeepsFailuresQueued() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = fixture.root.appendingPathComponent("first.mp4")
        let blocked = fixture.root.appendingPathComponent("blocked.mp4")
        try Data().write(to: first)
        try Data().write(to: blocked)
        let groupID = UUID()
        let firstItem = MediaItem(url: first, groupID: groupID, groupKind: .playlist)
        let blockedItem = MediaItem(url: blocked, groupID: groupID, groupKind: .playlist)
        let player = PlayerModel(defaults: fixture.defaults)
        player.moveFileToTrash = { url in
            if url == blocked { throw CocoaError(.fileWriteNoPermission) }
            try fixture.moveToTrash(url)
        }
        player.queue = [firstItem, blockedItem]

        player.removeQueueGroup(groupID)

        #expect(player.queue.map(\.id) == [blockedItem.id])
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: blocked.path))
        #expect(player.errorMessage?.contains("blocked.mp4") == true)
    }

    @Test @MainActor func removingTorrentFileThenCollectionTrashesDownloadsAndSource() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let info = Data("d6:lengthi4e4:name9:video.mp4e".utf8)
        var torrent = Data("d4:info".utf8)
        torrent.append(info)
        torrent.append(Data("e".utf8))
        let source = fixture.root.appendingPathComponent("source.torrent")
        try torrent.write(to: source)
        let hash = Insecure.SHA1.hash(data: info).map { String(format: "%02x", $0) }.joined()
        #expect(TorrentStorage.infoHash(for: source) == hash)

        let downloads = fixture.root.appendingPathComponent("downloads")
        let collection = downloads.appendingPathComponent(hash)
        let series = collection.appendingPathComponent("Series")
        let metadata = downloads.appendingPathComponent(".metadata")
            .appendingPathComponent("\(hash).torrent")
        try FileManager.default.createDirectory(at: series, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = series.appendingPathComponent("one.mp4")
        let second = series.appendingPathComponent("two.mp4")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        try torrent.write(to: metadata)
        let progress = TorrentStorage.progressURL(forInfoHash: hash, under: downloads)
        try Data(#"{"files":{}}"#.utf8).write(to: progress)

        let groupID = UUID()
        let firstItem = MediaItem(url: source,
            torrentFile: TorrentFile(index: 0, name: "one.mp4", path: "Series/one.mp4", length: 3),
            groupID: groupID, groupKind: .torrent)
        let secondItem = MediaItem(url: source,
            torrentFile: TorrentFile(index: 1, name: "two.mp4", path: "Series/two.mp4", length: 3),
            groupID: groupID, groupKind: .torrent)
        let player = PlayerModel(defaults: fixture.defaults,
            magnetStream: MagnetStream(downloadDirectory: downloads))
        player.moveFileToTrash = fixture.moveToTrash
        player.queue = [firstItem, secondItem]
        #expect(player.finderURL(for: firstItem) == first)

        player.remove(firstItem)
        #expect(player.queue.map(\.id) == [secondItem.id])
        #expect(player.finderURL(for: firstItem) == nil)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: source.path))

        player.removeQueueGroup(groupID)
        #expect(player.queue.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: collection.path))
        #expect(!FileManager.default.fileExists(atPath: metadata.path))
        #expect(!FileManager.default.fileExists(atPath: progress.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test @MainActor func torrentRowsShowSavedProgressOrLocal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let hash = String(repeating: "ab", count: 20)
        let source = URL(string: "magnet:?xt=urn:btih:\(hash)")!
        let downloads = fixture.root.appendingPathComponent("downloads")
        let collection = downloads.appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
        let progress = TorrentStorage.progressURL(forInfoHash: hash, under: downloads)
        try FileManager.default.createDirectory(at: progress.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"""
        {"files":{"0":{"downloaded":400,"done":true},"1":{"downloaded":250,"done":false},"2":{"downloaded":1000,"done":false},"3":{"downloaded":1000,"done":true}}}
        """#.utf8).write(to: progress)
        for index in 0..<3 {
            try Data().write(to: collection.appendingPathComponent("\(index).mp4"))
        }

        let items = (0..<5).map { index in
            MediaItem(url: source,
                torrentFile: TorrentFile(index: index, name: "\(index).mp4", path: "\(index).mp4", length: 1000),
                groupKind: .torrent)
        }
        let player = PlayerModel(defaults: fixture.defaults,
            magnetStream: MagnetStream(downloadDirectory: downloads))
        player.queue = items
        await player.refreshTorrentProgress()

        #expect(player.torrentDownloadState(for: items[0]) == .local)
        #expect(player.torrentDownloadState(for: items[1]) == .downloading(percent: 25))
        // Every byte arrived but the last piece is not verified yet.
        #expect(player.torrentDownloadState(for: items[2]) == .downloading(percent: 99))
        // Saved as done, then removed from disk.
        #expect(player.torrentDownloadState(for: items[3]) == nil)
        #expect(player.torrentDownloadState(for: items[4]) == nil)
        #expect(player.torrentDownloadState(for: MediaItem(url: source)) == nil)
        // Only helper-verified files skip the helper and play from disk.
        #expect(player.verifiedDownloadURL(for: items[0]) == collection.appendingPathComponent("0.mp4"))
        #expect(player.verifiedDownloadURL(for: items[1]) == nil)
        #expect(player.verifiedDownloadURL(for: items[3]) == nil)
    }

    @Test @MainActor func torrentDownloadsWithoutSavedProgressAreReadFromDisk() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let hash = String(repeating: "cd", count: 20)
        let source = URL(string: "magnet:?xt=urn:btih:\(hash)")!
        let downloads = fixture.root.appendingPathComponent("downloads")
        let collection = downloads.appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
        let length: Int64 = 64 * 1_048_576
        try Data(count: Int(length)).write(to: collection.appendingPathComponent("complete.mp4"))
        // A partial download: full logical size, but only its last block written.
        // APFS leaves a hole only for gaps of 16 MB or more.
        let partialURL = collection.appendingPathComponent("partial.mp4")
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partialURL)
        try handle.seek(toOffset: UInt64(length - 1))
        try handle.write(contentsOf: Data([1]))
        try handle.close()

        let complete = MediaItem(url: source,
            torrentFile: TorrentFile(index: 0, name: "complete.mp4", path: "complete.mp4", length: length),
            groupKind: .torrent)
        let partial = MediaItem(url: source,
            torrentFile: TorrentFile(index: 1, name: "partial.mp4", path: "partial.mp4", length: length),
            groupKind: .torrent)
        let player = PlayerModel(defaults: fixture.defaults,
            magnetStream: MagnetStream(downloadDirectory: downloads))
        player.queue = [complete, partial]
        await player.refreshTorrentProgress()

        #expect(player.torrentDownloadState(for: complete) == .local)
        #expect(player.torrentDownloadState(for: partial) == .downloading(percent: 0))
        // Disk usage is an estimate; playback still waits for verification.
        #expect(player.verifiedDownloadURL(for: complete) == nil)
    }

    @Test func torrentFileCannotEscapeDownloadDirectory() {
        let directory = URL(fileURLWithPath: "/tmp/downloads")
        let file = TorrentFile(index: 0, name: "outside.mp4", path: "../outside.mp4", length: 1)
        #expect(TorrentStorage.downloadedFileURL(for: file, in: directory) == nil)
    }
}

private final class Fixture {
    let root: URL
    let trash: URL
    let defaults: UserDefaults
    private let suite: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("macmpv-removal-\(UUID())")
        trash = root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        suite = "macmpv-removal-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }

    func moveToTrash(_ url: URL) throws {
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
