import Foundation

struct MediaItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    var metadata: MediaMetadata?

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.metadata = nil
    }

    var title: String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? url.lastPathComponent : name
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
        "m3u", "m3u8", "m4a", "m4v", "mka", "mkv", "mov", "mp2", "mp3",
        "mp4", "mpeg", "mpg", "mts", "oga", "ogg", "ogm", "ogv", "opus",
        "rm", "rmvb", "ts", "vob", "wav", "webm", "wma", "wmv"
    ]

    static func isPlayable(_ url: URL) -> Bool {
        guard url.isFileURL else {
            return ["http", "https", "rtmp", "rtsp"].contains(url.scheme?.lowercased() ?? "")
        }
        return extensions.contains(url.pathExtension.lowercased())
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
