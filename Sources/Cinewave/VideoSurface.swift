import AppKit
import OpenGL.GL3
import SwiftUI

final class MPVGLView: NSOpenGLView {
    weak var engine: MPVEngine?
    private var renderTimer: Timer?
    private weak var observedWindow: NSWindow?

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
        startRenderTimer()
    }

    func startPlaybackEngine() -> Bool {
        openGLContext?.makeCurrentContext()
        let started = engine?.start() ?? false
        if started {
            startRenderTimer()
            needsDisplay = true
        }
        return started
    }

    func stopPlaybackEngine() {
        renderTimer?.invalidate()
        renderTimer = nil
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
            renderTimer?.invalidate()
            renderTimer = nil
        } else {
            startRenderTimer()
        }
    }

    @objc private func windowWillClose() {
        stopPlaybackEngine()
    }

    private func startRenderTimer() {
        guard renderTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(checkForFrame), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    @objc private func checkForFrame() {
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
