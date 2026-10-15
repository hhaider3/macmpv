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
        #expect(!FileManager.default.fileExists(atPath: source.path))
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
