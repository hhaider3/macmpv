import Foundation

// Session scripts and metadata probes live in temp; playback data never does.
// A new prefix keeps cleanup away from any legacy video download directories.
private let torrentSessionDirectoryPrefix = "macmpv-torrent-session-"

// Nonisolated async functions run on the global concurrent executor (SE-0338),
// which keeps the 150 ms capture-file poll and log reads off the main actor.
private func readFileData(at url: URL) async -> Data? {
    try? Data(contentsOf: url)
}

private struct TorrentManifest: Decodable {
    let files: [TorrentFile]
}

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

    private(set) var process: Process?
    private var requestID = UUID()
    private let helperOverride: Helper?
    private let readFile: @Sendable (URL) async -> Data?
    private var streamWaitTask: Task<Void, Never>?
    private var temporaryDirectory: URL?
    private var activeIdentifier: String?
    let downloadDirectory: URL

    private struct Selection: Encodable {
        let requestID: UUID
        let index: Int?
    }

    private struct StreamResponse: Decodable {
        let requestID: UUID
        let url: URL
    }

    init(
        helper: Helper? = nil,
        downloadDirectory: URL? = nil,
        readFile: @escaping @Sendable (URL) async -> Data? = readFileData
    ) {
        self.helperOverride = helper
        self.downloadDirectory = downloadDirectory ?? FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macmpv/Torrents", isDirectory: true)
        self.readFile = readFile
        // Remove abandoned session scripts after a crash. Durable downloads live
        // under Movies and are never included in this sweep.
        // The sweep races this run's first stream (it is asynchronous) and may run
        // alongside other macmpv instances, so a directory is removed only when it
        // provably belongs to a dead process — never merely because it matches.
        Task.detached(priority: .utility) {
            Self.removeStaleDownloadDirectories()
        }
    }

    /// Resolves a torrent's metadata without downloading its payload. The small
    /// Node helper emits a stable JSON file instead of relying on WebTorrent CLI's
    /// human-oriented `--select` listing output.
    func resolveFiles(
        from source: URL,
        completion: @escaping @MainActor (Result<[TorrentFile], StreamError>) -> Void
    ) {
        stop()

        let torrentIdentifier: String
        do {
            torrentIdentifier = try Self.torrentIdentifier(from: source)
        } catch {
            completion(.failure(.invalidFile))
            return
        }

        guard let helper = helperOverride ?? Self.resolveHelper() else {
            completion(.failure(.helperUnavailable))
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                torrentSessionDirectoryPrefix + "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
        let manifestURL = directory.appendingPathComponent("torrent-files.json")
        let scriptURL = directory.appendingPathComponent("torrent-metadata.mjs")
        let logURL = directory.appendingPathComponent("webtorrent.log")
        let loaderURL = directory.appendingPathComponent("webtorrent-loader.mjs")
        let bootstrapURL = directory.appendingPathComponent("webtorrent-bootstrap.mjs")
        let downloadURL = directory.appendingPathComponent("download", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: downloadURL, withIntermediateDirectories: true)
            try Self.writeMetadataScript(to: scriptURL)
            try Self.writeCompatibilityLoader(to: loaderURL, bootstrapURL: bootstrapURL)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            completion(.failure(.helperFailed(error.localizedDescription)))
            return
        }

        let process = Process()
        process.executableURL = helper.nodeExecutableURL
        process.arguments = [
            scriptURL.path,
            helper.webTorrentModuleURL.path,
            torrentIdentifier,
            manifestURL.path,
            downloadURL.path,
            downloadDirectory.path
        ]
        var environment = ProcessInfo.processInfo.environment
        let compatibilityOption = "--import=\(bootstrapURL.absoluteString)"
        if let nodeOptions = environment["NODE_OPTIONS"], !nodeOptions.isEmpty {
            environment["NODE_OPTIONS"] = "\(nodeOptions) \(compatibilityOption)"
        } else {
            environment["NODE_OPTIONS"] = compatibilityOption
        }
        process.environment = environment
        let logHandle = try? FileHandle(forWritingTo: logURL)
        defer { try? logHandle?.close() }
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
        process.qualityOfService = .userInitiated

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            completion(.failure(.helperFailed(error.localizedDescription)))
            return
        }

        let requestID = self.requestID
        self.process = process
        temporaryDirectory = directory
        streamWaitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + .seconds(90)

            while !Task.isCancelled, ContinuousClock.now < deadline {
                let data = await readFile(manifestURL)
                guard !Task.isCancelled, self.requestID == requestID else { return }
                if let data,
                   let manifest = try? JSONDecoder().decode(TorrentManifest.self, from: data),
                   !manifest.files.isEmpty {
                    streamWaitTask = nil
                    self.stop()
                    completion(.success(manifest.files))
                    return
                }

                if !process.isRunning {
                    let detail = process.terminationStatus == 0
                        ? "The torrent did not expose any files."
                        : "The metadata helper exited with status \(process.terminationStatus)."
                    let message = await Self.appendingLogTail(detail, logURL: logURL)
                    guard !Task.isCancelled, self.requestID == requestID else { return }
                    self.stop()
                    completion(.failure(.helperFailed(message)))
                    return
                }

                try? await Task.sleep(for: .milliseconds(150))
            }

            guard !Task.isCancelled, self.requestID == requestID else { return }
            self.stop()
            completion(.failure(.timedOut))
        }
    }

    private nonisolated static func removeStaleDownloadDirectories() {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix(torrentSessionDirectoryPrefix),
                  isStaleDirectory(url, name: name, currentPID: currentPID) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// A directory is stale only when its owner can be proven gone: the name carries
    /// the creating process's PID (…) and that PID no longer exists. Live owners, our
    /// own PID (this run's active stream), and unparseable names are left alone; the
    /// last group falls back to a conservative age threshold so leftovers from
    /// pre-PID app versions still get cleaned eventually.
    private nonisolated static func isStaleDirectory(_ url: URL, name: String, currentPID: pid_t) -> Bool {
        let remainder = name.dropFirst(torrentSessionDirectoryPrefix.count)
        if let pidText = remainder.split(separator: "-").first, let ownerPID = Int32(pidText), ownerPID > 0 {
            if ownerPID == currentPID { return false }
            // kill(pid, 0) probes existence: 0 or EPERM (another user's live process)
            // means alive; ESRCH means the owner is gone.
            return kill(ownerPID, 0) == -1 && errno == ESRCH
        }

        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }
        return Date().timeIntervalSince(modified) > 24 * 3600
    }

    func start(
        from source: URL,
        selectedFileIndex: Int? = nil,
        completion: @escaping @MainActor (Result<URL, StreamError>) -> Void
    ) {
        if let selectedFileIndex, selectedFileIndex < 0 {
            completion(.failure(.invalidFile))
            return
        }
        let identifier: String
        do {
            identifier = try Self.torrentIdentifier(from: source)
        } catch {
            completion(.failure(.invalidFile))
            return
        }

        // Keep the torrent client and its verified piece map alive while the
        // user switches files. The response carries the request identity so an
        // old stream URL cannot be mistaken for the newly selected video.
        if activeIdentifier == identifier, let process, process.isRunning,
           let directory = temporaryDirectory {
            streamWaitTask?.cancel()
            requestID = UUID()
            do {
                try writeSelection(selectedFileIndex, in: directory)
                waitForStream(process: process, directory: directory, completion: completion)
            } catch {
                completion(.failure(.helperFailed(error.localizedDescription)))
            }
            return
        }
        stop()
        guard let helper = helperOverride ?? Self.resolveHelper() else {
            completion(.failure(.helperUnavailable))
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            torrentSessionDirectoryPrefix + "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )
        let scriptURL = directory.appendingPathComponent("torrent-stream.mjs")
        let logURL = directory.appendingPathComponent("webtorrent.log")
        let bootstrapURL = directory.appendingPathComponent("webtorrent-bootstrap.mjs")
        let extensions = MediaSupport.extensions.subtracting(["torrent", "magnet", "m3u", "m3u8"]).sorted()
        let extensionsJSON: String
        do {
            extensionsJSON = String(decoding: try JSONEncoder().encode(extensions), as: UTF8.self)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try TorrentDownloadRuntime.write(to: scriptURL)
            try Self.writeCompatibilityLoader(
                to: directory.appendingPathComponent("webtorrent-loader.mjs"), bootstrapURL: bootstrapURL
            )
            try writeSelection(selectedFileIndex, in: directory)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            completion(.failure(.helperFailed(error.localizedDescription)))
            return
        }
        let process = Process()
        process.executableURL = helper.nodeExecutableURL
        process.arguments = [
            scriptURL.path, helper.webTorrentModuleURL.path, identifier,
            downloadDirectory.path, directory.appendingPathComponent("stream-url").path,
            directory.appendingPathComponent("selection.json").path,
            extensionsJSON
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["NODE_OPTIONS"] = [environment["NODE_OPTIONS"], "--import=\(bootstrapURL.absoluteString)"]
            .compactMap { $0 }.joined(separator: " ")
        process.environment = environment
        let logHandle = try? FileHandle(forWritingTo: logURL)
        defer { try? logHandle?.close() }
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
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
        activeIdentifier = identifier
        waitForStream(process: process, directory: directory, completion: completion)
    }

    private func writeSelection(_ index: Int?, in directory: URL) throws {
        try JSONEncoder().encode(Selection(requestID: requestID, index: index))
            .write(to: directory.appendingPathComponent("selection.json"), options: .atomic)
    }

    private func waitForStream(
        process: Process, directory: URL,
        completion: @escaping @MainActor (Result<URL, StreamError>) -> Void
    ) {
        let requestID = self.requestID
        streamWaitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Existing pieces must be verified before a resumed stream is ready.
            let deadline = ContinuousClock.now + .seconds(600)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                let data = await readFile(directory.appendingPathComponent("stream-url"))
                guard !Task.isCancelled, self.requestID == requestID else { return }
                if let data,
                   let response = try? JSONDecoder().decode(StreamResponse.self, from: data),
                   response.requestID == requestID,
                   response.url.scheme == "http", response.url.host == "127.0.0.1" {
                    streamWaitTask = nil
                    completion(.success(response.url))
                    return
                }
                if !process.isRunning {
                    let message = await Self.appendingLogTail(
                        "The torrent helper exited with status \(process.terminationStatus).",
                        logURL: directory.appendingPathComponent("webtorrent.log")
                    )
                    guard !Task.isCancelled, self.requestID == requestID else { return }
                    self.stop()
                    completion(.failure(.helperFailed(message)))
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, self.requestID == requestID else { return }
            self.stop()
            completion(.failure(.timedOut))
        }
    }

    func stop() {
        requestID = UUID()
        streamWaitTask?.cancel()
        streamWaitTask = nil

        let processToStop = process
        let directoryToRemove = temporaryDirectory
        process = nil
        temporaryDirectory = nil
        activeIdentifier = nil

        if let processToStop, processToStop.isRunning {
            processToStop.terminationHandler = { _ in
                guard let directoryToRemove else { return }
                try? FileManager.default.removeItem(at: directoryToRemove)
            }
            processToStop.terminate()
        }

        // Only scripts, logs, and metadata-probe scratch files are temporary.
        // Video data is stored separately in downloadDirectory and is never deleted.
        if let directoryToRemove {
            try? FileManager.default.removeItem(at: directoryToRemove)
        }
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

    private static func writeMetadataScript(to url: URL) throws {
        let script = """
        import fs from 'node:fs/promises'
        import { pathToFileURL } from 'node:url'
        import { createRequire } from 'node:module'
        import path from 'node:path'

        const [modulePath, torrentIdentifier, outputPath, downloadPath, downloadRoot] = process.argv.slice(2)

        try {
          const { default: WebTorrent } = await import(pathToFileURL(modulePath).href)
          const require = createRequire(pathToFileURL(modulePath))
          async function resolveDependency(name) {
            try { return require.resolve(name) } catch (error) {
              if (error.code !== 'ERR_PACKAGE_PATH_NOT_EXPORTED') throw error
              for (const directory of require.resolve.paths(name)) {
                const entry = path.join(directory, name, 'index.js')
                try { await fs.access(entry); return entry } catch {}
              }
              throw error
            }
          }
          const { default: parseTorrent } = await import(pathToFileURL(await resolveDependency('parse-torrent')).href)
          const input = torrentIdentifier.toLowerCase().startsWith('magnet:')
            ? torrentIdentifier : await fs.readFile(torrentIdentifier)
          const parsed = await parseTorrent(input)
          let source = input
          try { source = await fs.readFile(path.join(downloadRoot, '.metadata', `${parsed.infoHash}.torrent`)) }
          catch (error) { if (error.code !== 'ENOENT') throw error }
          const client = new WebTorrent()
          let finished = false

          function fail(error) {
            if (finished) return
            finished = true
            console.error(error?.stack || error?.message || String(error))
            try {
              client.destroy(() => process.exit(1))
            } catch {
              process.exit(1)
            }
          }

          client.on('error', fail)
          const torrent = client.add(source, { path: downloadPath, deselect: true })
          torrent.on('warning', warning => console.error(warning?.message || String(warning)))
          torrent.once('ready', async () => {
            if (finished) return
            try {
              const manifest = {
                files: torrent.files.map((file, index) => ({
                  index,
                  name: file.name,
                  path: file.path,
                  length: file.length
                }))
              }
              const temporaryPath = `${outputPath}.tmp`
              await fs.writeFile(temporaryPath, JSON.stringify(manifest))
              await fs.rename(temporaryPath, outputPath)
              finished = true
              client.destroy(() => process.exit(0))
            } catch (error) {
              fail(error)
            }
          })
        } catch (error) {
          console.error(error?.stack || error?.message || String(error))
          process.exit(1)
        }
        """
        try Data(script.utf8).write(to: url, options: .atomic)
    }

    private static func writeCompatibilityLoader(to loaderURL: URL, bootstrapURL: URL) throws {
        // WebTorrent CLI 6 currently resolves WebTorrent 2.x alongside uint8-util
        // 2.3.x. That combination passes a hex string to an API which now requires a
        // byte array and exits with status 1 for every magnet. Its file selector also
        // uses substring matching, so index 38 selects 3, 8, and 38. Patch those two
        // narrow compatibility issues while loading WebTorrent; newer versions whose
        // source no longer contains these expressions pass through unchanged.
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
            source: source
              .replaceAll(
                'arr2hex(parsedTorrent.infoHash)',
                'arr2hex(parsedTorrent.infoHashBuffer)'
              )
              .replaceAll(
                'if (this.so.includes(i)) {',
                "if (String(this.so).split(',').map(Number).includes(i)) {"
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
            source: source
              .replaceAll(
                'arr2hex(parsedTorrent.infoHash)',
                'arr2hex(parsedTorrent.infoHashBuffer)'
              )
              .replaceAll(
                'if (this.so.includes(i)) {',
                "if (String(this.so).split(',').map(Number).includes(i)) {"
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

    private static func appendingLogTail(_ message: String, logURL: URL) async -> String {
        guard let data = await readFileData(at: logURL),
              let text = String(data: data, encoding: .utf8) else { return message }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return message }
        let tail = trimmed.count > 400 ? String(trimmed.suffix(400)) : trimmed
        return "\(message)\n\(tail)"
    }

    /// How to launch WebTorrent CLI: either a bundled node runtime plus the CLI
    /// script (the "+ Torrents" dmg variant), or a plain `webtorrent` executable.
    struct Helper {
        let executableURL: URL
        let prefixArguments: [String]
        let nodeExecutableURL: URL
        let webTorrentModuleURL: URL
    }

    private static func resolveHelper() -> Helper? {
        let fileManager = FileManager.default

        // 1. Runtime bundled inside the app bundle ("+ Torrents" dmg variant):
        //    node launcher in Contents/Helpers, the npm tree in Contents/Resources.
        let nodeURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/webtorrent-node")
        let cliURL = Bundle.main.resourceURL?
            .appendingPathComponent("webtorrent-cli/bin/cmd.js")
        let moduleURL = Bundle.main.resourceURL?
            .appendingPathComponent("webtorrent-cli/node_modules/webtorrent/index.js")
        if let cliURL,
           let moduleURL,
           fileManager.isExecutableFile(atPath: nodeURL.path),
           fileManager.fileExists(atPath: cliURL.path),
           fileManager.fileExists(atPath: moduleURL.path) {
            return Helper(
                executableURL: nodeURL,
                prefixArguments: [cliURL.path],
                nodeExecutableURL: nodeURL,
                webTorrentModuleURL: moduleURL
            )
        }

        // 2. Installed CLI (MACMPV_WEBTORRENT override, PATH, Homebrew locations).
        guard let executable = webtorrentExecutable,
              let nodeExecutableURL,
              let webTorrentModuleURL = webTorrentModuleURL(for: executable) else { return nil }
        return Helper(
            executableURL: executable,
            prefixArguments: [],
            nodeExecutableURL: nodeExecutableURL,
            webTorrentModuleURL: webTorrentModuleURL
        )
    }

    private static func webTorrentModuleURL(for executable: URL) -> URL? {
        let fileManager = FileManager.default
        let resolvedExecutable = executable.resolvingSymlinksInPath()
        let cliRoot = resolvedExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            cliRoot.appendingPathComponent("node_modules/webtorrent/index.js"),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/webtorrent-cli/node_modules/webtorrent/index.js"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/webtorrent-cli/node_modules/webtorrent/index.js"),
            URL(fileURLWithPath: "/opt/local/lib/node_modules/webtorrent-cli/node_modules/webtorrent/index.js")
        ]
        return candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    private static var nodeExecutableURL: URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                (String($0) as NSString).appendingPathComponent("node")
            })
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/opt/local/bin/node"
        ])
        return candidates.first(where: fileManager.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
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
