import Foundation

struct MediaItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    var metadata: MediaMetadata?
    /// True once an ffprobe attempt finished without metadata (missing ffprobe,
    /// timeout, unreadable stream). Lets the UI distinguish "failed" from
    /// "still probing" instead of spinning forever.
    var probeFailed = false

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.metadata = nil
    }

    var title: String {
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
        url.pathExtension.uppercased()
    }
}

struct MediaMetadata: Hashable, Sendable {
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
