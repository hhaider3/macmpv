import AppKit
import CMPV
import Foundation
import Observation

/// A separate, silent decoder. All session state and mpv calls stay on queue.
final class SeekPreviewRenderer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macmpv.seek-preview", qos: .utility)
    private var session: Session?
    private var idleGeneration = UUID()

    deinit {
        // The owner may be released on the main actor; destroy mpv on its queue.
        let session = session
        queue.async { withExtendedLifetime(session) {} }
    }

    /// One-shot convenience for probes and tests. The player retains its renderer.
    static func render(source: URL, seconds: Double) async -> Data? {
        await SeekPreviewRenderer().frame(source: source, seconds: seconds)
    }

    func frame(source: URL, seconds: Double) async -> Data? {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
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

    func reset() {
        queue.async { [self] in closeSession() }
    }

    private func closeSession() {
        idleGeneration = UUID()
        session = nil
    }

    private func extract(source: URL, seconds: Double, cancellation: Cancellation) -> Data? {
        guard !cancellation.isCancelled, seconds.isFinite, seconds >= 0 else { return nil }
        idleGeneration = UUID()
        var succeeded = false
        defer {
            if !succeeded { closeSession() }
        }
        if session?.source != source {
            closeSession()
            session = Session.open(source: source, seconds: seconds)
        } else if let handle = session?.handle {
            // Discard notifications from the previous completed seek before
            // waiting for this seek's first displayed frame.
            while cinewave_mpv_event_id(cinewave_mpv_wait_event(handle, 0)) != cinewave_mpv_event_none() {}
            guard cinewave_mpv_command_3(handle, "seek", String(seconds), "absolute+exact") >= 0 else { return nil }
        }
        guard let session else { return nil }
        let handle = session.handle
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
            if eventID == cinewave_mpv_event_playback_restart() {
                guard !cancellation.isCancelled else { return nil }
                let file = session.directory.appendingPathComponent("preview.png")
                defer { try? FileManager.default.removeItem(at: file) }
                guard cinewave_mpv_preview_screenshot(handle, file.path) >= 0,
                      let data = try? Data(contentsOf: file) else { return nil }
                succeeded = true
                let generation = idleGeneration
                // Release decoder memory and any HTTP connection after hovering.
                queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.idleGeneration == generation else { return }
                    self.closeSession()
                }
                return data
            }
            if eventID == cinewave_mpv_event_end_file() { return nil }
            if eventID == cinewave_mpv_event_shutdown() { return nil }
        }
        return nil
    }

    // Ownership may be handed back to queue during renderer deinitialization.
    private final class Session: @unchecked Sendable {
        let source: URL
        let handle: OpaquePointer
        let directory: URL

        private init(source: URL, handle: OpaquePointer, directory: URL) {
            self.source = source
            self.handle = handle
            self.directory = directory
        }

        static func open(source: URL, seconds: Double) -> Session? {
            guard let handle = cinewave_mpv_create() else { return nil }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("macmpv-preview-\(UUID())", isDirectory: true)
            var succeeded = false
            defer {
                if !succeeded {
                    cinewave_mpv_destroy(handle)
                    try? FileManager.default.removeItem(at: directory)
                }
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch { return nil }
            let options = [
                ("config", "no"), ("load-scripts", "no"), ("ytdl", "no"),
                ("terminal", "no"), ("msg-level", "all=no"),
                ("audio", "no"), ("aid", "no"), ("sid", "no"),
                ("sub-auto", "no"), ("audio-file-auto", "no"),
                ("vo", "null"), ("screenshot-sw", "yes"), ("screenshot-png-compression", "1"),
                ("vf", "scale=320:180:force_original_aspect_ratio=decrease"),
                ("hwdec", "no"), ("vd-lavc-threads", "2"),
                ("start", String(seconds)), ("hr-seek", "yes"), ("pause", "yes"),
                ("idle", "yes"), ("keep-open", "always"),
                ("cache", "no"), ("demuxer-readahead-secs", "0"),
                ("demuxer-max-bytes", "4MiB"), ("network-timeout", "2")
            ]
            for (name, value) in options {
                guard cinewave_mpv_set_option_string(handle, name, value) >= 0 else { return nil }
            }
            guard cinewave_mpv_initialize(handle) >= 0,
                  cinewave_mpv_add_preloaded_hook(handle) >= 0 else { return nil }
            let path = source.isFileURL ? source.path : source.absoluteString
            guard cinewave_mpv_command_3(handle, "loadfile", path, "replace") >= 0 else { return nil }
            succeeded = true
            return Session(source: source, handle: handle, directory: directory)
        }

        deinit {
            cinewave_mpv_destroy(handle)
            try? FileManager.default.removeItem(at: directory)
        }
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
    private(set) var imageSecond: Double?
    private(set) var isLoading = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var requestedSecond: Double?
    @ObservationIgnored private var cache: [Double: NSImage] = [:]
    @ObservationIgnored private var cacheOrder: [Double] = []
    @ObservationIgnored private let render: @Sendable (URL, Double) async -> Data?
    @ObservationIgnored private let hoverDelay: Duration
    @ObservationIgnored private let resetRenderer: @Sendable () -> Void

    init(
        hoverDelay: Duration = .milliseconds(80),
        render: (@Sendable (URL, Double) async -> Data?)? = nil
    ) {
        self.hoverDelay = hoverDelay
        let renderer = SeekPreviewRenderer()
        self.render = render ?? { await renderer.frame(source: $0, seconds: $1) }
        resetRenderer = { renderer.reset() }
    }

    func setSource(_ source: URL?) {
        hide()
        resetRenderer()
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
        requestedSecond = second
        if let cached = cache[second] {
            image = cached
            imageSecond = second
            isLoading = false
            touchCache(second)
            return
        }
        isLoading = true
        // Finish the current frame and then take the latest requested position.
        // Canceling on every mouse movement repeatedly reopened the same video.
        guard task == nil else { return }
        let request = revision
        let render = render
        let delay = hoverDelay
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            while !Task.isCancelled, let second = self?.requestedSecond {
                let data = await render(source, second)
                guard !Task.isCancelled, let self, self.revision == request else { return }
                if let data, let image = NSImage(data: data) {
                    self.cache[second] = image
                    self.touchCache(second)
                    if self.cacheOrder.count > 120 {
                        self.cache.removeValue(forKey: self.cacheOrder.removeFirst())
                    }
                    if self.requestedSecond == second || self.image == nil {
                        self.image = image
                        self.imageSecond = second
                    }
                } else if self.requestedSecond == second {
                    self.image = nil
                    self.imageSecond = nil
                }
                if self.requestedSecond == second || self.requestedSecond.flatMap({ self.cache[$0] }) != nil {
                    self.isLoading = false
                    self.task = nil
                    return
                }
            }
        }
    }

    func hide() {
        revision = UUID()
        task?.cancel()
        task = nil
        requestedSecond = nil
        image = nil
        imageSecond = nil
        isLoading = false
    }

    private func touchCache(_ second: Double) {
        cacheOrder.removeAll { $0 == second }
        cacheOrder.append(second)
    }
}
