import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class PlayerModel {
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
    var expandedQueueGroupIDs: Set<UUID> = []
    var currentID: UUID?
    var position: Double = 0
    var duration: Double = 0
    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            updateSleepPrevention()
        }
    }
    var isMuted = false
    var volume: Double = 80
    var speed: Double = 1
    var repeatMode: RepeatMode = .off
    var isSidebarVisible = false {
        didSet {
            guard isSidebarVisible != oldValue else { return }
            persistQueueState()
        }
    }
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

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let engine = MPVEngine()
    @ObservationIgnored let probe = MediaProbe()
    @ObservationIgnored let magnetStream = MagnetStream()
    @ObservationIgnored private weak var videoView: MPVGLView?
    @ObservationIgnored private var completion = PlaybackCompletion()
    @ObservationIgnored private var didReadLaunchArguments = false
    @ObservationIgnored private var previewSeekTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPreviewPosition: Double?
    @ObservationIgnored private var lastPreviewSeekUptime: TimeInterval = -.infinity
    @ObservationIgnored private var wasPlayingBeforeScrub = false
    @ObservationIgnored private var pendingResumePosition: Double?
    @ObservationIgnored var rememberedPositions: [String: Double] = [:]
    @ObservationIgnored var rememberedMarkers: [String: PlaybackMarkers] = [:]
    /// Position at the last progress write; snapshots arriving between 1-second
    /// deltas are ignored so playback persistence costs ~one write per second.
    @ObservationIgnored var lastPersistedPosition: Double?
    @ObservationIgnored private var controlsOverlayVisible = true
    @ObservationIgnored private var idleSleepActivity: NSObjectProtocol?
    /// Height of the bottom controls (including their bottom padding), measured
    /// by the view that renders them; 0 while the overlay is hidden.
    @ObservationIgnored private var controlsBottomInset: Double = 0

    private let previewSeekInterval: TimeInterval = 0.18
    static let positionsDefaultsKey = "playback.positions.v1"
    static let markersDefaultsKey = "playback.markers.v1"
    static let subtitleSettingsKey = "subtitles.settings.v1"
    static let queueDefaultsKey = "player.queue.v1"

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedVolume = defaults.object(forKey: "player.volume") as? Double
        volume = storedVolume.map { min(max($0, 0), 100) } ?? 80
        rememberedPositions = load([String: Double].self, key: Self.positionsDefaultsKey) ?? [:]
        rememberedMarkers = load([String: PlaybackMarkers].self, key: Self.markersDefaultsKey) ?? [:]
        subtitleSettings = load(SubtitleSettings.self, key: Self.subtitleSettingsKey) ?? SubtitleSettings()

        if let storedQueue = load(QueuePersistence.self, key: Self.queueDefaultsKey) {
            queue = storedQueue.items.filter(Self.isRestorableQueueItem)
            let restoredGroupIDs = Set(queue.map(\.groupID))
            expandedQueueGroupIDs = Set(storedQueue.expandedGroupIDs).intersection(restoredGroupIDs)
            isSidebarVisible = storedQueue.isSidebarVisible && !queue.isEmpty
        }

        for item in queue where item.metadata == nil && !MediaSupport.isTorrentSource(item.url) {
            inspect(item)
        }
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

    func bindEngineCallbacks() {
        engine.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .fileLoaded:
                self.completion.fileLoaded()
                self.isLoading = false
                self.refreshTracks()
                // Match a normal window to the video's display aspect so playback
                // does not start with app-added letterboxing. Fullscreen and zoomed
                // windows intentionally keep the user's chosen screen-filling size.
                self.fitWindowToVideoAspect()
                // Video geometry is known once the file loads; subtitle clearance
                // depends on the letterboxed video rect.
                self.updateSubtitlePosition()
                if let resumePosition = self.pendingResumePosition, resumePosition > 5 {
                    self.engine.seek(absolute: resumePosition)
                    self.position = resumePosition
                }
                self.pendingResumePosition = nil
            case .endFile(let reachedEOF, let error):
                if let error {
                    self.isLoading = false
                    self.isPlaying = false
                    self.magnetStream.stop()
                    self.errorMessage = "Playback failed: \(error)"
                } else if reachedEOF, self.completion.observe(eofReached: true) {
                    self.isLoading = false
                    self.isPlaying = false
                    self.handlePlaybackEnded()
                }
                // Stop/replacement events are not playback completion.
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
            if !self.isLoading, self.completion.observe(eofReached: snapshot.eofReached) {
                self.handlePlaybackEnded()
            }
        }
    }

    func openLaunchArgumentsIfNeeded() {
        guard !didReadLaunchArguments else { return }
        didReadLaunchArguments = true
        let urls = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") }
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
        cancelPendingPreviewSeek()
        completion.beginLoad()
        errorMessage = nil
        currentID = item.id
        position = 0
        duration = item.metadata?.duration ?? 0
        engineTitle = nil
        isLoading = true
        let key = persistenceKey(for: item)
        pendingResumePosition = rememberedPositions[key]
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
        defaults.set(volume, forKey: "player.volume")
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
        rememberedMarkers.removeValue(forKey: persistenceKey(for: currentItem))
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

    func clearCurrentPlayback() {
        cancelPendingPreviewSeek()
        completion.beginLoad()
        magnetStream.stop()
        currentID = nil
        engineTitle = nil
        position = 0
        duration = 0
        isPlaying = false
        isLoading = false
        audioTracks = []
        subtitleTracks = []
        introEndMarker = nil
        outroStartMarker = nil
        engine.stop()
    }

    func showTorrentDownloads() {
        let directory = magnetStream.downloadDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            errorMessage = "Could not open torrent downloads: \(error.localizedDescription)"
        }
    }

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Video playback alone does not hold an idle-sleep assertion on macOS: the
    /// rendered frames are our own, not AVKit's. Keep the system and the display
    /// awake while media plays, and release the assertion as soon as it does not.
    private func updateSleepPrevention() {
        let shouldPreventSleep = isPlaying
        if shouldPreventSleep, idleSleepActivity == nil {
            idleSleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "Video playback"
            )
        } else if !shouldPreventSleep, let token = idleSleepActivity {
            ProcessInfo.processInfo.endActivity(token)
            idleSleepActivity = nil
        }
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
            defaults.set(data, forKey: Self.subtitleSettingsKey)
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
        rememberCurrentProgress(saveImmediately: true)
        persistStores()
        persistQueueState()
        magnetStream.stop()
        if let token = idleSleepActivity {
            ProcessInfo.processInfo.endActivity(token)
            idleSleepActivity = nil
        }
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
            if currentItem.torrentFile == nil {
                resolveTorrentContents(for: currentItem)
                return
            }

            let itemID = currentItem.id
            engine.stop()
            isPlaying = false
            magnetStream.start(
                from: currentItem.url,
                selectedFileIndex: currentItem.torrentFile?.index
            ) { [weak self] result in
                guard let self, self.currentID == itemID else { return }
                switch result {
                case .success(let streamURL):
                    self.loadResolvedSource(streamURL)
                case .failure(let error):
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

    private func resolveTorrentContents(for container: MediaItem) {
        let itemID = container.id
        pendingResumePosition = nil
        engine.stop()
        isPlaying = false

        magnetStream.resolveFiles(from: container.url) { [weak self] result in
            guard let self,
                  self.currentID == itemID,
                  let containerIndex = self.queue.firstIndex(where: { $0.id == itemID }) else { return }

            switch result {
            case .success(let files):
                // Torrent metadata is not required to store files in filename order.
                // Keep the original index on each TorrentFile for WebTorrent, but
                // present a Finder-like natural order so episode 2 sorts before 10.
                let playableFiles = files
                    .filter(MediaSupport.isPlayableTorrentFile)
                    .sorted {
                        $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    }
                guard !playableFiles.isEmpty else {
                    self.isLoading = false
                    self.isPlaying = false
                    self.errorMessage = "The torrent does not contain a supported video or audio file."
                    return
                }

                let expandedItems = playableFiles.map { file in
                    MediaItem(
                        url: container.url,
                        torrentFile: file,
                        groupID: container.groupID,
                        groupTitle: container.groupTitle ?? container.title,
                        groupKind: .torrent
                    )
                }
                self.queue.replaceSubrange(containerIndex...containerIndex, with: expandedItems)
                self.expandedQueueGroupIDs.insert(container.groupID)
                self.persistQueueState()
                // Start with the first naturally sorted media file. Every expanded
                // row gets a fresh identity so SwiftUI cannot retain the placeholder
                // row at an unrelated position in the newly resolved file list.
                self.play(expandedItems[0])

            case .failure(let error):
                self.isLoading = false
                self.isPlaying = false
                self.errorMessage = error.localizedDescription
            }
        }
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

    /// Reshapes a regular playback window to the video's native display size,
    /// scaling only as needed to remain inside the usable screen and the app's
    /// minimum control size.
    private func fitWindowToVideoAspect() {
        guard let view = videoView,
              let window = view.window,
              !window.styleMask.contains(.fullScreen),
              !window.isZoomed,
              !window.isMiniaturized,
              let displaySize = engine.videoDisplaySize(),
              displaySize.width > 0,
              displaySize.height > 0,
              case let aspect = displaySize.width / displaySize.height,
              aspect.isFinite,
              aspect > 0,
              let screen = window.screen ?? NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        // isZoomed is authoritative for the green-button zoom state. Also protect
        // windows that were manually sized to the visible screen bounds.
        let maximizedTolerance: CGFloat = 2
        let frame = window.frame
        let fillsVisibleScreen = abs(frame.minX - visibleFrame.minX) <= maximizedTolerance
            && abs(frame.minY - visibleFrame.minY) <= maximizedTolerance
            && abs(frame.width - visibleFrame.width) <= maximizedTolerance
            && abs(frame.height - visibleFrame.height) <= maximizedTolerance
        guard !fillsVisibleScreen else { return }

        let contentRect = window.contentRect(forFrameRect: frame)
        let chromeWidth = max(0, frame.width - contentRect.width)
        let chromeHeight = max(0, frame.height - contentRect.height)
        let maximumContentWidth = max(1, visibleFrame.width - chromeWidth)
        let maximumContentHeight = max(1, visibleFrame.height - chromeHeight)
        let minimumContentSize = window.contentMinSize

        // Express all limits as a content-height range where width = height × aspect.
        let minimumHeight = max(minimumContentSize.height, minimumContentSize.width / aspect)
        let maximumHeight = min(maximumContentHeight, maximumContentWidth / aspect)
        // Extremely tall or wide video can be impossible to fit while honoring the
        // app's minimum usable control size. In that rare case, keep the current
        // window instead of moving part of it off-screen.
        guard minimumHeight <= maximumHeight else { return }

        // Video pixels equal points only at 1× backing scale; divide so the
        // window shows one device pixel per source pixel (e.g. half the pixel
        // height on a 2× Retina display) instead of pinning against full screen.
        let preferredHeight = displaySize.height / window.backingScaleFactor
        let targetContentHeight = min(max(preferredHeight, minimumHeight), maximumHeight)
        let targetContentSize = NSSize(
            width: targetContentHeight * aspect,
            height: targetContentHeight
        )
        guard abs(targetContentSize.width - contentRect.width) > 0.5
                || abs(targetContentSize.height - contentRect.height) > 0.5 else { return }

        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetContentSize)
        ).size
        var targetOrigin = NSPoint(
            x: frame.midX - targetFrameSize.width / 2,
            y: frame.midY - targetFrameSize.height / 2
        )
        targetOrigin.x = min(
            max(targetOrigin.x, visibleFrame.minX),
            visibleFrame.maxX - targetFrameSize.width
        )
        targetOrigin.y = min(
            max(targetOrigin.y, visibleFrame.minY),
            visibleFrame.maxY - targetFrameSize.height
        )

        window.setFrame(
            NSRect(origin: targetOrigin, size: targetFrameSize),
            display: true,
            animate: true
        )
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
            isLoading = false
            isPlaying = false
            errorMessage = engine.lastError
        }
    }

    private func refreshTracks() {
        audioTracks = engine.availableTracks(kind: .audio)
        subtitleTracks = engine.availableTracks(kind: .subtitle)
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

    func inspect(_ item: MediaItem) {
        guard !MediaSupport.isTorrentSource(item.url) else { return }
        Task { [weak self] in
            guard let self else { return }
            let metadata = await probe.inspect(item.url)
            guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
            if let metadata {
                queue[index].metadata = metadata
                if currentID == item.id, duration <= 0 {
                    duration = metadata.duration ?? 0
                }
            } else {
                queue[index].probeFailed = true
            }
            persistQueueState()
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
            rememberedPositions.removeValue(forKey: persistenceKey(for: currentItem))
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
                // Keep downloading the remaining files while the app is open.
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
