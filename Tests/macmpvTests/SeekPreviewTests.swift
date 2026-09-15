import AppKit
import Foundation
import Testing
@testable import macmpv

private actor PreviewGate {
    private var pending: [CheckedContinuation<Data?, Never>] = []
    private(set) var calls: [(URL, Double)] = []

    func render(_ source: URL, _ seconds: Double) async -> Data? {
        calls.append((source, seconds))
        // Deliberately ignores cancellation to exercise stale-result protection.
        return await withCheckedContinuation { pending.append($0) }
    }

    func release(_ data: Data?) {
        pending.removeFirst().resume(returning: data)
    }
}

struct SeekPreviewTests {
    private var fixture: URL {
        Bundle.module.url(forResource: "seek-colors", withExtension: "mp4", subdirectory: "Fixtures")!
    }

    @Test func decoderReturnsTheFrameAtTheRequestedTime() async throws {
        for (seconds, channel) in [(0.5, 0), (2.5, 1), (5.8, 2)] {
            let data = try #require(await SeekPreviewRenderer.render(source: fixture, seconds: seconds))
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide == 320)
            #expect(bitmap.pixelsHigh == 180)
            let pixel = try #require(bitmap.colorAt(x: 160, y: 90)?.usingColorSpace(.deviceRGB))
            let channels = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
            #expect(channels[channel] > 0.8)
            #expect(channels.enumerated().filter { $0.offset != channel }.allSatisfy { $0.element < 0.2 })
        }
    }

    @Test func missingVideoAndCancelledRequestReturnWithoutAnImage() async {
        let missing = URL(fileURLWithPath: "/tmp/macmpv-missing-\(UUID()).mp4")
        #expect(await SeekPreviewRenderer.render(source: missing, seconds: 3) == nil)
        let source = fixture
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await SeekPreviewRenderer.render(source: source, seconds: 1)
        }
        #expect(await task.value == nil)
    }

    @Test func decoderSupportsStreamURLsAndCancelsStalledReads() async throws {
        let server = try PreviewHTTPServer(video: Data(contentsOf: fixture))
        defer { server.stop() }
        let base = try await server.start()
        let data = try #require(await SeekPreviewRenderer.render(source: base.appendingPathComponent("torrent/7"), seconds: 2.5))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let pixel = try #require(bitmap.colorAt(x: 160, y: 90)?.usingColorSpace(.deviceRGB))
        #expect(pixel.greenComponent > 0.8)
        #expect(await SeekPreviewRenderer.render(source: base.appendingPathComponent("unseekable"), seconds: 2.5) == nil)

        let task = Task { await SeekPreviewRenderer.render(source: base.appendingPathComponent("stall"), seconds: 1) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        #expect(await task.value == nil)
        #expect(ContinuousClock.now - start < .seconds(3))

        let timeoutStart = ContinuousClock.now
        #expect(await SeekPreviewRenderer.render(source: base.appendingPathComponent("stall"), seconds: 1) == nil)
        #expect(ContinuousClock.now - timeoutStart < .seconds(6))
    }

    @Test @MainActor func hoverCacheAndFileSwitchDiscardStaleFrames() async throws {
        let gate = PreviewGate()
        let model = SeekPreviewModel(hoverDelay: .zero, render: { await gate.render($0, $1) })
        let source = fixture
        let png = try #require(await SeekPreviewRenderer.render(source: source, seconds: 1))
        model.setSource(source)
        model.show(at: 1.2, duration: 6)
        try await waitUntil { await gate.calls.count == 1 }
        await gate.release(png)
        try await waitUntil { !model.isLoading }
        #expect(model.image != nil)

        model.hide()
        #expect(model.image == nil)
        model.show(at: 1.9, duration: 6)
        #expect(model.image != nil)
        #expect(await gate.calls.count == 1)

        model.show(at: 5.99, duration: 6)
        try await waitUntil { await gate.calls.count == 2 }
        #expect(await gate.calls.last?.1 == 5)
        let nextSource = URL(string: "http://127.0.0.1:1234/torrent/7")!
        model.setSource(nextSource)
        model.show(at: 0, duration: 6)
        try await waitUntil { await gate.calls.count == 3 }
        await gate.release(png) // Result from the old file.
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.image == nil)
        #expect(model.isLoading)
        #expect(await gate.calls.last?.0 == nextSource)
        model.hide()
        await gate.release(png) // Result after leaving the seek bar.
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.image == nil)
        #expect(!model.isLoading)
    }

    @Test @MainActor func quickHoverDoesNotStartADecoder() async throws {
        let gate = PreviewGate()
        let model = SeekPreviewModel(hoverDelay: .milliseconds(40), render: { await gate.render($0, $1) })
        model.setSource(fixture)
        model.show(at: 2, duration: 6)
        model.hide()
        try await Task.sleep(for: .milliseconds(80))
        #expect(await gate.calls.isEmpty)
        #expect(model.image == nil)
    }

    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }
}
