import Foundation
import Observation
import UIKit

/// Keeps the list of downloads, runs them (2 at a time), and handles retry / delete.
/// The list is saved to disk so the library survives app restarts.
@Observable
@MainActor
final class DownloadManager {

    static let shared = DownloadManager()

    private(set) var items: [DownloadItem] = []

    /// How many videos download at the same time.
    private let maxConcurrent = 2

    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let storage = StorageManager.shared

    private var libraryFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("library.json")
    }

    private init() {
        load()
        // Anything that was in progress when the app closed continues automatically.
        for index in items.indices where items[index].isActive {
            items[index].status = .queued
        }
        scheduleNext()
    }

    var activeCount: Int { items.filter(\.isActive).count }
    var failedCount: Int { items.filter(\.isFailed).count }

    // MARK: - Public actions

    func enqueue(_ videos: [VideoInfo], height: Int) {
        let bookmark = storage.customFolderBookmark
        let newItems = videos.map { DownloadItem(video: $0, requestedHeight: height, folderBookmark: bookmark) }
        items.insert(contentsOf: newItems, at: 0)
        save()
        scheduleNext()
    }

    func retry(_ item: DownloadItem) {
        guard let index = index(of: item.id), items[index].isFailed else { return }
        items[index].status = .queued
        save()
        scheduleNext()
    }

    func retryAllFailed() {
        for index in items.indices where items[index].isFailed {
            items[index].status = .queued
        }
        save()
        scheduleNext()
    }

    func delete(_ item: DownloadItem) {
        running[item.id]?.cancel()
        running[item.id] = nil

        if let url = storage.fileURL(for: item) {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: StorageManager.workFolder(for: item.id))
        if let thumb = item.thumbnailFileName,
           !items.contains(where: { $0.id != item.id && $0.thumbnailFileName == thumb }) {
            try? FileManager.default.removeItem(at: StorageManager.thumbnailFolder.appendingPathComponent(thumb))
        }
        items.removeAll { $0.id == item.id }
        save()
        scheduleNext()
    }

    func thumbnailURL(for item: DownloadItem) -> URL? {
        item.thumbnailFileName.map { StorageManager.thumbnailFolder.appendingPathComponent($0) }
    }

    // MARK: - Queue

    private func scheduleNext() {
        while running.count < maxConcurrent,
              let next = items.last(where: { $0.status == .queued && running[$0.id] == nil }) { // oldest first
            let id = next.id
            running[id] = Task { [weak self] in
                await self?.process(id)
                self?.running[id] = nil
                self?.scheduleNext()
            }
        }
        updateKeepAlive()
    }

    /// While downloads run: keep the screen on and ask iOS for extra time if the app goes to the background.
    private func updateKeepAlive() {
        let busy = !running.isEmpty
        UIApplication.shared.isIdleTimerDisabled = busy
        if busy, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Downloads") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        } else if !busy {
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - Processing one video

    private func process(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        update(id) { $0.status = .preparing; $0.progress = 0 }

        do {
            // Always ask YouTube for fresh stream addresses: old ones expire after a few hours.
            let inspection = try await VideoInspector.shared.inspect(videoID: item.videoID, forceRefresh: true)
            let plan = try VideoInspector.plan(for: inspection.streams, preferredHeight: item.requestedHeight)
            update(id) {
                $0.actualHeight = plan.height
                if let title = inspection.title, !title.isEmpty { $0.title = title }
            }

            async let thumbnail = saveThumbnail(videoID: item.videoID)
            let work = StorageManager.workFolder(for: id)
            let readyFile: URL

            switch plan {
            case .single(let stream, _):
                let file = work.appendingPathComponent("single-\(Self.partKey(stream)).mp4")
                let total = await ChunkedDownloader.shared.remoteSize(of: stream.url) ?? 0
                update(id) { $0.status = .downloading; $0.totalBytes = total }
                try await ChunkedDownloader.shared.download(stream.url, to: file) { [weak self] written, _ in
                    Task { @MainActor in self?.reportProgress(id, written: written, total: total) }
                }
                readyFile = file

            case .separate(let video, let audio, _):
                let videoFile = work.appendingPathComponent("video-\(Self.partKey(video)).mp4")
                let audioFile = work.appendingPathComponent("audio-\(Self.partKey(audio)).m4a")
                async let videoSizeRequest = ChunkedDownloader.shared.remoteSize(of: video.url)
                async let audioSizeRequest = ChunkedDownloader.shared.remoteSize(of: audio.url)
                let videoSize = await videoSizeRequest ?? 0
                let audioSize = await audioSizeRequest ?? 0
                let total = videoSize + audioSize
                update(id) { $0.status = .downloading; $0.totalBytes = total }

                try await ChunkedDownloader.shared.download(video.url, to: videoFile) { [weak self] written, _ in
                    Task { @MainActor in self?.reportProgress(id, written: written, total: total) }
                }
                let videoDone = ChunkedDownloader.fileSize(videoFile)
                try await ChunkedDownloader.shared.download(audio.url, to: audioFile) { [weak self] written, _ in
                    Task { @MainActor in self?.reportProgress(id, written: videoDone + written, total: total) }
                }

                update(id) { $0.status = .merging; $0.progress = 1 }
                let merged = work.appendingPathComponent("merged.mp4")
                try await VideoMerger.merge(video: videoFile, audio: audioFile, into: merged)
                readyFile = merged
            }

            try Task.checkCancellation()

            // Move the finished video into the destination "Video" folder.
            guard let current = items.first(where: { $0.id == id }),
                  let folder = storage.videoFolder(for: current.folderBookmark) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The download folder is no longer accessible. Choose it again in Settings."])
            }
            let name = StorageManager.uniqueFileName(title: current.title, height: plan.height, in: folder)
            try FileManager.default.moveItem(at: readyFile, to: folder.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: work)

            let thumbName = await thumbnail
            let size = ChunkedDownloader.fileSize(folder.appendingPathComponent(name))
            update(id) {
                $0.fileName = name
                $0.thumbnailFileName = thumbName
                $0.status = .completed
                $0.progress = 1
                $0.bytesWritten = size
                $0.totalBytes = size
                $0.completedAt = Date()
            }
            save()
        } catch is CancellationError {
            // Deleted by the user – nothing to report.
        } catch {
            update(id) { $0.status = .failed(message: error.localizedDescription) }
            save()
        }
    }

    private func reportProgress(_ id: UUID, written: Int64, total: Int64) {
        update(id) {
            guard $0.status == .downloading else { return }
            $0.bytesWritten = written
            if total > 0 { $0.progress = min(1, Double(written) / Double(total)) }
        }
    }

    /// Saves the video's thumbnail picture so the library also looks good offline.
    private nonisolated func saveThumbnail(videoID: String) async -> String? {
        let name = "\(videoID).jpg"
        let file = StorageManager.thumbnailFolder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { return name }
        let url = VideoInfo(id: videoID, title: "").thumbnailURL
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return (try? data.write(to: file)) != nil ? name : nil
    }

    // MARK: - Helpers

    /// Identifies a YouTube format (its "itag", e.g. 137 = 1080p H.264) so a partial file
    /// is only resumed with the same format on Retry.
    private nonisolated static func partKey(_ stream: YTStream) -> String {
        let itag = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value
        return itag ?? "\(stream.videoResolution ?? 0)"
    }

    private func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let index = index(of: id) else { return }
        change(&items[index])
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile),
              let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: libraryFile, options: .atomic)
    }
}
