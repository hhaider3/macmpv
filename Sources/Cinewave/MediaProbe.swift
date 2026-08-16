import Darwin
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

    // MARK: - Public API

    func inspect(_ url: URL) async -> MediaMetadata? {
        guard let ffprobe = Self.ffprobeExecutable else { return nil }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "error",
            "-show_entries",
            "format=format_long_name,duration,size,bit_rate:stream=codec_name,codec_type,width,height,channels,avg_frame_rate,r_frame_rate",
            "-of", "json",
            url.isFileURL ? url.path : url.absoluteString
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // Ensure GUI apps don't inherit a stripped environment.
        process.qualityOfService = .userInitiated

        do {
            try process.run()
        } catch {
            return nil
        }

        // Race the probe against a timeout, draining both pipes concurrently.
        // On timeout we terminate gracefully, then force-kill after a short grace.
        return await withTaskGroup(of: MediaMetadata?.self) { group in
            group.addTask {
                await self.collectResult(process: process, outputPipe: outputPipe, errorPipe: errorPipe)
            }
            group.addTask {
                // 8s for local files, enough for remote / HLS without hanging indefinitely.
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if process.isRunning {
                    process.terminate() // SIGTERM
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s grace
                    if process.isRunning {
                        // SIGKILL as last resort; Process has no direct kill, use Darwin.
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
                return nil
            }

            // First completed wins; cancel the other branch.
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: - Executable search

    /// Resolved once per process: the PATH layout, Homebrew/Nix locations, and
    /// user overrides do not change between probes while the app runs, so
    /// re-walking them per item is pure waste.
    private static let ffprobeExecutable: URL? = MediaProbe.resolveFFProbeExecutable()

    // Bundled > user-configurable > PATH > hardcoded fallbacks.
    // Finder-launched apps get a minimal PATH, so hardcoded fallbacks are always checked.
    private static func resolveFFProbeExecutable() -> URL? {
        let fm = FileManager.default

        // 1. Bundled with app (e.g. Contents/MacOS/ffprobe or Resources/ffprobe)
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffprobe"),
           fm.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        if let resDir = Bundle.main.resourceURL?.appendingPathComponent("ffprobe"),
           fm.isExecutableFile(atPath: resDir.path) {
            return resDir
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ffprobe"),
           fm.isExecutableFile(atPath: execDir.path) {
            return execDir
        }

        // 2. User-configurable (UserDefaults or environment)
        // Environment checked first so launchctl / shell overrides win.
        let customCandidates: [String?] = [
            ProcessInfo.processInfo.environment["MACMPV_FFPROBE"],
            ProcessInfo.processInfo.environment["FFPROBE_PATH"],
            UserDefaults.standard.string(forKey: "ffprobe.path"),
            UserDefaults.standard.string(forKey: "MACMPV_FFPROBE"),
        ]
        for raw in customCandidates.compactMap({ $0 }).map({ ($0 as NSString).expandingTildeInPath }) {
            if fm.isExecutableFile(atPath: raw) {
                return URL(fileURLWithPath: raw)
            }
        }

        // 3. PATH — split on `:` and test each directory. Finder may give minimal PATH,
        // so we still fall through to hardcoded list below.
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":").map(String.init) where !dir.isEmpty {
                let candidate = (dir as NSString).appendingPathComponent("ffprobe")
                if fm.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }

        // 4. Hardcoded fallbacks: Homebrew (arm + intel), MacPorts, Nix, system
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let hardcoded = [
            "/opt/homebrew/bin/ffprobe",                // Homebrew arm
            "/usr/local/bin/ffprobe",                   // Homebrew Intel / manual
            "/opt/local/bin/ffprobe",                   // MacPorts
            "/usr/bin/ffprobe",                         // system
            "/run/current-system/sw/bin/ffprobe",       // NixOS
            "/nix/var/nix/profiles/default/bin/ffprobe",// Nix
            "\(home)/.nix-profile/bin/ffprobe",         // Nix single-user
            "/opt/nix/bin/ffprobe",
        ]
        for candidate in hardcoded where fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        return nil
    }

    // MARK: - Collection helpers

    private func collectResult(process: Process, outputPipe: Pipe, errorPipe: Pipe) async -> MediaMetadata? {
        // Drain stdout and stderr concurrently so neither pipe fills and deadlocks.
        // readToEnd() is async and suspends the actor without blocking the cooperative thread.
        async let stdoutDataTask: Data = {
            do {
                return try await outputPipe.fileHandleForReading.readToEnd() ?? Data()
            } catch {
                return Data()
            }
        }()

        async let stderrDrainTask: Data = {
            do {
                return try await errorPipe.fileHandleForReading.readToEnd() ?? Data()
            } catch {
                return Data()
            }
        }()

        async let exitStatusTask: Int32 = {
            await self.waitForExit(process)
        }()

        let (stdoutData, _, exitStatus) = await (stdoutDataTask, stderrDrainTask, exitStatusTask)

        guard exitStatus == 0 else { return nil }
        guard !stdoutData.isEmpty else { return nil }
        do {
            let probe = try JSONDecoder().decode(ProbeOutput.self, from: stdoutData)
            return Self.metadata(from: probe)
        } catch {
            return nil
        }
    }

    private func waitForExit(_ process: Process) async -> Int32 {
        return await withCheckedContinuation { continuation in
            // waitUntilExit has one completion path, avoiding the race between an
            // isRunning check and a concurrently invoked termination handler.
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
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
