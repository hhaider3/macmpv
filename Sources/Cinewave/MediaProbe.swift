import Foundation

actor MediaProbe {
    private struct ProbeOutput: Decodable {
        let streams: [Stream]?
        let format: Format?
    }

    private struct Stream: Decodable {
        let codecName: String?
        let codecType: String?
        let width: Int?
        let height: Int?
        let channels: Int?
        let averageFrameRate: String?
        let realFrameRate: String?

        enum CodingKeys: String, CodingKey {
            case codecName = "codec_name"
            case codecType = "codec_type"
            case width
            case height
            case channels
            case averageFrameRate = "avg_frame_rate"
            case realFrameRate = "r_frame_rate"
        }
    }

    private struct Format: Decodable {
        let formatLongName: String?
        let duration: String?
        let size: String?
        let bitRate: String?

        enum CodingKeys: String, CodingKey {
            case formatLongName = "format_long_name"
            case duration
            case size
            case bitRate = "bit_rate"
        }
    }

    func inspect(_ url: URL) -> MediaMetadata? {
        guard let ffprobe = Self.ffprobeExecutable else { return nil }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "error",
            "-show_entries",
            "format=format_long_name,duration,size,bit_rate:stream=codec_name,codec_type,width,height,channels,avg_frame_rate,r_frame_rate",
            "-of", "json",
            url.isFileURL ? url.path : url.absoluteString
        ]
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let probe = try JSONDecoder().decode(ProbeOutput.self, from: data)
            return Self.metadata(from: probe)
        } catch {
            return nil
        }
    }

    private static var ffprobeExecutable: URL? {
        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
        return candidates
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    private static func metadata(from output: ProbeOutput) -> MediaMetadata {
        let video = output.streams?.first(where: { $0.codecType == "video" })
        let audio = output.streams?.first(where: { $0.codecType == "audio" })
        let frameRate = parseFrameRate(video?.averageFrameRate ?? video?.realFrameRate)

        return MediaMetadata(
            duration: output.format?.duration.flatMap(Double.init),
            width: video?.width,
            height: video?.height,
            frameRate: frameRate,
            videoCodec: video?.codecName?.uppercased(),
            audioCodec: audio?.codecName?.uppercased(),
            audioChannels: audio?.channels,
            formatName: output.format?.formatLongName,
            bitRate: output.format?.bitRate.flatMap(Int64.init),
            fileSize: output.format?.size.flatMap(Int64.init)
        )
    }

    private static func parseFrameRate(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        let components = value.split(separator: "/")
        if components.count == 2,
           let numerator = Double(components[0]),
           let denominator = Double(components[1]),
           denominator != 0 {
            return numerator / denominator
        }
        return Double(value)
    }
}
