import AppKit
import OpenGL.GL3
import QuartzCore
import SwiftUI

final class MPVGLView: NSOpenGLView {
    weak var engine: MPVEngine?
    private weak var observedWindow: NSWindow?
    private var consecutiveNoFrameCount = 0

    // macOS 14+ displayLink – automatically pauses when the view is hidden or off-screen.
    @available(macOS 14.0, *)
    private var displayLink: CADisplayLink?

    // Fallback for theoretical pre-14 target (kept for completeness, never used on the current 26.0 target).
    private var fallbackTimer: Timer?

    init?(configuredForMPV: Bool) {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile),
            UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFAAllowOfflineRenderers),
            0
        ]
        let pixelFormat = NSOpenGLPixelFormat(attributes: attributes)
        super.init(frame: .zero, pixelFormat: pixelFormat)
        wantsBestResolutionOpenGLSurface = true
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

    func makeNSView(context: Context) -> MPVGLView {
        guard let view = MPVGLView(configuredForMPV: true) else {
            fatalError("macmpv could not create an accelerated OpenGL surface.")
        }
        view.engine = player.engine
        player.attachVideoView(view)
        return view
    }

    func updateNSView(_ nsView: MPVGLView, context: Context) {}

    static func dismantleNSView(_ nsView: MPVGLView, coordinator: Coordinator) {
        coordinator.player.detachVideoView(nsView)
    }
}
