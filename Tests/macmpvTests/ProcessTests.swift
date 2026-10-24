import Foundation
import Testing
@testable import macmpv

private actor ReadGate {
    private var continuation: CheckedContinuation<Data?, Never>?
    private(set) var entered = false
    func read(_ url: URL) async -> Data? {
        guard !entered else { return nil }
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

private func executable(in directory: URL, script: String) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("helper")
    try Data(("#!/bin/sh\n" + script).utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

struct ProcessTests {
    @Test(arguments: [false, true]) @MainActor
    func canceledTorrentReadCannotStopReplacement(streaming: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macmpv-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try executable(in: directory, script: "exec /bin/sleep 30\n")
        let helper = MagnetStream.Helper(executableURL: executable, prefixArguments: [], nodeExecutableURL: executable, webTorrentModuleURL: executable)
        let gate = ReadGate()
        let stream = MagnetStream(helper: helper, readFile: { await gate.read($0) })
        defer { stream.stop() }
        let source = URL(string: "magnet:?xt=urn:btih:0123456789012345678901234567890123456789")!
        var completions = 0
        if streaming {
            stream.start(from: source) { _ in completions += 1 }
        } else {
            stream.resolveFiles(from: source) { _ in completions += 1 }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await gate.entered), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.entered)
        stream.resolveFiles(from: source) { _ in completions += 1 }
        let replacement = try #require(stream.process)
        let payload = streaming ? "http://127.0.0.1:1234/video" : "{\"files\":[{\"index\":0,\"name\":\"movie.mp4\",\"path\":\"movie.mp4\",\"length\":10}]}"
        await gate.release(Data(payload.utf8))
        try await Task.sleep(for: .milliseconds(100))
        #expect(stream.process === replacement)
        #expect(replacement.isRunning)
        #expect(completions == 0)
    }

    @Test @MainActor
    func torrentSwitchReusesProcessAndStopKeepsDownloads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macmpv-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try executable(in: directory, script: "exec /bin/sleep 30\n")
        let helper = MagnetStream.Helper(executableURL: executable, prefixArguments: [], nodeExecutableURL: executable, webTorrentModuleURL: executable)
        let downloads = directory.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let savedFile = downloads.appendingPathComponent("movie.mp4")
        let bytes = Data("saved video".utf8)
        try bytes.write(to: savedFile)
        let stream = MagnetStream(helper: helper, downloadDirectory: downloads)
        defer { stream.stop() }
        let source = URL(string: "magnet:?xt=urn:btih:0123456789012345678901234567890123456789")!
        stream.start(from: source, selectedFileIndex: 0) { _ in }
        let original = try #require(stream.process)
        stream.start(from: source, selectedFileIndex: 1) { _ in }
        #expect(stream.process === original)
        #expect(original.isRunning)
        stream.stop()
        #expect(try Data(contentsOf: savedFile) == bytes)
    }

    @Test func probeDrainsLargeStderrAndDecodesMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macmpv-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = try executable(in: directory, script: "/usr/bin/head -c 131072 /dev/zero >&2\nprintf '%s' '{\"streams\":[{\"codec_type\":\"video\",\"width\":1920,\"height\":1080,\"avg_frame_rate\":\"24000/1001\"}],\"format\":{\"duration\":\"60\"}}'\n")
        let probe = MediaProbe(executable: helper)
        let metadata = await probe.inspect(URL(fileURLWithPath: "/tmp/unused.mp4"))
        #expect(metadata?.width == 1920)
        #expect(metadata?.height == 1080)
        #expect(metadata?.duration == 60)
        #expect(abs((metadata?.frameRate ?? 0) - 23.976) < 0.001)
    }

    @Test func slowProbesTimeOutWithoutStarvingConcurrentTasks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macmpv-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = try executable(in: directory, script: "exec /bin/sleep 30\n")
        let probe = MediaProbe(
            executable: helper, timeout: .milliseconds(80), exitGrace: .milliseconds(500), maximumConcurrentProbes: 2
        )
        let start = ContinuousClock.now
        await withTaskGroup(of: MediaMetadata?.self) { group in
            for _ in 0..<8 {
                group.addTask { await probe.inspect(URL(fileURLWithPath: "/tmp/unused.mp4")) }
            }
            for await result in group { #expect(result == nil) }
        }
        #expect(ContinuousClock.now - start < .seconds(8))
    }

    @Test(.timeLimit(.minutes(1))) func probeIgnoringTerminationIsKilledAfterGrace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macmpv-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        // The ignored SIGTERM survives exec, and the child keeps the output pipes open.
        let helper = try executable(in: directory, script: "trap '' TERM\nexec /bin/sleep 30\n")
        // A freshly written script can take a while to start; the timeout leaves
        // time for the trap to be installed before SIGTERM arrives.
        let probe = MediaProbe(executable: helper, timeout: .seconds(1), exitGrace: .milliseconds(300))
        let start = ContinuousClock.now
        #expect(await probe.inspect(URL(fileURLWithPath: "/tmp/unused.mp4")) == nil)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(1_300), "SIGTERM ended the probe; the kill path was not exercised")
        #expect(elapsed < .seconds(5))
    }
}
