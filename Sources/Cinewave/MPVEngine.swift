import AppKit
import CMPV

@MainActor
final class MPVEngine {
    enum Event {
        case fileLoaded
        case endFile
        case shutdown
    }

    struct Snapshot {
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
            // Copy-back avoids invalid VideoToolbox textures after random seeks
            // while retaining hardware decode for demanding media.
            ("hwdec", "auto-copy-safe"),
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

        // Opt-in diagnostics used by local playback smoke tests. Normal app
        // launches expose no IPC socket and write no mpv log file.
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
        return true
    }

    func shutdown() {
        if let renderContext {
            cinewave_mpv_render_free(renderContext)
            self.renderContext = nil
        }
        if let handle {
            cinewave_mpv_destroy(handle)
            self.handle = nil
        }
    }

    func load(_ url: URL) -> Bool {
        guard let handle else { return false }
        configureDecoder(for: url, handle: handle)
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

    func cycleAudioTrack() {
        command("cycle", "audio")
    }

    func cycleSubtitleTrack() {
        command("cycle", "sub")
    }

    func frameStep() {
        command("frame-step")
    }

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

    func drainEvents() -> [Event] {
        guard let handle else { return [] }
        var events: [Event] = []
        while true {
            let event = cinewave_mpv_next_event(handle)
            if event == cinewave_mpv_event_none() { break }
            if event == cinewave_mpv_event_file_loaded() {
                events.append(.fileLoaded)
            } else if event == cinewave_mpv_event_end_file() {
                events.append(.endFile)
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

    private func command(_ first: String, _ second: String? = nil) {
        guard let handle else { return }
        if let second {
            _ = cinewave_mpv_command_2(handle, first, second)
        } else {
            _ = cinewave_mpv_command_1(handle, first)
        }
    }

    private func configureDecoder(for url: URL, handle: OpaquePointer) {
        // H.264 in AVI commonly lacks the timestamp/extradata guarantees that
        // VideoToolbox expects after an arbitrary seek. Software decode is
        // inexpensive for these typically older files and avoids blue frames.
        let hardwareMode = url.pathExtension.lowercased() == "avi"
            ? "no"
            : "auto-copy-safe"
        _ = cinewave_mpv_set_string(handle, "hwdec", hardwareMode)
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
