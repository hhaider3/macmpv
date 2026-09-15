import AppKit
import CMPV
import Foundation
import Observation

/// A separate, silent decoder. Never seeks or changes the playback engine.
enum SeekPreviewRenderer {
    private static let queue = DispatchQueue(label: "macmpv.seek-preview", qos: .utility)

    static func render(source: URL, seconds: Double) async -> Data? {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let data = autoreleasepool {
                        extract(source: source, seconds: seconds, cancellation: cancellation)
                    }
                    continuation.resume(returning: data)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func extract(source: URL, seconds: Double, cancellation: Cancellation) -> Data? {
        guard !cancellation.isCancelled, seconds.isFinite, seconds >= 0 else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmpv-preview-\(UUID())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let handle = cinewave_mpv_create() else { return nil }
        defer { cinewave_mpv_destroy(handle) }

        let options = [
            ("config", "no"), ("load-scripts", "no"), ("ytdl", "no"),
            ("terminal", "no"), ("msg-level", "all=no"),
            ("audio", "no"), ("aid", "no"), ("sid", "no"),
            ("sub-auto", "no"), ("audio-file-auto", "no"),
            ("vo", "image"), ("vo-image-format", "png"),
            ("vo-image-png-compression", "1"), ("vo-image-outdir", directory.path),
            ("vf", "scale=320:180:force_original_aspect_ratio=decrease"),
            ("hwdec", "no"), ("vd-lavc-threads", "2"),
            ("start", String(seconds)), ("hr-seek", "yes"), ("frames", "1"),
            ("idle", "yes"), ("keep-open", "no"),
            // Avoid speculative read-ahead competing with torrent playback.
            ("cache", "no"), ("demuxer-readahead-secs", "0"),
            ("demuxer-max-bytes", "4MiB"), ("network-timeout", "2")
        ]
        for (name, value) in options {
            guard cinewave_mpv_set_option_string(handle, name, value) >= 0 else { return nil }
        }
        guard !cancellation.isCancelled, cinewave_mpv_initialize(handle) >= 0 else { return nil }
        guard cinewave_mpv_add_preloaded_hook(handle) >= 0 else { return nil }
        let path = source.isFileURL ? source.path : source.absoluteString
        guard cinewave_mpv_command_3(handle, "loadfile", path, "replace") >= 0 else { return nil }

        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !cancellation.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            let event = cinewave_mpv_wait_event(handle, 0.05)
            let eventID = cinewave_mpv_event_id(event)
            if eventID == cinewave_mpv_event_hook() {
                // Check before decoding starts: a non-seekable URL can ignore
                // --start and otherwise produce a misleading first-frame image.
                let seekable = cinewave_mpv_get_flag(handle, "seekable", 0) != 0
                cinewave_mpv_continue_hook(handle, event)
                if !seekable { return nil }
            }
            if eventID == cinewave_mpv_event_end_file() {
                guard cinewave_mpv_event_end_file_error(event) >= 0 else { return nil }
                return try? Data(contentsOf: directory.appendingPathComponent("00000001.png"))
            }
            if eventID == cinewave_mpv_event_shutdown() { return nil }
        }
        return nil
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}

@MainActor
@Observable
final class SeekPreviewModel {
    private(set) var source: URL?
    private(set) var image: NSImage?
    private(set) var isLoading = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var requestedSecond: Double?
    @ObservationIgnored private var cache: [Double: NSImage] = [:]
    @ObservationIgnored private var cacheOrder: [Double] = []
    @ObservationIgnored private let render: @Sendable (URL, Double) async -> Data?
    @ObservationIgnored private let hoverDelay: Duration

    init(
        hoverDelay: Duration = .milliseconds(120),
        render: @escaping @Sendable (URL, Double) async -> Data? = SeekPreviewRenderer.render
    ) {
        self.hoverDelay = hoverDelay
        self.render = render
    }

    func setSource(_ source: URL?) {
        hide()
        self.source = source
        cache.removeAll()
        cacheOrder.removeAll()
    }

    func show(at seconds: Double, duration: Double) {
        guard let source, seconds.isFinite, duration.isFinite, duration > 0 else {
            hide()
            return
        }
        // Reuse a frame within each second, and never request a frame past EOF.
        let second = floor(min(max(seconds, 0), max(duration - 0.1, 0)))
        guard requestedSecond != second else { return }
        hide()
        requestedSecond = second
        if let cached = cache[second] {
            image = cached
            touchCache(second)
            return
        }
        isLoading = true
        let request = revision
        let render = render
        let delay = hoverDelay
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            let data = await render(source, second)
            guard !Task.isCancelled, let self, self.revision == request else { return }
            self.isLoading = false
            self.task = nil
            guard let data, let image = NSImage(data: data) else { return }
            self.image = image
            self.cache[second] = image
            self.touchCache(second)
            if self.cacheOrder.count > 48 {
                self.cache.removeValue(forKey: self.cacheOrder.removeFirst())
            }
        }
    }

    func hide() {
        revision = UUID()
        task?.cancel()
        task = nil
        requestedSecond = nil
        image = nil
        isLoading = false
    }

    private func touchCache(_ second: Double) {
        cacheOrder.removeAll { $0 == second }
        cacheOrder.append(second)
    }
}
