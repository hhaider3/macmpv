import AppKit
import CMPV
import Foundation

@MainActor
final class MPVEngine {
    enum TrackKind: String, Sendable {
        case audio
        case subtitle = "sub"

        var propertyName: String {
            switch self {
            case .audio: "aid"
            case .subtitle: "sid"
            }
        }
    }

    struct MediaTrack: Identifiable, Hashable, Sendable {
        let id: String
        let kind: TrackKind
        let title: String?
        let language: String?
        let codec: String?
        var isSelected: Bool

        var displayName: String {
            let fallback = kind == .audio ? "Audio \(id)" : "Subtitle \(id)"
            let primary = title ?? language?.uppercased() ?? fallback
            guard let codec, !codec.isEmpty else { return primary }
            return "\(primary) · \(codec.uppercased())"
        }
    }

    enum Event: Sendable {
        case fileLoaded
        case endFile(error: String?)
        case shutdown
    }

    struct Snapshot: Equatable {
        var position: Double
        var duration: Double
        var paused: Bool
        var muted: Bool
        var volume: Double
        var speed: Double
        var eofReached: Bool
        var title: String?
    }

    private(set) var handle: OpaquePointer?
    private(set) var renderContext: OpaquePointer?
    private(set) var lastError: String?

    var isReady: Bool {
        handle != nil && renderContext != nil
    }

    /// Called on MainActor when a lifecycle event arrives.
    var onEvent: ((Event) -> Void)?
    /// Called on MainActor only when one of the eight observed properties actually changes.
    var onSnapshot: ((Snapshot) -> Void)?
    /// Called on MainActor when mpv signals a new video frame is available via
    /// `mpv_render_context_set_update_callback`.
    var onRenderUpdate: (() -> Void)?

    // MARK: - Event queue

    private let eventQueue = DispatchQueue(label: "local.macmpv.eventQueue", qos: .userInitiated)
    nonisolated(unsafe) private var shouldRunEventLoop = false
    private let eventLoopLock = NSLock()
    nonisolated(unsafe) private var bgSnapshot = Snapshot(position: 0, duration: 0, paused: true, muted: false, volume: 80, speed: 1, eofReached: false, title: nil)
    nonisolated(unsafe) private var bgLastEmitted: Snapshot?

    nonisolated private var shouldKeepRunning: Bool {
        get { eventLoopLock.lock(); defer { eventLoopLock.unlock() }; return shouldRunEventLoop }
        set { eventLoopLock.lock(); shouldRunEventLoop = newValue; eventLoopLock.unlock() }
    }

    // MARK: - Render callback

