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

    @Test func keyframePreviewIsFastPathAndExactPreviewIsTheRealFrame() async throws {
        let source = Bundle.module.url(
            forResource: "seek-colors-one-keyframe", withExtension: "mp4", subdirectory: "Fixtures"
        )!
        let renderer = SeekPreviewRenderer()
        defer { renderer.reset() }
        // Alternate modes on one open decoder: each seek must honor its own mode.
        for (seconds, exact, channel) in [(2.5, false, 0), (2.5, true, 1), (4.5, false, 0), (4.5, true, 2)] {
            let data = try #require(await renderer.frame(source: source, seconds: seconds, exact: exact))
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let pixel = try #require(bitmap.colorAt(x: 160, y: 90)?.usingColorSpace(.deviceRGB))
            let channels = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
            #expect(channels[channel] > 0.8, "\(seconds)s exact=\(exact)")
        }
    }

    @Test func canceledPreviewKeepsTheDecoderOpen() async throws {
        let server = try PreviewHTTPServer(video: Data(contentsOf: fixture))
        defer { server.stop() }
        let base = try await server.start()
        let source = base.appendingPathComponent("torrent/7")
        let renderer = SeekPreviewRenderer()
        defer { renderer.reset() }
        #expect(await renderer.frame(source: source, seconds: 0.5) != nil)
        let requests = await server.requestCount()
        let canceled = Task { await renderer.frame(source: source, seconds: 5.8, exact: true) }
        canceled.cancel()
        _ = await canceled.value
        let data = try #require(await renderer.frame(source: source, seconds: 2.5))
        let pixel = try #require(NSBitmapImageRep(data: data)?.colorAt(x: 160, y: 90)?.usingColorSpace(.deviceRGB))
        #expect(pixel.greenComponent > 0.8)
        #expect(await server.requestCount() == requests)
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

    @Test func repeatedPreviewsReuseTheOpenVideoAndSeekBackwards() async throws {
        let server = try PreviewHTTPServer(video: Data(contentsOf: fixture))
        defer { server.stop() }
        let base = try await server.start()
        let source = base.appendingPathComponent("torrent/7")
        let renderer = SeekPreviewRenderer()
        defer { renderer.reset() }
        let first = try #require(await renderer.frame(source: source, seconds: 5.8))
        #expect(NSBitmapImageRep(data: first) != nil)
        let initialRequests = await server.requestCount()
        for (seconds, channel) in [(0.5, 0), (2.5, 1), (5.8, 2), (0.5, 0)] {
            let data = try #require(await renderer.frame(source: source, seconds: seconds))
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let pixel = try #require(bitmap.colorAt(x: 160, y: 90)?.usingColorSpace(.deviceRGB))
            #expect([pixel.redComponent, pixel.greenComponent, pixel.blueComponent][channel] > 0.8)
        }
        // This tiny movie fits in the open decoder's input buffer. Reopening it
        // for every thumbnail would require at least one new request each time.
        #expect(await server.requestCount() == initialRequests)
        renderer.reset()
        #expect(await renderer.frame(source: source, seconds: 2.5) != nil)
        #expect(await server.requestCount() > initialRequests)
    }

    @Test @MainActor func cursorMovementKeepsTheImageAndCoalescesPendingPositions() async throws {
        let gate = PreviewGate()
        let model = SeekPreviewModel(hoverDelay: .zero, render: { await gate.render($0, $1) })
        let png = try #require(await SeekPreviewRenderer.render(source: fixture, seconds: 1))
        model.setSource(fixture)
        model.show(at: 1, duration: 6)
        try await waitUntil { await gate.calls.count == 1 }
        await gate.release(png)
        try await waitUntil { !model.isLoading }
        let image = try #require(model.image)

        model.show(at: 2, duration: 6)
        try await waitUntil { await gate.calls.count == 2 }
        model.show(at: 3, duration: 6)
        model.show(at: 4, duration: 6)
        #expect(model.image === image)
        #expect(model.imageSecond == 1)
        #expect(model.isLoading)
        #expect(await gate.calls.count == 2)
        await gate.release(png)
        try await waitUntil { await gate.calls.count == 3 }
        #expect(await gate.calls.last?.1 == 4)
        #expect(model.image === image)
        #expect(model.imageSecond == 1)
        await gate.release(png)
        try await waitUntil { !model.isLoading }
        #expect(model.imageSecond == 4)
    }

    @Test @MainActor func delayAppliesOnlyWhenEnteringTheSeekBar() async throws {
        let gate = PreviewGate()
        let model = SeekPreviewModel(hoverDelay: .seconds(1), render: { await gate.render($0, $1) })
        defer { model.hide() }
        let png = try #require(await SeekPreviewRenderer.render(source: fixture, seconds: 1))
        model.setSource(fixture)
        let entered = ContinuousClock.now
        model.show(at: 1, duration: 6)
        try await Task.sleep(for: .milliseconds(50))
        model.show(at: 2, duration: 6)
        #expect(await gate.calls.isEmpty)
        try await waitUntil { await gate.calls.count == 1 }
        #expect(ContinuousClock.now - entered >= .milliseconds(900))
        #expect(await gate.calls.last?.1 == 2)
        await gate.release(png)
        try await waitUntil { !model.isLoading }

        // Even after the previous request finishes, movement must not wait again.
        model.show(at: 3, duration: 6)
        try await waitUntil(timeout: .milliseconds(400)) { await gate.calls.count == 2 }
        await gate.release(png)
        try await waitUntil { !model.isLoading }

        // A cached preview on re-entry activates immediate updates as well.
        model.hide()
        model.show(at: 2, duration: 6)
        #expect(model.image != nil)
        model.show(at: 4, duration: 6)
        try await waitUntil(timeout: .milliseconds(400)) { await gate.calls.count == 3 }
        await gate.release(png)
        try await waitUntil { !model.isLoading }

        model.hide()
        model.show(at: 0, duration: 6)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await gate.calls.count == 3)
    }

    @Test @MainActor func restingCursorRefinesToTheExactFrameAndMovementCancelsIt() async throws {
        let fast = PreviewGate()
        let exact = PreviewGate()
        let model = SeekPreviewModel(
            hoverDelay: .zero,
            refineDelay: .milliseconds(50),
            render: { await fast.render($0, $1) },
            refine: { await exact.render($0, $1) }
        )
        defer { model.hide() }
        let keyframe = try #require(await SeekPreviewRenderer.render(source: fixture, seconds: 0.5))
        let real = try #require(await SeekPreviewRenderer.render(source: fixture, seconds: 2.5))
        model.setSource(fixture)

        model.show(at: 2.4, duration: 6)
        try await waitUntil { await fast.calls.count == 1 }
        await fast.release(keyframe)
        try await waitUntil { !model.isLoading }
        let approximate = try #require(model.image)
        try await waitUntil { await exact.calls.count == 1 }
        #expect(await exact.calls.last?.1 == 2)
        await exact.release(real)
        try await waitUntil { model.image !== approximate }
        #expect(model.imageSecond == 2)

        // Returning to a refined second shows the exact image with no new work.
        model.show(at: 3, duration: 6)
        try await waitUntil { await fast.calls.count == 2 }
        await fast.release(keyframe)
        try await waitUntil { !model.isLoading }
        try await waitUntil { await exact.calls.count == 2 }
        model.show(at: 2.7, duration: 6)
        let refined = try #require(model.image)
        try await Task.sleep(for: .milliseconds(120))
        #expect(await fast.calls.count == 2)
        #expect(await exact.calls.count == 2)

        // The exact decode for 3 s was canceled by moving; its late result is
        // dropped instead of replacing the image for 2 s.
        await exact.release(real)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.image === refined)
        #expect(model.imageSecond == 2)
        // 3 s still holds only its keyframe image, so resting there refines again.
        model.show(at: 3, duration: 6)
        try await waitUntil { await exact.calls.count == 3 }
        #expect(await fast.calls.count == 2)
        await exact.release(real)
    }

    @MainActor private func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }
}
