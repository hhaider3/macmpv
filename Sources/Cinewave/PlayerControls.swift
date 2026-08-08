import SwiftUI

struct PlayerControls: View {
    @Bindable var player: PlayerModel
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    private let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 10) {
                Text(currentTime.playbackTime)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.72))

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubPosition : player.position },
                        set: { newPosition in
                            scrubPosition = newPosition
                            if isScrubbing {
                                player.previewSeek(to: newPosition)
                            }
                        }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            scrubPosition = player.position
                            isScrubbing = true
                            player.beginScrubbing()
                        } else {
                            player.endScrubbing(at: scrubPosition)
                            isScrubbing = false
                        }
                    }
                )
                .tint(.white)
                .disabled(!player.hasMedia || player.duration <= 0)

                Text(player.duration.playbackTime)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.72))
            }
            .font(.system(size: 11, weight: .medium))

            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    ControlButton(
                        symbol: player.isSidebarVisible ? "sidebar.left" : "sidebar.right",
                        help: player.isSidebarVisible ? "Hide playlist" : "Show playlist"
                    ) {
                        player.isSidebarVisible.toggle()
                    }

                    subtitleMenu
                    audioMenu
                    markerMenu
                }

                Spacer(minLength: 16)

                HStack(spacing: 13) {
                    ControlButton(symbol: "backward.end.fill", size: 15, help: "Previous") {
                        player.goPrevious()
                    }
                    .disabled(!player.canGoPrevious)

                    ControlButton(symbol: "gobackward.10", size: 17, help: "Back 10 seconds") {
                        player.seek(relative: -10)
                    }
                    .disabled(!player.hasMedia)

                    if player.introEndMarker != nil {
                        ControlButton(symbol: "forward.fill", size: 14, help: "Skip intro") {
                            player.skipIntro()
                        }
                    }

                    Button {
                        player.togglePlayback()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color(red: 0.06, green: 0.07, blue: 0.12))
                            .frame(width: 48, height: 48)
                            .background(.white, in: Circle())
                            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help(player.hasMedia ? (player.isPlaying ? "Pause" : "Play") : "Open media")

                    ControlButton(symbol: "goforward.10", size: 17, help: "Forward 10 seconds") {
                        player.seek(relative: 10)
                    }
                    .disabled(!player.hasMedia)

                    if player.outroStartMarker != nil {
                        ControlButton(symbol: "forward.end.fill", size: 14, help: "Skip outro") {
                            player.skipOutro()
                        }
                    }

                    ControlButton(symbol: "forward.end.fill", size: 15, help: "Next") {
                        player.goNext()
                    }
                    .disabled(!player.canGoNext)
                }

                Spacer(minLength: 16)

                HStack(spacing: 8) {
                    ControlButton(
                        symbol: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        help: player.isMuted ? "Unmute" : "Mute"
                    ) {
                        player.toggleMuted()
                    }

                    Slider(
                        value: Binding(
                            get: { player.volume },
                            set: { player.setVolume($0) }
                        ),
                        in: 0...100
                    )
                    .tint(.white)
                    .frame(width: 72)

                    Menu {
                        ForEach(speeds, id: \.self) { speed in
                            Button {
                                player.setSpeed(speed)
                            } label: {
                                if player.speed == speed {
                                    Label(speedLabel(speed), systemImage: "checkmark")
                                } else {
                                    Text(speedLabel(speed))
                                }
                            }
                        }
                    } label: {
                        Text(speedLabel(player.speed))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .frame(minWidth: 28)
                            .padding(.horizontal, 7)
                            .frame(height: 30)
                            .background(.white.opacity(0.09), in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    ControlButton(symbol: "camera.fill", help: "Save screenshot (⇧⌘S)") {
                        player.takeScreenshot()
                    }
                    .disabled(!player.hasMedia)

                    ControlButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Enter full screen") {
                        player.toggleFullscreen()
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 16)
        .glassEffect(
            .clear
                .interactive(),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .glassEffectTransition(.materialize)
    }

    private var currentTime: Double {
        isScrubbing ? scrubPosition : player.position
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                player.selectSubtitleTrack(nil)
            } label: {
                if player.subtitleTracks.contains(where: \.isSelected) {
                    Text("Subtitles Off")
                } else {
                    Label("Subtitles Off", systemImage: "checkmark")
                }
            }

            if !player.subtitleTracks.isEmpty {
                Divider()
                ForEach(player.subtitleTracks) { track in
                    Button {
                        player.selectSubtitleTrack(track)
                    } label: {
                        if track.isSelected {
                            Label(track.displayName, systemImage: "checkmark")
                        } else {
                            Text(track.displayName)
                        }
                    }
                }
            }

            Divider()
            Button("Open Subtitle File…", systemImage: "folder") {
                player.openSubtitlePanel()
            }
        } label: {
            GlassMenuIcon(symbol: "captions.bubble")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!player.hasMedia)
        .help("Choose subtitles")
    }

    private var audioMenu: some View {
        Menu {
            if player.audioTracks.isEmpty {
                Text("No audio tracks")
            } else {
                ForEach(player.audioTracks) { track in
                    Button {
                        player.selectAudioTrack(track)
                    } label: {
                        if track.isSelected {
                            Label(track.displayName, systemImage: "checkmark")
                        } else {
                            Text(track.displayName)
                        }
                    }
                }
            }
        } label: {
            GlassMenuIcon(symbol: "waveform")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!player.hasMedia)
        .help("Choose audio track")
    }

    private var markerMenu: some View {
        Menu {
            Button("Set Intro End Here", systemImage: "inpoint") {
                player.setIntroEndMarker()
            }
            if let marker = player.introEndMarker {
                Button("Skip Intro to \(marker.playbackTime)", systemImage: "forward.fill") {
                    player.skipIntro()
                }
            }

            Divider()

            Button("Set Outro Start Here", systemImage: "outpoint") {
                player.setOutroStartMarker()
            }
            if let marker = player.outroStartMarker {
                Button("Skip Outro from \(marker.playbackTime)", systemImage: "forward.end.fill") {
                    player.skipOutro()
                }
            }

            if player.introEndMarker != nil || player.outroStartMarker != nil {
                Divider()
                Button("Clear Markers", role: .destructive) {
                    player.clearPlaybackMarkers()
                }
            }
        } label: {
            GlassMenuIcon(symbol: "flag.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!player.hasMedia)
        .help("Intro and outro markers")
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : "\(speed.formatted())×"
    }
}

private struct GlassMenuIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white.opacity(0.88))
            .frame(width: 34, height: 42)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .glassEffect(
                .clear.interactive(),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}

struct ControlButton: View {
    let symbol: String
    var size: CGFloat = 14
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(PlayerIconButtonStyle())
        .help(help)
    }
}

private struct PlayerIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? .white.opacity(0.15) : .clear,
                in: Circle()
            )
            .opacity(isEnabled ? 1 : 0.32)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
