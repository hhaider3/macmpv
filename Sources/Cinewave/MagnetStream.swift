import Foundation

@MainActor
final class MagnetStream {
    enum StreamError: LocalizedError {
        case invalidFile
        case helperUnavailable
        case helperFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                "The file is not a valid BitTorrent .magnet or .torrent source."
            case .helperUnavailable:
                "Torrent playback requires WebTorrent CLI. Install it with “npm install -g webtorrent-cli”."
            case .helperFailed(let detail):
                detail.isEmpty ? "WebTorrent could not start this magnet stream." : "WebTorrent failed: \(detail)"
            case .timedOut:
                "The torrent stream timed out while waiting for metadata or peers."
            }
        }
    }

    private var process: Process?
    private var streamWaitTask: Task<Void, Never>?
    private var temporaryDirectory: URL?

    func start(
        from source: URL,
        completion: @escaping @MainActor (Result<URL, StreamError>) -> Void
    ) {
        stop()

        let torrentIdentifier: String
        do {
            torrentIdentifier = try Self.torrentIdentifier(from: source)
        } catch {
            completion(.failure(.invalidFile))
            return
        }

        guard let executable = Self.webtorrentExecutable else {
            completion(.failure(.helperUnavailable))
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmpv-magnet-\(UUID().uuidString)", isDirectory: true)
        let captureURL = directory.appendingPathComponent("stream-url")
        let shimURL = directory.appendingPathComponent("mpv")
        let logURL = directory.appendingPathComponent("webtorrent.log")
        let loaderURL = directory.appendingPathComponent("webtorrent-loader.mjs")
        let bootstrapURL = directory.appendingPathComponent("webtorrent-bootstrap.mjs")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.writeCaptureShim(to: shimURL)
            try Self.writeCompatibilityLoader(to: loaderURL, bootstrapURL: bootstrapURL)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        } catch {
            completion(.failure(.helperFailed(error.localizedDescription)))
            return
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            torrentIdentifier,
            "--mpv",
            "--not-on-top",
            "--no-quit",
            "--quiet"
        ]
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        let helperDirectory = executable.deletingLastPathComponent().path
        environment["PATH"] = [
            directory.path,
            helperDirectory,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            existingPath
        ].joined(separator: ":")
        environment["MACMPV_MAGNET_URL_FILE"] = captureURL.path
        let compatibilityOption = "--import=\(bootstrapURL.absoluteString)"
        if let nodeOptions = environment["NODE_OPTIONS"], !nodeOptions.isEmpty {
            environment["NODE_OPTIONS"] = "\(nodeOptions) \(compatibilityOption)"
        } else {
            environment["NODE_OPTIONS"] = compatibilityOption
        }
        process.environment = environment
        let logHandle = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        // WebTorrent prints some fatal errors with console.log, so capture stdout and
        // stderr together instead of reducing every failure to an unexplained status 1.
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.qualityOfService = .userInitiated

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            completion(.failure(.helperFailed(error.localizedDescription)))
            return
        }

        self.process = process
        temporaryDirectory = directory
        streamWaitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + .seconds(90)

            while !Task.isCancelled, ContinuousClock.now < deadline {
                if let data = try? Data(contentsOf: captureURL),
                   let rawValue = String(data: data, encoding: .utf8),
                   let streamURL = URL(
                    dataRepresentation: Data(
                        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).utf8
                    ),
                    relativeTo: nil
                   ),
                   streamURL.scheme == "http" || streamURL.scheme == "https" {
                    streamWaitTask = nil
                    completion(.success(streamURL))
                    return
                }

                if !process.isRunning {
                    let detail = process.terminationStatus == 0
                        ? "The torrent did not expose a playable media file."
                        : "The helper exited with status \(process.terminationStatus)."
                    let message = Self.appendingLogTail(detail, logURL: logURL)
                    self.stop()
                    completion(.failure(.helperFailed(message)))
                    return
                }

                try? await Task.sleep(for: .milliseconds(150))
            }

            guard !Task.isCancelled else { return }
            self.stop()
            completion(.failure(.timedOut))
        }
    }

    func stop() {
        streamWaitTask?.cancel()
        streamWaitTask = nil

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil

        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    private static func torrentIdentifier(from source: URL) throws -> String {
        if source.isFileURL, source.pathExtension.lowercased() == "torrent" {
            let resourceValues = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard resourceValues.isRegularFile == true,
                  let fileSize = resourceValues.fileSize,
                  fileSize > 0,
                  fileSize <= 20 * 1_048_576 else {
                throw StreamError.invalidFile
            }
            return source.path
        }

        let rawValue: String
        if source.isFileURL {
            let resourceValues = try source.resourceValues(forKeys: [.fileSizeKey])
            guard (resourceValues.fileSize ?? 0) <= 1_048_576 else { throw StreamError.invalidFile }
            rawValue = try String(contentsOf: source, encoding: .utf8)
        } else {
            rawValue = source.absoluteString
        }

        guard let start = rawValue.range(of: "magnet:?", options: .caseInsensitive) else {
            throw StreamError.invalidFile
        }
        let remainder = rawValue[start.lowerBound...]
        let candidate = remainder
            .prefix { !$0.isWhitespace && $0 != "\"" && $0 != "'" && $0 != "<" && $0 != ">" }
        let magnet = String(candidate)
        guard let components = URLComponents(string: magnet),
              components.scheme?.lowercased() == "magnet",
              components.queryItems?.contains(where: {
                  $0.name.lowercased() == "xt" &&
                  ($0.value?.lowercased().hasPrefix("urn:btih:") == true ||
                   $0.value?.lowercased().hasPrefix("urn:btmh:") == true)
              }) == true else {
            throw StreamError.invalidFile
        }
        return magnet
    }

    private static func writeCaptureShim(to url: URL) throws {
        // webtorrent-cli launches its mpv player via `sh -c`, passing the resolved
        // stream URL as one of the arguments. Detect it by scheme rather than relying
        // on it being the final argument, so ordering or extra flags can't break it.
        let script = """
        #!/bin/sh
        destination=${MACMPV_MAGNET_URL_FILE:?}
        stream_url=
        for argument do
            case "$argument" in
                http://*|https://*)
                    stream_url=$argument
                    ;;
            esac
        done
        if [ -n "$stream_url" ]; then
            printf '%s' "$stream_url" > "$destination"
        fi
        """
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func writeCompatibilityLoader(to loaderURL: URL, bootstrapURL: URL) throws {
        // WebTorrent CLI 6 currently resolves WebTorrent 2.x alongside uint8-util
        // 2.3.x. That combination passes a hex string to an API which now requires a
        // byte array and exits with status 1 for every magnet. Patch only the two
        // affected debug-label calls while loading WebTorrent; newer versions do not
        // contain this expression and pass through unchanged.
        let loader = """
        export async function load(url, context, nextLoad) {
          const result = await nextLoad(url, context)
          if (!url.endsWith('/webtorrent/lib/torrent.js') || typeof result.source === 'undefined') {
            return result
          }
          const source = Buffer.isBuffer(result.source)
            ? result.source.toString('utf8')
            : String(result.source)
          return {
            ...result,
            source: source.replaceAll(
              'arr2hex(parsedTorrent.infoHash)',
              'arr2hex(parsedTorrent.infoHashBuffer)'
            )
          }
        }
        """

        let bootstrap = """
        import * as Module from 'node:module'

        function patch(result, url) {
          if (!url.endsWith('/webtorrent/lib/torrent.js') || typeof result.source === 'undefined') {
            return result
          }
          const source = Buffer.isBuffer(result.source)
            ? result.source.toString('utf8')
            : String(result.source)
          return {
            ...result,
            source: source.replaceAll(
              'arr2hex(parsedTorrent.infoHash)',
              'arr2hex(parsedTorrent.infoHashBuffer)'
            )
          }
        }

        if (typeof Module.registerHooks === 'function') {
          Module.registerHooks({
            load(url, context, nextLoad) {
              return patch(nextLoad(url, context), url)
            }
          })
        } else {
          Module.register(new URL('./webtorrent-loader.mjs', import.meta.url))
        }
        """

        try Data(loader.utf8).write(to: loaderURL, options: .atomic)
        try Data(bootstrap.utf8).write(to: bootstrapURL, options: .atomic)
    }

    private static func appendingLogTail(_ message: String, logURL: URL) -> String {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else { return message }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return message }
        let tail = trimmed.count > 400 ? String(trimmed.suffix(400)) : trimmed
        return "\(message)\n\(tail)"
    }

    private static var webtorrentExecutable: URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []

        if let customPath = environment["MACMPV_WEBTORRENT"], !customPath.isEmpty {
            candidates.append((customPath as NSString).expandingTildeInPath)
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                (String($0) as NSString).appendingPathComponent("webtorrent")
            })
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/webtorrent",
            "/usr/local/bin/webtorrent",
            "/opt/local/bin/webtorrent"
        ])

        return candidates.first(where: fileManager.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }
}
