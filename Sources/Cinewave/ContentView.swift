import SwiftUI

struct ContentView: View {
    @Bindable var player: PlayerModel
    @State private var isDropTarget = false
    @State private var isShowingURLSheet = false
    @State private var isFullscreen = false
    @State private var isFullscreenControlZoneHovered = false

    private let fullscreenControlZoneHeight: CGFloat = 160

    var body: some View {
        ZStack {
            playerArea

            if player.isSidebarVisible {
                HStack(alignment: .top, spacing: 0) {
                    QueueSidebar(player: player)
                        .padding(.top, 58)
                        .padding(.bottom, 130)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.25), value: player.isSidebarVisible)
        .background(Color(red: 0.025, green: 0.029, blue: 0.047))
        .preferredColorScheme(.dark)
        .dropDestination(for: URL.self) { urls, _ in
            let playable = urls.filter(MediaSupport.isPlayable)
            guard !playable.isEmpty else { return false }
            player.enqueue(playable, playFirst: player.currentID == nil)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) {
                isDropTarget = targeted
            }
        }
        .sheet(isPresented: $isShowingURLSheet) {
            OpenURLSheet { value in
                player.openNetworkURL(value)
                isShowingURLSheet = false
            }
        }
        .overlay {
            if isDropTarget && !isFullscreen {
                DropOverlay()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onAppear {
            updateSubtitleControlInset()
        }
        .onChange(of: isFullscreen) {
            updateSubtitleControlInset()
        }
        .onChange(of: isFullscreenControlZoneHovered) {
            updateSubtitleControlInset()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullscreen = true
            isFullscreenControlZoneHovered = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullscreen = false
            isFullscreenControlZoneHovered = false
        }
    }

    private func updateSubtitleControlInset() {
        player.setControlsOverlayVisible(!isFullscreen || isFullscreenControlZoneHovered)
    }

    private func isMouseInFullscreenControlZone() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        return mouse.x >= frame.minX
            && mouse.x <= frame.maxX
            && mouse.y >= frame.minY
            && mouse.y <= frame.minY + fullscreenControlZoneHeight
    }

    private var playerArea: some View {
        ZStack {
            VideoSurface(player: player)
                .ignoresSafeArea()
                .transaction { transaction in
                    transaction.animation = nil
                }

            if !player.hasMedia {
                WelcomeView(
                    openFiles: player.openPanel,
                    openURL: { isShowingURLSheet = true }
                )
            }

            if isFullscreen {
                fullscreenControls
            } else {
                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(player.hasMedia ? 0.16 : 0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    PlayerHeader(
                        player: player,
                        openURL: { isShowingURLSheet = true }
                    )

                    Spacer()

                    PlayerControls(player: player)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                        .background {
                            ControlsInsetReader(player: player)
                        }
                }

                if player.isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .padding(18)
                        .background(.ultraThinMaterial, in: Circle())
                }

                if let error = player.errorMessage {
                    VStack {
                        ErrorToast(message: error, dismiss: player.dismissError)
                            .padding(.top, 54)
                        Spacer()
                    }
                }
            }
        }
    }

    private var fullscreenControls: some View {
        VStack(spacing: 0) {
            if !player.isPlaying, player.hasMedia {
                PlayerHeader(
                    player: player,
                    openURL: { isShowingURLSheet = true }
                )
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.55), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .top)
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            ZStack(alignment: .bottom) {
                Color.clear
                    .contentShape(Rectangle())

                if isFullscreenControlZoneHovered {
                    ZStack(alignment: .bottom) {
                        PlayerControls(player: player)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 22)
                            .background {
                                ControlsInsetReader(player: player)
                            }
                    }
                    .compositingGroup()
                    .transition(.opacity)
                }
            }
            .frame(height: fullscreenControlZoneHeight)
            .contentShape(Rectangle())
            .onHover { hovering in
                // Moving into the settings popover reports a zone exit; keep the
                // bar (and the popover anchored to it) alive while it is open.
                let effective = hovering || player.isSubtitleSettingsPresented
                withAnimation(.easeOut(duration: 0.2)) {
                    isFullscreenControlZoneHovered = effective
                }
            }
            .onChange(of: player.isSubtitleSettingsPresented) { _, presented in
                guard !presented else { return }
                // The popover swallowed hover events while open, so the zone state
                // may be stale; re-evaluate it from the actual cursor position.
                withAnimation(.easeOut(duration: 0.2)) {
                    isFullscreenControlZoneHovered = isMouseInFullscreenControlZone()
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: player.isPlaying)
    }
}

private struct PlayerHeader: View {
    @Bindable var player: PlayerModel
    let openURL: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if !player.isSidebarVisible {
                Button {
                    player.isSidebarVisible = true
                } label: {
                    Image(systemName: "sidebar.left")
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.28), in: Circle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(player.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let metadata = player.currentMetadata {
                    HStack(spacing: 5) {
                        if let resolution = metadata.resolution { Text(resolution) }
                        if let codec = metadata.videoCodec { Text("•"); Text(codec) }
                        if let fps = metadata.frameRateLabel { Text("•"); Text(fps) }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                }
            }

            Spacer()

            Button(action: player.openPanel) {
                Label("Open", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(.black.opacity(0.26), in: Capsule())
            }
            .buttonStyle(.plain)

            Button(action: openURL) {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.26), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Open network stream")
        }
        .padding(.horizontal, 17)
        .padding(.top, 28)
    }
}

private struct WelcomeView: View {
    let openFiles: () -> Void
    let openURL: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.indigo.opacity(0.75), Color.cyan.opacity(0.38)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 84, height: 84)
                    .blur(radius: 18)

                Image(systemName: "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: 2)
            }

            VStack(spacing: 7) {
                Text("Play something beautiful")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("Drop a video here, open a local file, or connect to a stream.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }

            HStack(spacing: 9) {
                Button(action: openFiles) {
                    Label("Open Media", systemImage: "folder")
                        .frame(height: 28)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)

                Button(action: openURL) {
                    Label("Open URL", systemImage: "link")
                        .frame(height: 28)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(.bottom, 68)
    }
}

private struct OpenURLSheet: View {
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                Image(systemName: "network")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 42, height: 42)
                    .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open Network Stream")
                        .font(.system(size: 17, weight: .semibold))
                    Text("HTTP, HTTPS, RTMP, RTSP, and magnet links are supported.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            TextField("https://example.com/video.m3u8", text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func submit() {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        open(value)
    }
}

/// Reports the height the bottom controls occupy (including their bottom
/// padding) so subtitle placement can clear the actual overlap rather than a
/// fixed nudge. Attached as a background to the padded controls, whose bounds
/// reach the bottom of the player area.
private struct ControlsInsetReader: View {
    let player: PlayerModel

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { player.setControlsBottomInset(geo.size.height) }
                .onChange(of: geo.size.height) { _, height in
                    player.setControlsBottomInset(height)
                }
        }
    }
}

private struct ErrorToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(.orange.opacity(0.28), lineWidth: 1) }
        .shadow(color: .black.opacity(0.3), radius: 16, y: 5)
        .frame(maxWidth: 520)
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Color.indigo.opacity(0.18)
                .background(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    .white.opacity(0.85),
                    style: StrokeStyle(lineWidth: 2, dash: [10, 7])
                )
                .padding(22)
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 38, weight: .medium))
                Text("Drop to add to macmpv")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }
        }
    }
}