    fileprivate static let renderUpdateCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
        guard let data else { return }
        let engine = Unmanaged<MPVEngine>.fromOpaque(data).takeUnretainedValue()
        Task { @MainActor in
            engine.onRenderUpdate?()
        }
    }

    func start() -> Bool {
        guard handle == nil else { return isReady }
        guard let newHandle = cinewave_mpv_create() else {
            lastError = "Could not create an mpv playback instance."
            return false
        }
        handle = newHandle

        var options: [(String, String)] = [
            ("config", "no"),
            ("vo", "libmpv"),
            ("hwdec", "auto-copy-safe"),
            ("hr-seek-framedrop", "yes"),
            ("demuxer-readahead-secs", "20"),
            ("demuxer-max-bytes", "268435456"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("osc", "no"),
            ("input-default-bindings", "no"),
            ("terminal", "no"),
            ("msg-level", "all=warn"),
            ("audio-client-name", "macmpv"),
            ("sub-auto", "fuzzy"),
            ("alang", "auto"),
            ("slang", "auto")
        ]

        let environment = ProcessInfo.processInfo.environment
        if let ipcPath = environment["MACMPV_MPV_IPC"], !ipcPath.isEmpty {
            options.append(("input-ipc-server", ipcPath))
        }
        if let logPath = environment["MACMPV_MPV_LOG"], !logPath.isEmpty {
            options.append(("log-file", logPath))
        }
        if let ipcPath = Self.diagnosticArgument(named: "--macmpv-ipc") {
            options.append(("input-ipc-server", ipcPath))
        }
        if let logPath = Self.diagnosticArgument(named: "--macmpv-log") {
            options.append(("log-file", logPath))
        }

        for (name, value) in options {
            let result = cinewave_mpv_set_option_string(newHandle, name, value)
            if result < 0 {
                lastError = Self.errorMessage(result, context: "Setting mpv option “\(name)”")
            }
        }

        let initializeResult = cinewave_mpv_initialize(newHandle)
        guard initializeResult >= 0 else {
            lastError = Self.errorMessage(initializeResult, context: "Starting mpv")
            cinewave_mpv_destroy(newHandle)
            handle = nil
            return false
        }

        var context: OpaquePointer?
        let renderResult = cinewave_mpv_render_create(&context, newHandle)
        guard renderResult >= 0, let context else {
            lastError = Self.errorMessage(renderResult, context: "Creating the video renderer")
            cinewave_mpv_destroy(newHandle)
            handle = nil
            return false
        }

        renderContext = context
        lastError = nil

        startObserving(handle: newHandle, renderContext: context)
        return true
    }

    func shutdown() {
        let wasRunning = shouldKeepRunning
        stopObserving()
        // Synchronize with the dedicated event queue before destroying the handle.
        // libmpv forbids concurrent calls during mpv_terminate_destroy; the loop may
        // still be blocked in mpv_wait_event, so wake it and wait for the queue to drain.
        if wasRunning {
            // Enqueue a barrier after the running runEventLoop block. The barrier
            // will not execute until runEventLoop has observed shouldKeepRunning == false,
            // returned from mpv_wait_event (woken above), and exited.
            let barrier = DispatchSemaphore(value: 0)
            eventQueue.async { barrier.signal() }
            // mpv_wakeup guarantees the blocking wait returns. Do not destroy the
            // handle until the queue confirms that no client call is still using it.
            barrier.wait()
        }
        if let renderContext {
            // Clear update callback before freeing.
            cinewave_mpv_render_set_update_callback(renderContext, nil, nil)
            cinewave_mpv_render_free(renderContext)
            self.renderContext = nil
        }
        if let handle {
            cinewave_mpv_destroy(handle)
            self.handle = nil
        }
        bgLastEmitted = nil
        bgSnapshot = Snapshot(position: 0, duration: 0, paused: true, muted: false, volume: 80, speed: 1, eofReached: false, title: nil)
    }

    // MARK: - Observe + event loop

    private func startObserving(handle: OpaquePointer, renderContext: OpaquePointer) {
        // Eight properties: position, duration, paused, muted, volume, speed, eofReached, media-title
        let fmtDouble = cinewave_mpv_format_double()
        let fmtFlag = cinewave_mpv_format_flag()
        let fmtString = cinewave_mpv_format_string()
        _ = cinewave_mpv_observe_property(handle, 1, "time-pos", fmtDouble)
        _ = cinewave_mpv_observe_property(handle, 2, "duration", fmtDouble)
        _ = cinewave_mpv_observe_property(handle, 3, "pause", fmtFlag)
        _ = cinewave_mpv_observe_property(handle, 4, "mute", fmtFlag)
        _ = cinewave_mpv_observe_property(handle, 5, "volume", fmtDouble)
        _ = cinewave_mpv_observe_property(handle, 6, "speed", fmtDouble)
        _ = cinewave_mpv_observe_property(handle, 7, "eof-reached", fmtFlag)
        _ = cinewave_mpv_observe_property(handle, 8, "media-title", fmtString)

        let unmanaged = Unmanaged.passUnretained(self).toOpaque()
        cinewave_mpv_render_set_update_callback(renderContext, Self.renderUpdateCallback, unmanaged)

        shouldKeepRunning = true

        // Prime bgSnapshot on the event queue so all bgSnapshot / bgLastEmitted
        // mutations are serialized on eventQueue (only background thread touches them after this point).
        let handleBits = UInt(bitPattern: handle)
        eventQueue.async { [weak self] in
            guard let self else { return }
            guard let handle = OpaquePointer(bitPattern: handleBits) else { return }
            self.bgSnapshot = Snapshot(
                position: cinewave_mpv_get_double(handle, "time-pos", 0),
                duration: cinewave_mpv_get_double(handle, "duration", 0),
                paused: cinewave_mpv_get_flag(handle, "pause", 1) != 0,
                muted: cinewave_mpv_get_flag(handle, "mute", 0) != 0,
                volume: cinewave_mpv_get_double(handle, "volume", 80),
                speed: cinewave_mpv_get_double(handle, "speed", 1),
                eofReached: cinewave_mpv_get_flag(handle, "eof-reached", 0) != 0,
                title: self.stringPropertySync(handle, name: "media-title")
            )
            self.bgLastEmitted = nil
            let initial = self.bgSnapshot
            if self.bgLastEmitted != initial {
                self.bgLastEmitted = initial
                Task { @MainActor in self.onSnapshot?(initial) }
            }
            self.runEventLoop(handle: handle)
        }
    }

    private func stopObserving() {
        guard shouldKeepRunning else { return }
        shouldKeepRunning = false
        if let handle {
            cinewave_mpv_wakeup(handle)
        }
        if let renderContext {
            cinewave_mpv_render_set_update_callback(renderContext, nil, nil)
        }
    }

    nonisolated private func runEventLoop(handle: OpaquePointer) {
        while shouldKeepRunning {
            guard let event = cinewave_mpv_wait_event(handle, -1) else { continue }
            let eid = cinewave_mpv_event_id(event)
            if eid == cinewave_mpv_event_none() { continue }

            if eid == cinewave_mpv_event_property_change() {
                let userdata = cinewave_mpv_event_reply_userdata(event)
                handlePropertyChange(userdata: userdata, handle: handle, event: event)
                continue
            }

            if eid == cinewave_mpv_event_file_loaded() {
                Task { @MainActor [weak self] in self?.onEvent?(.fileLoaded) }
            } else if eid == cinewave_mpv_event_end_file() {
                let errorCode = cinewave_mpv_event_end_file_error(event)
                let error = errorCode < 0
                    ? cinewave_mpv_error_string(errorCode).map(String.init(cString:))
                    : nil
                Task { @MainActor [weak self] in self?.onEvent?(.endFile(error: error)) }
            } else if eid == cinewave_mpv_event_shutdown() {
                Task { @MainActor [weak self] in self?.onEvent?(.shutdown) }
                shouldKeepRunning = false
                break
            }
        }
    }

    nonisolated private func handlePropertyChange(userdata: UInt64, handle: OpaquePointer, event: UnsafePointer<mpv_event>) {
        var changed = false
        switch userdata {
        case 1:
            let v = cinewave_mpv_get_double(handle, "time-pos", bgSnapshot.position)
            if v != bgSnapshot.position { bgSnapshot.position = v; changed = true }
        case 2:
            let v = cinewave_mpv_get_double(handle, "duration", bgSnapshot.duration)
            if v != bgSnapshot.duration { bgSnapshot.duration = v; changed = true }
        case 3:
            let v = cinewave_mpv_get_flag(handle, "pause", bgSnapshot.paused ? 1 : 0) != 0
            if v != bgSnapshot.paused { bgSnapshot.paused = v; changed = true }
        case 4:
            let v = cinewave_mpv_get_flag(handle, "mute", bgSnapshot.muted ? 1 : 0) != 0
            if v != bgSnapshot.muted { bgSnapshot.muted = v; changed = true }
        case 5:
            let v = cinewave_mpv_get_double(handle, "volume", bgSnapshot.volume)
            if v != bgSnapshot.volume { bgSnapshot.volume = v; changed = true }
        case 6:
            let v = cinewave_mpv_get_double(handle, "speed", bgSnapshot.speed)
            if v != bgSnapshot.speed { bgSnapshot.speed = v; changed = true }
        case 7:
            let v = cinewave_mpv_get_flag(handle, "eof-reached", bgSnapshot.eofReached ? 1 : 0) != 0
            if v != bgSnapshot.eofReached { bgSnapshot.eofReached = v; changed = true }
        case 8:
            let v = stringPropertySync(handle, name: "media-title")
            if v != bgSnapshot.title { bgSnapshot.title = v; changed = true }
        default:
            // Unknown userdata — inspect the current event without consuming the next one.
            if let cname = cinewave_mpv_property_name(event) {
                _ = cname
            }
            return
        }

        if changed {
            // Publish only if snapshot actually differs from last emitted.
            if bgLastEmitted != bgSnapshot {
                let snap = bgSnapshot
                bgLastEmitted = snap
                Task { @MainActor [weak self] in
                    self?.onSnapshot?(snap)
                }
            }
        }
    }

    nonisolated private func stringPropertySync(_ handle: OpaquePointer, name: String) -> String? {
        guard let value = cinewave_mpv_get_string(handle, name) else { return nil }
        defer { cinewave_mpv_free(value) }
        return String(cString: value)
    }

    // MARK: - Playback commands (MainActor)

    func load(_ url: URL) -> Bool {
        guard let handle else { return false }
        let source = url.isFileURL ? url.path : url.absoluteString
        let result = cinewave_mpv_command_3(handle, "loadfile", source, "replace")
        if result < 0 {
            lastError = Self.errorMessage(result, context: "Opening \(url.lastPathComponent)")
            return false
        }
        lastError = nil
        return true
    }

    func stop() {
        command("stop")
    }

    func togglePause() {
        guard let handle else { return }
        let paused = cinewave_mpv_get_flag(handle, "pause", 0) != 0
        _ = cinewave_mpv_set_flag(handle, "pause", paused ? 0 : 1)
    }

    func setPaused(_ paused: Bool) {
        guard let handle else { return }
        _ = cinewave_mpv_set_flag(handle, "pause", paused ? 1 : 0)
    }

    func seek(relative seconds: Double) {
        guard let handle else { return }
        _ = cinewave_mpv_command_3(handle, "seek", String(seconds), "relative+exact")
    }

    func seek(absolute seconds: Double) {
        guard let handle else { return }
        _ = cinewave_mpv_command_3(handle, "seek", String(max(0, seconds)), "absolute+exact")
    }

    func previewSeek(absolute seconds: Double) {
        guard let handle else { return }
        _ = cinewave_mpv_command_3(handle, "seek", String(max(0, seconds)), "absolute+keyframes")
    }

    func setVolume(_ value: Double) {
        guard let handle else { return }
        _ = cinewave_mpv_set_double(handle, "volume", min(max(value, 0), 100))
    }

    func setMuted(_ muted: Bool) {
        guard let handle else { return }
        _ = cinewave_mpv_set_flag(handle, "mute", muted ? 1 : 0)
    }

    func setSpeed(_ speed: Double) {
        guard let handle else { return }
        _ = cinewave_mpv_set_double(handle, "speed", min(max(speed, 0.25), 4))
    }

    func availableTracks(kind: TrackKind) -> [MediaTrack] {
        guard let handle else { return [] }
        let count = Int(cinewave_mpv_get_int64(handle, "track-list/count", 0))
        guard count > 0 else { return [] }

        return (0..<count).compactMap { index in
            let prefix = "track-list/\(index)"
            guard stringProperty("\(prefix)/type") == kind.rawValue,
                  let id = stringProperty("\(prefix)/id") else { return nil }
            return MediaTrack(
                id: id,
                kind: kind,
                title: stringProperty("\(prefix)/title"),
                language: stringProperty("\(prefix)/lang"),
                codec: stringProperty("\(prefix)/codec"),
                isSelected: cinewave_mpv_get_flag(handle, "\(prefix)/selected", 0) != 0
            )
        }
    }

    func selectTrack(_ track: MediaTrack?) {
        guard let handle else { return }
        let kind = track?.kind ?? .subtitle
        _ = cinewave_mpv_set_string(handle, kind.propertyName, track?.id ?? "no")
    }

    func addExternalSubtitle(_ url: URL) -> Bool {
        guard let handle else { return false }
        let result = cinewave_mpv_command_3(handle, "sub-add", url.path, "select")
        if result < 0 {
            lastError = Self.errorMessage(result, context: "Adding subtitles")
            return false
        }
        lastError = nil
        return true
    }

    func saveScreenshot(to url: URL) -> Bool {
        guard let handle else { return false }
        let result = cinewave_mpv_command_3(handle, "screenshot-to-file", url.path, "video")
        if result < 0 {
            lastError = Self.errorMessage(result, context: "Saving screenshot")
            return false
        }
        lastError = nil
        return true
    }

    func cycleAudioTrack() {
        command("cycle", "audio")
    }

    func cycleSubtitleTrack() {
        command("cycle", "sub")
    }

    func frameStep() {
        command("frame-step")
    }

    /// Synchronous snapshot for callers that need an immediate read (e.g. tests).
    /// The event-driven path uses `onSnapshot` instead — this reads directly from mpv
    /// and does not touch the background queue's cached snapshot.
    func snapshot() -> Snapshot? {
        guard let handle else { return nil }
        return Snapshot(
            position: cinewave_mpv_get_double(handle, "time-pos", 0),
            duration: cinewave_mpv_get_double(handle, "duration", 0),
            paused: cinewave_mpv_get_flag(handle, "pause", 1) != 0,
            muted: cinewave_mpv_get_flag(handle, "mute", 0) != 0,
            volume: cinewave_mpv_get_double(handle, "volume", 80),
            speed: cinewave_mpv_get_double(handle, "speed", 1),
            eofReached: cinewave_mpv_get_flag(handle, "eof-reached", 0) != 0,
            title: stringProperty("media-title")
        )
    }

    /// Kept for compatibility; with the event-queue architecture new events arrive
    /// via `onEvent`. This drains any pending non-blocking events as a fallback.
    func drainEvents() -> [Event] {
        guard let handle else { return [] }
        var events: [Event] = []
        while true {
            let event = cinewave_mpv_next_event(handle)
            if event == cinewave_mpv_event_none() { break }
            if event == cinewave_mpv_event_file_loaded() {
                events.append(.fileLoaded)
            } else if event == cinewave_mpv_event_end_file() {
                events.append(.endFile(error: nil))
            } else if event == cinewave_mpv_event_shutdown() {
                events.append(.shutdown)
            }
        }
        return events
    }

    func rendererNeedsFrame() -> Bool {
        guard let renderContext else { return false }
        let flags = cinewave_mpv_render_update(renderContext)
        return cinewave_mpv_render_has_frame(flags) != 0
    }

    func render(framebuffer: Int32, width: Int32, height: Int32) {
        guard let renderContext, width > 0, height > 0 else { return }
        cinewave_mpv_render_frame(renderContext, framebuffer, width, height)
    }

    func reportSwap() {
        guard let renderContext else { return }
        cinewave_mpv_render_report_swap(renderContext)
    }

    private func command(_ first: String, _ second: String? = nil) {
        guard let handle else { return }
        if let second {
            _ = cinewave_mpv_command_2(handle, first, second)
        } else {
            _ = cinewave_mpv_command_1(handle, first)
        }
    }

    private func stringProperty(_ name: String) -> String? {
        guard let handle, let value = cinewave_mpv_get_string(handle, name) else { return nil }
        defer { cinewave_mpv_free(value) }
        return String(cString: value)
    }

    private static func errorMessage(_ code: Int32, context: String) -> String {
        let detail = cinewave_mpv_error_string(code).map(String.init(cString:)) ?? "Unknown error"
        return "\(context) failed: \(detail)"
    }

    private static func diagnosticArgument(named name: String) -> String? {
        let prefix = name + "="
        return CommandLine.arguments
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
    }
}
