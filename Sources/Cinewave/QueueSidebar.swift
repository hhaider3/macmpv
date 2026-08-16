import AppKit
import SwiftUI

struct QueueSidebar: View {
    @Bindable var player: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            header

            if player.queue.isEmpty {
                emptyQueue
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(player.queue) { item in
                            QueueRow(
                                item: item,
                                isCurrent: item.id == player.currentID,
                                moveBefore: { draggedID in
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        player.moveQueueItem(id: draggedID, before: item.id)
                                    }
                                }
                            ) {
                                player.play(item)
                            }
                            .contextMenu {
                                Button("Play") { player.play(item) }
                                if item.url.isFileURL {
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                    }
                                }
                                Divider()
                                Button("Remove from Queue", role: .destructive) {
                                    player.remove(item)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }

            if let item = player.currentItem {
                CurrentMediaDetails(item: item)
                    .padding(10)
            }
        }
        .frame(
            minWidth: 300,
            idealWidth: 300,
            maxWidth: 300,
            maxHeight: .infinity
        )
        .glassEffect(
            .clear
                .interactive(),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .glassEffectTransition(.materialize)
        .overlay(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("UP NEXT")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                Text("\(player.queue.count) \(player.queue.count == 1 ? "item" : "items")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.8))
            }

            Spacer()

            Button {
                player.openPanel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 27, height: 27)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Add media")

            if !player.queue.isEmpty {
                Menu {
                    Button("Clear Queue", role: .destructive) {
                        player.clearQueue()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 27, height: 27)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 32)
        .padding(.bottom, 14)
    }

    private var emptyQueue: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Your queue is empty")
                .font(.system(size: 13, weight: .semibold))
            Text("Add several files to play them in order.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 170)
            Button("Add Media") { player.openPanel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct QueueRow: View {
    let item: MediaItem
    let isCurrent: Bool
    let moveBefore: (UUID) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isCurrent
                                    ? [Color.indigo.opacity(0.85), Color.cyan.opacity(0.6)]
                                    : [.white.opacity(0.1), .white.opacity(0.035)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: isCurrent ? "waveform" : "play.fill")
                        .font(.system(size: isCurrent ? 13 : 10, weight: .bold))
                        .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.55))
                }
                .frame(width: 42, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? Color.primary : Color.primary.opacity(0.84))
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text(item.fileExtension.isEmpty ? "STREAM" : item.fileExtension)
                        if let duration = item.metadata?.duration {
                            Text("•")
                            Text(duration.playbackTime)
                        }
                    }
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isCurrent ? .white.opacity(0.09) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .draggable(item.id.uuidString)
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first,
                  let draggedID = UUID(uuidString: value) else { return false }
            moveBefore(draggedID)
            return true
        }
    }
}

private struct CurrentMediaDetails: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("NOW PLAYING")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.25)
                .foregroundStyle(.secondary)

            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)

            if let metadata = item.metadata {
                HStack(spacing: 6) {
                    if let resolution = metadata.resolution {
                        MetadataPill(resolution)
                    }
                    if let codec = metadata.videoCodec ?? metadata.audioCodec {
                        MetadataPill(codec)
                    }
                    if let fps = metadata.frameRateLabel {
                        MetadataPill(fps)
                    }
                }
            } else if MediaSupport.isTorrentSource(item.url) {
                Text("Streaming from BitTorrent")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if item.probeFailed {
                Text("Media info unavailable")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading media info…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        }
    }
}

struct MetadataPill: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 19)
            .background(.white.opacity(0.07), in: Capsule())
    }
}
