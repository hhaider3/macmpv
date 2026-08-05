import SwiftUI

@main
struct MacMPVApp: App {
    @State private var player = PlayerModel()

    var body: some Scene {
        WindowGroup {
            ContentView(player: player)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
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
