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
        let probe = MediaProbe(executable: helper, timeout: .milliseconds(80), maximumConcurrentProbes: 2)
        let start = ContinuousClock.now
        await withTaskGroup(of: MediaMetadata?.self) { group in
            for _ in 0..<8 {
                group.addTask { await probe.inspect(URL(fileURLWithPath: "/tmp/unused.mp4")) }
            }
            for await result in group { #expect(result == nil) }
        }
        #expect(ContinuousClock.now - start < .seconds(8))
    }
}
