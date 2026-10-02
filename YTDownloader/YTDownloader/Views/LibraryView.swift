import SwiftUI
import UIKit

/// Tab 2: every download – progress while running, then Play / Delete when finished.
struct LibraryView: View {

    private var manager: DownloadManager { DownloadManager.shared }

    @State private var playing: PlayableVideo?
    @State private var pendingDelete: DownloadItem?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if manager.items.isEmpty {
                    ContentUnavailableView(
                        "No videos yet",
                        systemImage: "film.stack",
                        description: Text("Videos you download appear here. Start on the Download tab.")
                    )
                } else {
                    List {
                        ForEach(manager.items) { item in
                            DownloadRow(
                                item: item,
                                onPlay: { play(item) },
                                onRetry: { manager.retry(item) },
                                onDelete: { pendingDelete = item }
                            )
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { manager.delete(item) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Videos")
            .toolbar {
                if manager.failedCount > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { manager.retryAllFailed() } label: {
                            Label("Retry failed", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete this video?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { item in
                Button("Delete", role: .destructive) { manager.delete(item) }
            } message: { item in
                Text(item.title)
            }
            .alert("Cannot play", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .fullScreenCover(item: $playing) { video in
                PlayerView(url: video.url, title: video.title)
            }
        }
    }

    private func play(_ item: DownloadItem) {
        guard let url = StorageManager.shared.fileURL(for: item),
              FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "The video file was not found. It may have been moved or deleted in the Files app."
            return
        }
        playing = PlayableVideo(url: url, title: item.title)
    }
}

struct PlayableVideo: Identifiable {
    let url: URL
    let title: String
    var id: URL { url }
}

/// One line in the Videos list.
struct DownloadRow: View {
    let item: DownloadItem
    var onPlay: () -> Void
    var onRetry: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onPlay) {
                ZStack {
                    ThumbnailView(
                        localFile: DownloadManager.shared.thumbnailURL(for: item),
                        remoteURL: VideoInfo(id: item.videoID, title: item.title).thumbnailURL
                    )
                    if item.status == .completed {
                        Image(systemName: "play.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                }
                .frame(width: 112, height: 63)
            }
            .buttonStyle(.borderless)
            .disabled(item.status != .completed)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                statusView
            }

            Spacer(minLength: 0)

            Menu {
                if item.status == .completed {
                    Button(action: onPlay) { Label("Play", systemImage: "play.fill") }
                }
                if item.isFailed {
                    Button(action: onRetry) { Label("Retry", systemImage: "arrow.clockwise") }
                }
                Button(role: .destructive, action: onDelete) {
                    Label(item.isActive ? "Cancel & delete" : "Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if item.status == .completed { onPlay() } }
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.status {
        case .queued:
            Label("Waiting…", systemImage: "clock").font(.caption).foregroundStyle(.secondary)

        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Preparing…").font(.caption).foregroundStyle(.secondary)
            }

        case .downloading:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: item.progress)
                Text(progressText).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }

        case .merging:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: 1)
                Text("Joining video and audio…").font(.caption2).foregroundStyle(.secondary)
            }

        case .completed:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(completedText).foregroundStyle(.secondary)
            }
            .font(.caption)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var progressText: String {
        let percent = Int((item.progress * 100).rounded())
        let written = ByteCountFormatter.string(fromByteCount: item.bytesWritten, countStyle: .file)
        guard item.totalBytes > 0 else { return "\(written)" }
        let total = ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
        return "\(percent)% · \(written) of \(total)" + heightSuffix
    }

    private var completedText: String {
        let size = ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
        return "Downloaded · " + size + heightSuffix
    }

    private var heightSuffix: String {
        guard let h = item.actualHeight else { return "" }
        return h == item.requestedHeight ? " · \(h)p" : " · \(h)p (closest to \(item.requestedHeight)p)"
    }
}

/// Shows the saved thumbnail, or loads it from YouTube when there is none on disk yet.
struct ThumbnailView: View {
    let localFile: URL?
    let remoteURL: URL

    var body: some View {
        Group {
            if let localFile, let image = UIImage(contentsOfFile: localFile.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                AsyncImage(url: remoteURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
