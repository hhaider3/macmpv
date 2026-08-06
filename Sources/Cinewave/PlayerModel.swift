import AppKit
import Foundation
import Observation
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
    var currentID: UUID?
    var position: Double = 0
    var duration: Double = 0
    var isPlaying = false
    var isMuted = false
    var volume: Double = 80
    var speed: Double = 1
    var repeatMode: RepeatMode = .off
    var isSidebarVisible = true
    var isLoading = false
    var errorMessage: String?
    var engineTitle: String?

    @ObservationIgnored let engine = MPVEngine()
    @ObservationIgnored private let probe = MediaProbe()
    @ObservationIgnored private weak var videoView: MPVGLView?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var ignoreNextEndEvent = false
    @ObservationIgnored private var didReadLaunchArguments = false
    @ObservationIgnored private var previewSeekTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPreviewPosition: Double?
    @ObservationIgnored private var lastPreviewSeekUptime: TimeInterval = -.infinity
    @ObservationIgnored private var wasPlayingBeforeScrub = false

    private let previewSeekInterval: TimeInterval = 0.18

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
    }

    func attachVideoView(_ view: MPVGLView) {
        if let existingView = videoView, existingView !== view {
            existingView.stopPlaybackEngine()
        }
        videoView = view
        guard view.startPlaybackEngine() else {
            errorMessage = engine.lastError ?? "The mpv video engine could not start."
            return
        }
        engine.setVolume(volume)
        startPolling()
        if currentID != nil {
            loadCurrentItem()
        }
    }

    func detachVideoView(_ view: MPVGLView) {
        guard videoView === view else { return }
        view.stopPlaybackEngine()
        videoView = nil
        isLoading = false
        isPlaying = false
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
        panel.allowedContentTypes = [.audiovisualContent, .movie, .audio]
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
            errorMessage = "Enter a valid HTTP, HTTPS, RTMP, or RTSP media URL."
            return
        }
        enqueue([url], playFirst: true)
    }

    func play(_ item: MediaItem) {
        guard queue.contains(where: { $0.id == item.id }) else { return }
        currentID = item.id
        position = 0
        duration = item.metadata?.duration ?? 0
        engineTitle = nil
        isLoading = true
        ignoreNextEndEvent = true
        loadCurrentItem()
    }

    func togglePlayback() {
        guard hasMedia else {
            openPanel()
            return
        }
        engine.togglePause()
        isPlaying.toggle()
    }

    func playPause(_ shouldPlay: Bool) {
        guard hasMedia else { return }
        engine.setPaused(!shouldPlay)
        isPlaying = shouldPlay
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
            engine.setPaused(true)
            isPlaying = false
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
            engine.setPaused(false)
            isPlaying = true
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

    func setMuted(_ muted: Bool) {
        isMuted = muted
        engine.setMuted(muted)
    }

    func toggleMuted() {
        setMuted(!isMuted)
    }

    func setSpeed(_ newSpeed: Double) {
        speed = newSpeed
        engine.setSpeed(newSpeed)
    }

    func cycleRepeatMode() {
        repeatMode.advance()
    }

    func remove(_ item: MediaItem) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
        let wasCurrent = item.id == currentID
        queue.remove(at: index)
        guard wasCurrent else { return }

        if queue.isEmpty {
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
        queue.removeAll()
        currentID = nil
        engineTitle = nil
        position = 0
        duration = 0
        isPlaying = false
        engine.stop()
    }

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    func dismissError() {
        errorMessage = nil
    }

    private func loadCurrentItem() {
        guard engine.isReady, let currentItem else { return }
        if engine.load(currentItem.url) {
            engine.setPaused(false)
            isPlaying = true
        } else {
            isLoading = false
            isPlaying = false
            errorMessage = engine.lastError
        }
    }

    private func inspect(_ item: MediaItem) {
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

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(pollPlayback), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
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

    @objc private func pollPlayback() {
        for event in engine.drainEvents() {
            switch event {
            case .fileLoaded:
                ignoreNextEndEvent = false
                isLoading = false
            case .endFile:
                if ignoreNextEndEvent {
                    ignoreNextEndEvent = false
                } else {
                    handlePlaybackEnded()
                }
            case .shutdown:
                isPlaying = false
            }
        }

        guard let snapshot = engine.snapshot(), hasMedia else { return }
        position = snapshot.position
        if snapshot.duration > 0 { duration = snapshot.duration }
        isPlaying = !snapshot.paused && !snapshot.eofReached
        isMuted = snapshot.muted
        volume = snapshot.volume
        speed = snapshot.speed
        engineTitle = snapshot.title
    }

    private func handlePlaybackEnded() {
        switch repeatMode {
        case .one:
            seek(to: 0)
            playPause(true)
        case .all, .off:
            if canGoNext {
                goNext()
            } else {
                isPlaying = false
            }
        }
    }
}
