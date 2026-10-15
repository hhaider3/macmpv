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
    static func render(source: URL, seconds: Double, exact: Bool = false) async -> Data? {
        await SeekPreviewRenderer().frame(source: source, seconds: seconds, exact: exact)
    }

    /// A keyframe preview decodes one frame: the keyframe at or before `seconds`.
    /// An exact preview decodes from that keyframe up to `seconds`, which for a
    /// 10-second 4K HEVC GOP took 1–2 s instead of about 50 ms.
    func frame(source: URL, seconds: Double, exact: Bool = false) async -> Data? {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let data = autoreleasepool {
                        extract(source: source, seconds: seconds, exact: exact, cancellation: cancellation)
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

    private func extract(source: URL, seconds: Double, exact: Bool, cancellation: Cancellation) -> Data? {
        guard !cancellation.isCancelled, seconds.isFinite, seconds >= 0 else { return nil }
        idleGeneration = UUID()
        var succeeded = false
        defer {
            if succeeded || cancellation.isCancelled {
                // A canceled request (the cursor moved on) leaves a usable
                // decoder; the next seek replaces its pending one. Reopening the
                // file instead would cost every following preview a cold start.
                scheduleIdleClose()
            } else {
                closeSession()
            }
        }
        if session?.source != source {
            closeSession()
            session = Session.open(source: source, seconds: seconds, exact: exact)
        } else if let handle = session?.handle {
            // Discard notifications from earlier seeks before waiting for this
            // seek's first displayed frame. A request canceled during loading can
            // leave the preload hook unanswered, which would stall the file.
            while true {
                let event = cinewave_mpv_wait_event(handle, 0)
                let eventID = cinewave_mpv_event_id(event)
                if eventID == cinewave_mpv_event_none() { break }
                if eventID == cinewave_mpv_event_hook(), !continuePreloadHook(handle, event) { return nil }
                if eventID == cinewave_mpv_event_end_file() || eventID == cinewave_mpv_event_shutdown() { return nil }
            }
            let mode = exact ? "absolute+exact" : "absolute+keyframes"
            guard cinewave_mpv_command_3(handle, "seek", String(seconds), mode) >= 0 else { return nil }
        }
        guard let session else { return nil }
        let handle = session.handle
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !cancellation.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            let event = cinewave_mpv_wait_event(handle, 0.05)
            let eventID = cinewave_mpv_event_id(event)
            if eventID == cinewave_mpv_event_hook(), !continuePreloadHook(handle, event) { return nil }
            if eventID == cinewave_mpv_event_playback_restart() {
                guard !cancellation.isCancelled else { return nil }
                let file = session.directory.appendingPathComponent("preview.png")
                defer { try? FileManager.default.removeItem(at: file) }
                guard cinewave_mpv_preview_screenshot(handle, file.path) >= 0,
                      let data = try? Data(contentsOf: file) else { return nil }
                succeeded = true
                return data
            }
            if eventID == cinewave_mpv_event_end_file() { return nil }
            if eventID == cinewave_mpv_event_shutdown() { return nil }
        }
        return nil
    }

    /// Lets loading continue and reports whether the source is seekable. Checked
    /// before decoding starts: a non-seekable URL can ignore --start and would
    /// otherwise produce a misleading first-frame image.
    private func continuePreloadHook(_ handle: OpaquePointer, _ event: UnsafePointer<mpv_event>?) -> Bool {
        let seekable = cinewave_mpv_get_flag(handle, "seekable", 0) != 0
        cinewave_mpv_continue_hook(handle, event)
        return seekable
    }

    /// Releases decoder memory and any HTTP connection after hovering ends.
    private func scheduleIdleClose() {
        let generation = idleGeneration
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.idleGeneration == generation else { return }
            self.closeSession()
        }
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

        static func open(source: URL, seconds: Double, exact: Bool) -> Session? {
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
                ("start", String(seconds)), ("hr-seek", exact ? "yes" : "no"), ("pause", "yes"),
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
    @ObservationIgnored private var refineTask: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var requestedSecond: Double?
    @ObservationIgnored private var isHoverActivated = false
    @ObservationIgnored private var cache: [Double: NSImage] = [:]
    @ObservationIgnored private var cacheOrder: [Double] = []
    /// Cached seconds whose image is the exact frame, not the preceding keyframe.
    @ObservationIgnored private var exactSeconds: Set<Double> = []
    @ObservationIgnored private let render: @Sendable (URL, Double) async -> Data?
    @ObservationIgnored private let refine: (@Sendable (URL, Double) async -> Data?)?
    @ObservationIgnored private let hoverDelay: Duration
    @ObservationIgnored private let refineDelay: Duration
    @ObservationIgnored private let resetRenderer: @Sendable () -> Void

    /// `render` returns a fast, approximate (keyframe) preview while the cursor
    /// moves; `refine` replaces it with the exact frame once the cursor rests.
    /// Passing only `render` disables refinement.
    init(
        hoverDelay: Duration = .milliseconds(80),
        refineDelay: Duration = .milliseconds(300),
        render: (@Sendable (URL, Double) async -> Data?)? = nil,
        refine: (@Sendable (URL, Double) async -> Data?)? = nil
    ) {
        self.hoverDelay = hoverDelay
        self.refineDelay = refineDelay
        let renderer = SeekPreviewRenderer()
        if let render {
            self.render = render
            self.refine = refine
        } else {
            self.render = { await renderer.frame(source: $0, seconds: $1, exact: false) }
            self.refine = refine ?? { await renderer.frame(source: $0, seconds: $1, exact: true) }
        }
        resetRenderer = { renderer.reset() }
    }

    func setSource(_ source: URL?) {
        hide()
        resetRenderer()
        self.source = source
        cache.removeAll()
        cacheOrder.removeAll()
        exactSeconds.removeAll()
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
        // An exact decode for the previous position would delay this one.
        cancelRefine()
        if let cached = cache[second] {
            if !isHoverActivated {
                // An immediately available preview also completes the entry delay.
                task?.cancel()
                task = nil
                isHoverActivated = true
            }
            image = cached
            imageSecond = second
            isLoading = false
            touchCache(second)
            scheduleRefine(second)
            return
        }
        isLoading = true
        // Finish the current frame and then take the latest requested position.
        // Canceling on every mouse movement repeatedly reopened the same video.
        guard task == nil else { return }
        let request = revision
        let render = render
        let delay = isHoverActivated ? .zero : hoverDelay
        task = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled, self?.revision == request else { return }
            self?.isHoverActivated = true
            while !Task.isCancelled, let second = self?.requestedSecond {
                let data = await render(source, second)
                guard !Task.isCancelled, let self, self.revision == request else { return }
                if let data, let image = NSImage(data: data) {
                    self.store(image, for: second, exact: false)
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
                    if let resting = self.requestedSecond {
                        self.scheduleRefine(resting)
                    }
                    return
                }
            }
        }
    }

    func hide() {
        revision = UUID()
        task?.cancel()
        task = nil
        cancelRefine()
        requestedSecond = nil
        isHoverActivated = false
        image = nil
        imageSecond = nil
        isLoading = false
    }

    /// Once the cursor has rested on `second`, decodes its exact frame and swaps
    /// it in. Any movement cancels this before it can delay the next preview.
    private func scheduleRefine(_ second: Double) {
        guard let refine, let source, !exactSeconds.contains(second) else { return }
        let request = revision
        let delay = refineDelay
        refineTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.revision == request, self.requestedSecond == second,
                  self.task == nil else { return }
            let data = await refine(source, second)
            guard !Task.isCancelled, self.revision == request,
                  let data, let image = NSImage(data: data) else { return }
            self.store(image, for: second, exact: true)
            if self.requestedSecond == second {
                self.image = image
                self.imageSecond = second
            }
        }
    }

    private func cancelRefine() {
        refineTask?.cancel()
        refineTask = nil
    }

    private func store(_ image: NSImage, for second: Double, exact: Bool) {
        cache[second] = image
        if exact { exactSeconds.insert(second) }
        touchCache(second)
        if cacheOrder.count > 120 {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
            exactSeconds.remove(evicted)
        }
    }

    private func touchCache(_ second: Double) {
        cacheOrder.removeAll { $0 == second }
        cacheOrder.append(second)
    }
}
