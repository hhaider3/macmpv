import AppKit
import OpenGL.GL3
import QuartzCore
import SwiftUI

final class MPVGLView: NSOpenGLView {
    weak var engine: MPVEngine?
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private weak var observedWindow: NSWindow?
    private var consecutiveNoFrameCount = 0
    private var pendingSingleClick: DispatchWorkItem?

    // macOS 14+ displayLink – automatically pauses when the view is hidden or off-screen.
    @available(macOS 14.0, *)
    private var displayLink: CADisplayLink?

    // Fallback for theoretical pre-14 target (kept for completeness, never used on the current 26.0 target).
    private var fallbackTimer: Timer?

    init?(configuredForMPV: Bool) {
        guard let pixelFormat = Self.makePixelFormat() else { return nil }
        super.init(frame: .zero, pixelFormat: pixelFormat)
        wantsBestResolutionOpenGLSurface = true
    }

    /// Prefer an accelerated GL 3.2 context. VMs and headless sessions may only
    /// expose a software renderer, so degrade the attribute list instead of failing
    /// outright; the minimal double-buffered format is supported by every renderer.
    private static func makePixelFormat() -> NSOpenGLPixelFormat? {
        let accelerated: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFAAllowOfflineRenderers),
            0
        ]
        let software: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            0
        ]
        let minimal: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFADoubleBuffer),
            0
        ]
        return NSOpenGLPixelFormat(attributes: accelerated)
            ?? NSOpenGLPixelFormat(attributes: software)
            ?? NSOpenGLPixelFormat(attributes: minimal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)
        setupDisplayLink()
    }

    func startPlaybackEngine() -> Bool {
        openGLContext?.makeCurrentContext()
        let started = engine?.start() ?? false
        if started {
            setupDisplayLink()
            bindRenderCallback()
            needsDisplay = true
        }
        return started
    }

    func stopPlaybackEngine() {
        teardownDisplayLink()
        // Clear render callback before destroying the context.
        engine?.onRenderUpdate = nil
        openGLContext?.makeCurrentContext()
        engine?.shutdown()
        NSOpenGLContext.clearCurrentContext()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let engine else {
            glClearColor(0.018, 0.022, 0.035, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            openGLContext?.flushBuffer()
            return
        }

        openGLContext?.makeCurrentContext()
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        let backingBounds = convertToBacking(bounds)
        engine.render(
            framebuffer: framebuffer,
            width: Int32(backingBounds.width.rounded()),
            height: Int32(backingBounds.height.rounded())
        )
        openGLContext?.flushBuffer()
        engine.reportSwap()
    }

    override func reshape() {
        super.reshape()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            onDoubleClick?()
            return
        }

        guard event.clickCount == 1 else { return }
        pendingSingleClick?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingSingleClick = nil
            self?.onSingleClick?()
        }
        pendingSingleClick = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NSEvent.doubleClickInterval,
            execute: workItem
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if observedWindow !== window {
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.willCloseNotification,
                    object: observedWindow
                )
            }
            observedWindow = window
            if let window {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowWillClose),
                    name: NSWindow.willCloseNotification,
                    object: window
                )
            }
        }
        if window == nil {
            teardownDisplayLink()
        } else {
            setupDisplayLink()
            // Re-bind: the engine may have been started before the view was in a window.
            if engine?.isReady == true {
                bindRenderCallback()
            }
        }
    }

    @objc private func windowWillClose() {
        stopPlaybackEngine()
    }

    // MARK: - DisplayLink

    private func setupDisplayLink() {
        if #available(macOS 14.0, *) {
            guard displayLink == nil else { return }
            // `NSView.displayLink(target:selector:)` is the macOS 14+ replacement for CVDisplayLink.
            // The returned CADisplayLink is view-owned and automatically stops callbacks when
            // the view is hidden, off-screen, or the window is minimized — eliminating the
            // 60 Hz polling that previously ran while paused/minimized.
            let dl = displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
            dl.add(to: .main, forMode: .common)
            dl.isPaused = true
            displayLink = dl
        } else {
            startFallbackTimer()
        }
    }

    private func teardownDisplayLink() {
        pendingSingleClick?.cancel()
        pendingSingleClick = nil
        if #available(macOS 14.0, *) {
            displayLink?.invalidate()
            displayLink = nil
        }
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        consecutiveNoFrameCount = 0
    }

    private func bindRenderCallback() {
        engine?.onRenderUpdate = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if #available(macOS 14.0, *) {
                    self.displayLink?.isPaused = false
                    self.consecutiveNoFrameCount = 0
                }
                self.needsDisplay = true
            }
        }
    }

    @available(macOS 14.0, *)
    @objc private func handleDisplayLink(_ sender: CADisplayLink) {
        guard let engine else {
            sender.isPaused = true
            return
        }
        // `mpv_render_context_update` must be called on the render thread to learn
        // whether a new frame is available. We do this at display cadence, not via a fixed timer.
        if engine.rendererNeedsFrame() {
            needsDisplay = true
            consecutiveNoFrameCount = 0
        } else {
            consecutiveNoFrameCount += 1
            // After ~0.5 s of idle frames, pause the link until mpv signals new content.
            if consecutiveNoFrameCount > 30 {
                sender.isPaused = true
            }
        }
    }

    // MARK: - Fallback (pre-14, kept only for completeness)

    private func startFallbackTimer() {
        guard fallbackTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(checkForFrameFallback), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    @objc private func checkForFrameFallback() {
        if engine?.rendererNeedsFrame() == true {
            needsDisplay = true
        }
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: PlayerModel

    final class Coordinator {
        let player: PlayerModel

        init(player: PlayerModel) {
            self.player = player
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player)
    }

    func makeNSView(context: Context) -> NSView {
        guard let view = MPVGLView(configuredForMPV: true) else {
            // No OpenGL pixel format exists at all (no renderer on this system).
            // Keep the app running and surface the failure in-app instead of crashing.
            player.reportVideoSurfaceFailure()
            return UnsupportedSurfaceView()
        }
        view.engine = player.engine
        view.onSingleClick = { [weak player] in
            guard let player, player.hasMedia else { return }
            player.togglePlayback()
        }
        view.onDoubleClick = { [weak player] in
            player?.toggleFullscreen()
        }
        player.attachVideoView(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        guard let view = nsView as? MPVGLView else { return }
        view.onSingleClick = nil
        view.onDoubleClick = nil
        coordinator.player.detachVideoView(view)
    }
}

/// Placeholder shown when no OpenGL surface can be created at all — playback is
/// impossible, but the app must stay alive and explain why.
private final class UnsupportedSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.018, green: 0.022, blue: 0.035, alpha: 1).cgColor

        let label = NSTextField(
            labelWithString: "Video playback is unavailable: no OpenGL renderer was found on this system."
        )
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            trailingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 20)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
