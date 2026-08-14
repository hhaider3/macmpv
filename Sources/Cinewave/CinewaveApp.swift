import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var player: PlayerModel?

    func applicationWillTerminate(_ notification: Notification) {
        player?.prepareForTermination()
    }
}

@main
struct MacMPVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var player = PlayerModel()

    var body: some Scene {
        Window("macmpv", id: "player") {
            ContentView(player: player)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    appDelegate.player = player
                    player.openLaunchArgumentsIfNeeded()
                }
                .onOpenURL { url in
                    player.enqueue([url], playFirst: true)
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            MacMPVCommands(player: player)
        }
    }
}

struct MacMPVCommands: Commands {
    let player: PlayerModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Media…") {
                player.openPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") {
                player.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])

            Divider()

            Button("Back 10 Seconds") {
                player.seek(relative: -10)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!player.hasMedia)

            Button("Forward 10 Seconds") {
                player.seek(relative: 10)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!player.hasMedia)

            Button("Previous Item") {
                player.goPrevious()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!player.canGoPrevious)

            Button("Next Item") {
                player.goNext()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!player.canGoNext)

            Divider()

            Button(player.repeatMode.label) {
                player.cycleRepeatMode()
            }

            Button(player.isMuted ? "Unmute" : "Mute") {
                player.toggleMuted()
            }
            .keyboardShortcut("m", modifiers: [])

            Button("Volume Up") {
                player.adjustVolume(by: 5)
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(!player.hasMedia)

            Button("Volume Down") {
                player.adjustVolume(by: -5)
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(!player.hasMedia)

            Divider()

            Button("Decrease Speed") {
                player.adjustSpeed(by: -0.25)
            }
            .keyboardShortcut("[", modifiers: [])
            .disabled(!player.hasMedia)

            Button("Increase Speed") {
                player.adjustSpeed(by: 0.25)
            }
            .keyboardShortcut("]", modifiers: [])
            .disabled(!player.hasMedia)

            Button("Reset Speed") {
                player.resetSpeed()
            }
            .keyboardShortcut("\\", modifiers: [])
            .disabled(!player.hasMedia)

            Divider()

            Button("Open Subtitle File…") {
                player.openSubtitlePanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!player.hasMedia)

            Button("Save Screenshot…") {
                player.takeScreenshot()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!player.hasMedia)
        }

        CommandMenu("Queue") {
            Button(player.isSidebarVisible ? "Hide Queue" : "Show Queue") {
                player.isSidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Button("Clear Queue", role: .destructive) {
                player.clearQueue()
            }
            .disabled(player.queue.isEmpty)
        }
    }
}
