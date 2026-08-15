import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class PlayerModel {
    private struct PlaybackMarkers: Codable {
        var introEnd: Double?
        var outroStart: Double?
    }

    enum RepeatMode: String, CaseIterable {
        case off
        case all
        case one

        var symbol: String {
            switch self {
            case .off, .all: "repeat"
            case .one: "repeat.1"
            }
        }

        var label: String {
            switch self {
            case .off: "Repeat Off"
            case .all: "Repeat All"
            case .one: "Repeat One"
            }
        }

        mutating func advance() {
            switch self {
            case .off: self = .all
            case .all: self = .one
            case .one: self = .off
            }
        }
    }

    var queue: [MediaItem] = []
    var currentID: UUID?
    var position: Double = 0
    var duration: Double = 0
    var isPlaying = false
    var isMuted = false
    var volume: Double = 80
    var speed: Double = 1
    var repeatMode: RepeatMode = .off
    var isSidebarVisible = false
    var isLoading = false
    var errorMessage: String?
    var engineTitle: String?
    var audioTracks: [MPVEngine.MediaTrack] = []
    var subtitleTracks: [MPVEngine.MediaTrack] = []
    var introEndMarker: Double?
    var outroStartMarker: Double?

    struct SubtitleSettings: Codable, Equatable {
        var scale: Double = 1
        var outlineSize: Double = 1.65
        var bold = false
        var delay: Double = 0
        var textColorHex: String = "#FFFFFF"
        var backgroundOpacity: Double = 0
    }

    var subtitleSettings = SubtitleSettings()
    /// True while the subtitle settings popover is showing; the fullscreen
    /// control zone stays visible for as long as it is open.
    var isSubtitleSettingsPresented = false

    @ObservationIgnored let engine = MPVEngine()
    @ObservationIgnored private let probe = MediaProbe()
    @ObservationIgnored private let magnetStream = MagnetStream()
    @ObservationIgnored private weak var videoView: MPVGLView?
    @ObservationIgnored private var ignoreNextEndEvent = false
    @ObservationIgnored private var didReadLaunchArguments = false
    @ObservationIgnored private var previewSeekTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPreviewPosition: Double?
    @ObservationIgnored private var lastPreviewSeekUptime: TimeInterval = -.infinity
    @ObservationIgnored private var wasPlayingBeforeScrub = false
    @ObservationIgnored private var pendingResumePosition: Double?
    @ObservationIgnored private var rememberedPositions: [String: Double] = [:]
    @ObservationIgnored private var rememberedMarkers: [String: PlaybackMarkers] = [:]
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var controlsOverlayVisible = true
    /// Height of the bottom controls (including their bottom padding), measured
    /// by the view that renders them; 0 while the overlay is hidden.
    @ObservationIgnored private var controlsBottomInset: Double = 0

    private let previewSeekInterval: TimeInterval = 0.18
    private static let positionsDefaultsKey = "playback.positions.v1"
    private static let markersDefaultsKey = "playback.markers.v1"
    private static let subtitleSettingsKey = "subtitles.settings.v1"

    var currentItem: MediaItem? {
        guard let currentID else { return nil }
        return queue.first(where: { $0.id == currentID })
    }

    var currentMetadata: MediaMetadata? {
        currentItem?.metadata
    }

    var displayTitle: String {
        engineTitle ?? currentItem?.title ?? "macmpv"
    }

    var hasMedia: Bool {
        currentID != nil
    }

    var canGoNext: Bool {
        guard let index = currentIndex else { return false }
        return index < queue.count - 1 || repeatMode == .all
    }

    var canGoPrevious: Bool {
        guard let index = currentIndex else { return false }
        return index > 0 || repeatMode == .all || position > 3
    }

    private var currentIndex: Int? {
        guard let currentID else { return nil }
        return queue.firstIndex(where: { $0.id == currentID })
    }

    init() {
        let storedVolume = UserDefaults.standard.object(forKey: "player.volume") as? Double
        volume = storedVolume.map { min(max($0, 0), 100) } ?? 80
        rememberedPositions = Self.load([String: Double].self, key: Self.positionsDefaultsKey) ?? [:]
        rememberedMarkers = Self.load([String: PlaybackMarkers].self, key: Self.markersDefaultsKey) ?? [:]
        subtitleSettings = Self.load(SubtitleSettings.self, key: Self.subtitleSettingsKey) ?? SubtitleSettings()
    }

    func attachVideoView(_ view: MPVGLView) {
        if let existingView = videoView, existingView !== view {
            existingView.stopPlaybackEngine()
        }
        videoView = view
        view.onViewGeometryChanged = { [weak self] in
            self?.updateSubtitlePosition()
        }
        guard view.startPlaybackEngine() else {
            errorMessage = engine.lastError ?? "The mpv video engine could not start."
            return
        }
        engine.setVolume(volume)
        updateSubtitlePosition()
        applySubtitleSettings()
        bindEngineCallbacks()
        if currentID != nil {
            loadCurrentItem()
        }
    }

    func detachVideoView(_ view: MPVGLView) {
        guard videoView === view else { return }
        rememberCurrentProgress(saveImmediately: true)
        magnetStream.stop()
        view.onViewGeometryChanged = nil
        view.stopPlaybackEngine()
        videoView = nil
        // Tear down event-driven callbacks and reset transient UI state.
        engine.onEvent = nil
        engine.onSnapshot = nil
        isLoading = false
        isPlaying = false
    }

    private func bindEngineCallbacks() {
        engine.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .fileLoaded:
                self.ignoreNextEndEvent = false
                self.isLoading = false
                self.refreshTracks()
                // Video geometry is known once the file loads; subtitle clearance
                // depends on the letterboxed video rect.
                self.updateSubtitlePosition()
                if let resumePosition = self.pendingResumePosition, resumePosition > 5 {
                    self.engine.seek(absolute: resumePosition)
                    self.position = resumePosition
                }
                self.pendingResumePosition = nil
            case .endFile(let error):
                if self.ignoreNextEndEvent {
                    self.ignoreNextEndEvent = false
                } else {
                    self.isLoading = false
                    self.isPlaying = false
                    if let error {
                        self.magnetStream.stop()
                        self.errorMessage = "Playback failed: \(error)"
                    } else {
                        self.handlePlaybackEnded()
                    }
                }
            case .shutdown:
                self.magnetStream.stop()
                self.isPlaying = false
                self.isLoading = false
            }
        }

        engine.onSnapshot = { [weak self] snapshot in
            guard let self, self.hasMedia else { return }
            // Ignore positional snapshots from the item being replaced until the
            // new file-loaded event arrives.
            if !self.isLoading {
                self.position = snapshot.position
                if snapshot.duration > 0 {
                    self.duration = snapshot.duration
                }
                self.rememberCurrentProgress(saveImmediately: false)
            }
            self.isPlaying = !snapshot.paused && !snapshot.eofReached
            self.isMuted = snapshot.muted
            self.volume = snapshot.volume
            self.speed = snapshot.speed
            self.engineTitle = snapshot.title
        }
    }

    func openLaunchArgumentsIfNeeded() {
        guard !didReadLaunchArguments else { return }
        didReadLaunchArguments = true
        let urls = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("--macmpv-") }
            .compactMap { argument -> URL? in
            if let remote = URL(string: argument), !remote.isFileURL, remote.scheme != nil {
                return remote
            }
            return URL(fileURLWithPath: argument)
        }
        if !urls.isEmpty {
            enqueue(urls, playFirst: true)
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open media"
        panel.message = "Choose one or more video or audio files"
        panel.prompt = "Open"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        var contentTypes: [UTType] = [.audiovisualContent, .movie, .audio]
        if let magnetType = UTType(filenameExtension: "magnet") {
            contentTypes.append(magnetType)
        }
        if let torrentType = UTType(filenameExtension: "torrent") {
            contentTypes.append(torrentType)
        }
        panel.allowedContentTypes = contentTypes
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.enqueue(panel.urls, playFirst: true)
        }
    }

    func enqueue(_ urls: [URL], playFirst: Bool) {
        let playable = urls.filter(MediaSupport.isPlayable)
        guard !playable.isEmpty else {
            errorMessage = "No supported media files were found."
            return
        }

        var added: [MediaItem] = []
        for url in playable {
            if let existing = queue.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                added.append(existing)
                continue
            }
            let item = MediaItem(url: url)
            queue.append(item)
            added.append(item)
            inspect(item)
        }

        if currentID == nil || playFirst, let first = added.first {
            play(first)
        }
    }

    func openNetworkURL(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), MediaSupport.isPlayable(url) else {
            errorMessage = "Enter a valid HTTP, HTTPS, RTMP, RTSP, or magnet URL."
            return
        }
        enqueue([url], playFirst: true)
    }

    func play(_ item: MediaItem) {
        guard queue.contains(where: { $0.id == item.id }) else { return }
        rememberCurrentProgress(saveImmediately: true)
        let isReplacingCurrentItem = currentID != nil
        currentID = item.id
        position = 0
        duration = item.metadata?.duration ?? 0
        engineTitle = nil
        isLoading = true
        ignoreNextEndEvent = isReplacingCurrentItem
        let key = persistenceKey(for: item.url)
        pendingResumePosition = MediaSupport.isTorrentSource(item.url) ? nil : rememberedPositions[key]
        let markers = rememberedMarkers[key]
        introEndMarker = markers?.introEnd
        outroStartMarker = markers?.outroStart
        audioTracks = []
        subtitleTracks = []
        loadCurrentItem()
    }

    func togglePlayback() {
        guard hasMedia else {
            openPanel()
            return
        }
        if engine.togglePause() {
            isPlaying.toggle()
        } else if let detail = engine.lastError {
            errorMessage = detail
        }
    }

    func playPause(_ shouldPlay: Bool) {
        guard hasMedia else { return }
        if engine.setPaused(!shouldPlay) {
            isPlaying = shouldPlay
        } else if let detail = engine.lastError {
            errorMessage = detail
        }
    }

    func seek(relative seconds: Double) {
        guard hasMedia else { return }
        engine.seek(relative: seconds)
        position = min(max(position + seconds, 0), max(duration, 0))
    }

    func seek(to seconds: Double) {
        guard hasMedia else { return }
        cancelPendingPreviewSeek()
        position = min(max(seconds, 0), max(duration, 0))
        engine.seek(absolute: position)
    }

    func beginScrubbing() {
        guard hasMedia else { return }
        cancelPendingPreviewSeek()
        wasPlayingBeforeScrub = isPlaying
        if wasPlayingBeforeScrub {
            if engine.setPaused(true) {
                isPlaying = false
            } else {
                wasPlayingBeforeScrub = false
            }
        }
    }

    func previewSeek(to seconds: Double) {
        guard hasMedia else { return }
        let target = min(max(seconds, 0), max(duration, 0))
        position = target
        pendingPreviewPosition = target

        guard previewSeekTask == nil else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastPreviewSeekUptime
        let delay = max(0, previewSeekInterval - elapsed)
        if delay == 0 {
            flushPreviewSeek()
            return
        }

        previewSeekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
            guard !Task.isCancelled else { return }
            self?.flushPreviewSeek()
        }
    }

    func endScrubbing(at seconds: Double) {
        seek(to: seconds)
        if wasPlayingBeforeScrub {
            if engine.setPaused(false) {
                isPlaying = true
            }
        }
        wasPlayingBeforeScrub = false
    }

    func goNext() {
        guard let index = currentIndex, !queue.isEmpty else { return }
        if index + 1 < queue.count {
            play(queue[index + 1])
        } else if repeatMode == .all {
            play(queue[0])
        }
    }

    func goPrevious() {
        guard let index = currentIndex, !queue.isEmpty else { return }
        if position > 3 {
            seek(to: 0)
        } else if index > 0 {
            play(queue[index - 1])
        } else if repeatMode == .all {
            play(queue[queue.count - 1])
        }
    }

    func setVolume(_ newValue: Double) {
        volume = min(max(newValue, 0), 100)
        engine.setVolume(volume)
        UserDefaults.standard.set(volume, forKey: "player.volume")
        if volume > 0, isMuted {
            setMuted(false)
        }
    }

    func adjustVolume(by delta: Double) {
        setVolume(volume + delta)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        engine.setMuted(muted)
    }

    func toggleMuted() {
        setMuted(!isMuted)
    }

    func setSpeed(_ newSpeed: Double) {
        speed = min(max(newSpeed, 0.25), 4)
        engine.setSpeed(speed)
    }

    func adjustSpeed(by delta: Double) {
        setSpeed((speed + delta).rounded(toPlaces: 2))
    }

    func resetSpeed() {
        setSpeed(1)
    }

    func cycleRepeatMode() {
        repeatMode.advance()
    }

    func selectAudioTrack(_ track: MPVEngine.MediaTrack) {
        engine.selectTrack(track)
        audioTracks = audioTracks.map { item in
            var item = item
            item.isSelected = item.id == track.id
            return item
        }
    }

    func selectSubtitleTrack(_ track: MPVEngine.MediaTrack?) {
        engine.selectTrack(track)
        subtitleTracks = subtitleTracks.map { item in
            var item = item
            item.isSelected = item.id == track?.id
            return item
        }
    }

    func openSubtitlePanel() {
        guard hasMedia else { return }
        let panel = NSOpenPanel()
        panel.title = "Open subtitles"
        panel.message = "Choose an SRT, ASS, SSA, or WebVTT subtitle file"
        panel.prompt = "Open Subtitle"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt", "sub"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard self.engine.addExternalSubtitle(url) else {
                self.errorMessage = self.engine.lastError ?? "The subtitle file could not be opened."
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                self?.refreshTracks()
            }
        }
    }

    func takeScreenshot() {
        guard hasMedia else { return }
        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = screenshotFilename()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if !self.engine.saveScreenshot(to: url) {
                self.errorMessage = self.engine.lastError ?? "The screenshot could not be saved."
            }
        }
    }

    func setIntroEndMarker() {
        guard hasMedia else { return }
        introEndMarker = position
        saveCurrentMarkers()
    }

    func setOutroStartMarker() {
        guard hasMedia else { return }
        outroStartMarker = position
        saveCurrentMarkers()
    }

    func clearPlaybackMarkers() {
        guard let currentItem else { return }
        introEndMarker = nil
        outroStartMarker = nil
        rememberedMarkers.removeValue(forKey: persistenceKey(for: currentItem.url))
        persistStores()
    }

    func skipIntro() {
        guard let introEndMarker else { return }
        seek(to: introEndMarker)
    }

    func skipOutro() {
        guard outroStartMarker != nil else { return }
        if canGoNext {
            goNext()
        } else {
            seek(to: duration)
            playPause(false)
        }
    }

    func moveQueueItem(id: UUID, before destinationID: UUID) {
        guard id != destinationID,
              let sourceIndex = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue.remove(at: sourceIndex)
        guard let destinationIndex = queue.firstIndex(where: { $0.id == destinationID }) else {
            queue.insert(item, at: min(sourceIndex, queue.count))
            return
        }
        queue.insert(item, at: destinationIndex)
    }

    func remove(_ item: MediaItem) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
        let wasCurrent = item.id == currentID
        if wasCurrent {
            rememberCurrentProgress(saveImmediately: true)
        }
        queue.remove(at: index)
        guard wasCurrent else { return }

        if queue.isEmpty {
            magnetStream.stop()
            currentID = nil
            engineTitle = nil
            position = 0
            duration = 0
            isPlaying = false
            engine.stop()
        } else {
            play(queue[min(index, queue.count - 1)])
        }
    }

    func clearQueue() {
        rememberCurrentProgress(saveImmediately: true)
        magnetStream.stop()
        queue.removeAll()
        currentID = nil
        engineTitle = nil
        position = 0
        duration = 0
        isPlaying = false
        audioTracks = []
        subtitleTracks = []
        introEndMarker = nil
        outroStartMarker = nil
        engine.stop()
    }

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    func dismissError() {
        errorMessage = nil
    }

    func reportVideoSurfaceFailure() {
        isLoading = false
        errorMessage = "No OpenGL surface is available, so video playback cannot start on this system."
    }

    func setControlsOverlayVisible(_ visible: Bool) {
        guard controlsOverlayVisible != visible else { return }
        controlsOverlayVisible = visible
        updateSubtitlePosition()
    }
    func setControlsBottomInset(_ inset: Double) {
        let clamped = max(0, inset)
        guard controlsBottomInset != clamped else { return }
        controlsBottomInset = clamped
        updateSubtitlePosition()
    }

    func applySubtitleSettings() {
        let settings = subtitleSettings
        engine.setSubtitleScale(settings.scale)
        engine.setSubtitleOutlineSize(settings.outlineSize)
        engine.setSubtitleBold(settings.bold)
        engine.setSubtitleDelay(settings.delay)
        let (red, green, blue) = Self.rgbComponents(fromHex: settings.textColorHex)
        engine.setSubtitleTextColor(String(format: "%.3f/%.3f/%.3f/1.0", red, green, blue))
        engine.setSubtitleBackground(String(format: "0.0/0.0/0.0/%.3f", settings.backgroundOpacity))
        if let data = try? JSONEncoder().encode(subtitleSettings) {
            UserDefaults.standard.set(data, forKey: Self.subtitleSettingsKey)
        }
    }

    func resetSubtitleSettings() {
        subtitleSettings = SubtitleSettings()
        applySubtitleSettings()
    }

    static func color(fromHex hex: String) -> Color {
        let (red, green, blue) = rgbComponents(fromHex: hex)
        return Color(red: red, green: green, blue: blue)
    }

    static func hex(from color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(
            format: "#%02X%02X%02X",
            Int((nsColor.redComponent * 255).rounded()),
            Int((nsColor.greenComponent * 255).rounded()),
            Int((nsColor.blueComponent * 255).rounded())
        )
    }

    private static func rgbComponents(fromHex hex: String) -> (Double, Double, Double) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: Int64 = 0xFFFFFF
        Scanner(string: digits).scanHexInt64(&value)
        let clamped = UInt64(max(0, value))
        return (
            Double((clamped >> 16) & 0xFF) / 255,
            Double((clamped >> 8) & 0xFF) / 255,
            Double(clamped & 0xFF) / 255
        )
    }

    func prepareForTermination() {
        persistenceTask?.cancel()
        rememberCurrentProgress(saveImmediately: true)
        persistStores()
        magnetStream.stop()
    }

    private func loadCurrentItem() {
        guard let currentItem else { return }
        guard engine.isReady else {
            // The engine never started (missing renderer, failed init). Surface the
            // failure instead of leaving the loading spinner up forever.
            isLoading = false
            errorMessage = engine.lastError ?? "The video engine is unavailable on this system."
            return
        }

        if MediaSupport.isTorrentSource(currentItem.url) {
            let itemID = currentItem.id
            // Swallow the end-file event `stop` emits so it isn't mistaken for the
            // magnet stream finishing before it has resolved.
            ignoreNextEndEvent = true
            pendingResumePosition = nil
            engine.stop()
            isPlaying = false
            magnetStream.start(from: currentItem.url) { [weak self] result in
                guard let self, self.currentID == itemID else { return }
                switch result {
                case .success(let streamURL):
                    self.loadResolvedSource(streamURL)
                case .failure(let error):
                    self.ignoreNextEndEvent = false
                    self.isLoading = false
                    self.isPlaying = false
                    self.errorMessage = error.localizedDescription
                }
            }
            return
        }

        magnetStream.stop()
        loadResolvedSource(currentItem.url)
    }

    private func updateSubtitlePosition() {
        // Compute the real overlap between the subtitle baseline and the controls
        // instead of a fixed nudge: the clearance the controls need varies with
        // window size and control content, and a letterboxed video's subtitles may
        // already clear the bar. With sub-use-margins off, sub-pos 100 places the
        // subtitle bottom at the bottom of the displayed video image, and shifts
        // scale by the displayed video height.
        guard controlsOverlayVisible,
              let view = videoView,
              view.bounds.width > 0, view.bounds.height > 0,
              let aspect = engine.videoDisplayAspect() else {
            engine.setSubtitlePosition(100)
            return
        }

        let viewSize = view.bounds.size
        let videoHeight = min(viewSize.height, viewSize.width / aspect)
        // Gap between the video image's bottom edge and the view's bottom edge;
        // the subtitle baseline sits there at sub-pos 100.
        let subtitleBottomFromViewBottom = (viewSize.height - videoHeight) / 2
        // Small breathing margin above the controls.
        let requiredClearance = controlsBottomInset + 8

        guard requiredClearance > subtitleBottomFromViewBottom else {
            // Subtitles already clear the controls; leave them at the video bottom.
            engine.setSubtitlePosition(100)
            return
        }

        let shift = requiredClearance - subtitleBottomFromViewBottom
        let position = 100 - shift / videoHeight * 100
        engine.setSubtitlePosition(min(max(position, 0), 150))
    }

    private func loadResolvedSource(_ source: URL) {
        if engine.load(source) {
            if engine.setPaused(false) {
                isPlaying = true
            } else {
                isPlaying = false
                errorMessage = engine.lastError
            }
        } else {
            ignoreNextEndEvent = false
            isLoading = false
            isPlaying = false
            errorMessage = engine.lastError
        }
    }

    private func refreshTracks() {
        audioTracks = engine.availableTracks(kind: .audio)
        subtitleTracks = engine.availableTracks(kind: .subtitle)
    }

    private func rememberCurrentProgress(saveImmediately: Bool) {
        // Magnet streams are ephemeral; their localhost URL changes every session, so
        // there is nothing meaningful to resume or persist.
        guard let currentItem, !MediaSupport.isTorrentSource(currentItem.url) else { return }
        let key = persistenceKey(for: currentItem.url)
        if position >= 5, duration <= 0 || position < duration - 10 {
            rememberedPositions[key] = position
        } else if duration > 0, position >= duration - 10 {
            rememberedPositions.removeValue(forKey: key)
        }

        if saveImmediately {
            persistenceTask?.cancel()
            persistStores()
        } else {
            schedulePersistence()
        }
    }

    private func saveCurrentMarkers() {
        guard let currentItem else { return }
        rememberedMarkers[persistenceKey(for: currentItem.url)] = PlaybackMarkers(
            introEnd: introEndMarker,
            outroStart: outroStartMarker
        )
        persistStores()
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.persistStores()
        }
    }

    private func persistStores() {
        persistenceTask = nil
        if let positions = try? JSONEncoder().encode(rememberedPositions) {
            UserDefaults.standard.set(positions, forKey: Self.positionsDefaultsKey)
        }
        if let markers = try? JSONEncoder().encode(rememberedMarkers) {
            UserDefaults.standard.set(markers, forKey: Self.markersDefaultsKey)
        }
    }

    private func persistenceKey(for url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    private func screenshotFilename() -> String {
        let rawTitle = currentItem?.title ?? "Screenshot"
        let safeTitle = rawTitle.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(safeTitle.isEmpty ? "Screenshot" : safeTitle)-\(formatter.string(from: Date())).png"
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func inspect(_ item: MediaItem) {
        guard !MediaSupport.isTorrentSource(item.url) else { return }
        Task { [weak self] in
            guard let self else { return }
            let metadata = await probe.inspect(item.url)
            guard let metadata,
                  let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
            queue[index].metadata = metadata
            if currentID == item.id, duration <= 0 {
                duration = metadata.duration ?? 0
            }
        }
    }

    private func flushPreviewSeek() {
        previewSeekTask = nil
        guard let target = pendingPreviewPosition else { return }
        pendingPreviewPosition = nil
        lastPreviewSeekUptime = ProcessInfo.processInfo.systemUptime
        engine.previewSeek(absolute: target)
    }

    private func cancelPendingPreviewSeek() {
        previewSeekTask?.cancel()
        previewSeekTask = nil
        pendingPreviewPosition = nil
    }

    private func handlePlaybackEnded() {
        if let currentItem {
            rememberedPositions.removeValue(forKey: persistenceKey(for: currentItem.url))
            persistStores()
        }
        switch repeatMode {
        case .one:
            seek(to: 0)
            playPause(true)
        case .all, .off:
            if canGoNext {
                goNext()
            } else {
                isPlaying = false
                magnetStream.stop()
            }
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
