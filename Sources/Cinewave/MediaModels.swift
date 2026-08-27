import Foundation

enum MediaGroupKind: String, Codable, Hashable, Sendable {
    case standalone
    case playlist
    case torrent
}

struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let url: URL
    /// Stable identity shared by every item opened as one playlist or torrent.
    /// Standalone media receives its own one-item group as well, which keeps
    /// queue ordering and persistence consistent across all source types.
    let groupID: UUID
    let groupTitle: String?
    let groupKind: MediaGroupKind
    /// The file inside a multi-file torrent represented by this queue entry.
    /// `nil` means the torrent has not resolved its file table yet.
    let torrentFile: TorrentFile?
    var metadata: MediaMetadata?
    /// True once an ffprobe attempt finished without metadata (missing ffprobe,
    /// timeout, unreadable stream). Lets the UI distinguish "failed" from
    /// "still probing" instead of spinning forever.
    var probeFailed = false

    init(
        id: UUID = UUID(),
        url: URL,
        torrentFile: TorrentFile? = nil,
        groupID: UUID = UUID(),
        groupTitle: String? = nil,
        groupKind: MediaGroupKind = .standalone
    ) {
        self.id = id
        self.url = url
        self.torrentFile = torrentFile
        self.groupID = groupID
        self.groupTitle = groupTitle
        self.groupKind = groupKind
        self.metadata = nil
    }

    var title: String {
        if let torrentFile {
            return torrentFile.name
        }
        if !url.isFileURL,
           url.scheme?.lowercased() == "magnet",
           let displayName = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name.lowercased() == "dn" })?.value,
           !displayName.isEmpty {
            return displayName
        }
        let name = url.deletingPathExtension().lastPathComponent
        if !name.isEmpty { return name }
        return url.lastPathComponent.isEmpty ? "Magnet Stream" : url.lastPathComponent
    }

    var fileExtension: String {
        if let torrentFile {
            return (torrentFile.path as NSString).pathExtension.uppercased()
        }
        return url.pathExtension.uppercased()
    }
}

struct MediaQueueGroup: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let kind: MediaGroupKind
    var items: [MediaItem]

    var isCollapsible: Bool {
        kind != .standalone || items.count > 1
    }
}

struct TorrentFile: Codable, Hashable, Sendable {
    /// Original position in WebTorrent's `torrent.files` array. This must not be
    /// renumbered after filtering because it is passed back to CLI `--select`.
    let index: Int
    let name: String
    let path: String
    let length: Int64

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: length, countStyle: .file)
    }
}

struct MediaMetadata: Hashable, Codable, Sendable {
    var duration: Double?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var videoCodec: String?
    var audioCodec: String?
    var audioChannels: Int?
    var formatName: String?
    var bitRate: Int64?
    var fileSize: Int64?

    var resolution: String? {
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }

    var frameRateLabel: String? {
        guard let frameRate, frameRate > 0 else { return nil }
        let rounded = frameRate.rounded()
        if abs(frameRate - rounded) < 0.01 {
            return "\(Int(rounded)) FPS"
        }
        return String(format: "%.2f FPS", frameRate)
    }
}

enum MediaSupport {
    static let extensions: Set<String> = [
        "3g2", "3gp", "aac", "ac3", "aiff", "alac", "ape", "asf", "avi",
        "av1", "caf", "divx", "dts", "dv", "f4v", "flac", "flv", "m2ts",
        "m3u", "m3u8", "m4a", "m4v", "magnet", "mka", "mkv", "mov", "mp2", "mp3",
        "mp4", "mpeg", "mpg", "mts", "oga", "ogg", "ogm", "ogv", "opus",
        "rm", "rmvb", "torrent", "ts", "vob", "wav", "webm", "wma", "wmv"
    ]

    static func isPlayable(_ url: URL) -> Bool {
        guard url.isFileURL else {
            return ["http", "https", "magnet", "rtmp", "rtsp"].contains(url.scheme?.lowercased() ?? "")
        }
        return extensions.contains(url.pathExtension.lowercased())
    }

    static func isTorrentSource(_ url: URL) -> Bool {
        (url.isFileURL && ["magnet", "torrent"].contains(url.pathExtension.lowercased())) ||
            url.scheme?.lowercased() == "magnet"
    }

    static func isPlaylistSource(_ url: URL) -> Bool {
        url.isFileURL && ["m3u", "m3u8"].contains(url.pathExtension.lowercased())
    }

    static func isPlayableTorrentFile(_ file: TorrentFile) -> Bool {
        let fileExtension = (file.path as NSString).pathExtension.lowercased()
        return !fileExtension.isEmpty &&
            !["magnet", "m3u", "m3u8", "torrent"].contains(fileExtension) &&
            extensions.contains(fileExtension)
    }
}

extension Double {
    var playbackTime: String {
        guard isFinite, self >= 0 else { return "00:00" }
        let total = Int(self.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
