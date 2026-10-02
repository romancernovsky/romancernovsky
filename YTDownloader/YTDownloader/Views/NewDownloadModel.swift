import Foundation
import Observation

/// Logic behind the "Download" tab: read the link, list the videos, find their resolutions.
@Observable
@MainActor
final class NewDownloadModel {

    enum Phase: Equatable {
        case idle
        case working(String)
        case ready
        case failed(String)
    }

    struct Row: Identifiable {
        var video: VideoInfo
        var heights: Set<Int>?      // nil = still checking
        var error: String?
        var selected = true
        var id: String { video.id }
    }

    var link = ""
    private(set) var phase: Phase = .idle
    private(set) var collectionTitle: String?
    private(set) var isPlaylist = false
    var rows: [Row] = []
    private(set) var options: [ResolutionOption] = []
    var selectedHeight: Int?

    @ObservationIgnored private var lookupTask: Task<Void, Never>?

    /// How many videos are checked at the same time.
    private let parallelChecks = 4

    var selectedVideos: [VideoInfo] {
        rows.filter { $0.selected && $0.error == nil }.map(\.video)
    }

    var allSelected: Bool {
        rows.filter { $0.error == nil }.allSatisfy(\.selected)
    }

    func toggleAll() {
        let newValue = !allSelected
        for i in rows.indices where rows[i].error == nil { rows[i].selected = newValue }
    }

    func toggle(_ row: Row) {
        guard row.error == nil, let i = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[i].selected.toggle()
    }

    func reset() {
        lookupTask?.cancel()
        link = ""
        phase = .idle
        rows = []
        options = []
        selectedHeight = nil
        collectionTitle = nil
        isPlaylist = false
    }

    func cancel() {
        lookupTask?.cancel()
        phase = rows.contains(where: { $0.heights != nil }) ? .ready : .idle
        buildOptions()
    }

    func startLookup() {
        lookupTask?.cancel()
        lookupTask = Task { await lookup() }
    }

    // MARK: - Lookup

    private func lookup() async {
        rows = []
        options = []
        selectedHeight = nil
        collectionTitle = nil

        guard let parsed = YouTubeLink.parse(link) else {
            phase = .failed("This doesn't look like a YouTube video or playlist link.")
            return
        }

        // 1) Which videos?
        switch parsed {
        case .video(let id):
            isPlaylist = false
            rows = [Row(video: VideoInfo(id: id, title: "Video \(id)"))]
        case .playlist(let id, let startVideoID):
            isPlaylist = true
            phase = .working("Reading playlist…")
            do {
                let result = try await PlaylistFetcher().fetchVideos(playlistID: id, startVideoID: startVideoID)
                if Task.isCancelled { return }
                collectionTitle = result.title
                rows = result.videos.map { Row(video: $0) }
            } catch {
                if Task.isCancelled { return }
                // Could not read the playlist – fall back to the single video in the link, if any.
                if let startVideoID {
                    isPlaylist = false
                    rows = [Row(video: VideoInfo(id: startVideoID, title: "Video \(startVideoID)"))]
                } else {
                    phase = .failed(error.localizedDescription)
                    return
                }
            }
        }

        // 2) Which resolutions does each video have?
        await checkResolutions()
        if Task.isCancelled { return }

        buildOptions()
        if options.isEmpty {
            let reason = rows.compactMap(\.error).first ?? "No downloadable versions were found."
            phase = .failed(reason)
        } else {
            phase = .ready
        }
    }

    private func checkResolutions() async {
        let ids = rows.map(\.video.id)
        var done = 0
        phase = .working(ids.count == 1 ? "Checking available resolutions…" : "Checking resolutions 0 of \(ids.count)…")

        await withTaskGroup(of: (Int, VideoInspector.Inspection?, String?).self) { group in
            func add(_ index: Int) {
                let id = ids[index]
                group.addTask {
                    do {
                        return (index, try await VideoInspector.shared.inspect(videoID: id), nil)
                    } catch {
                        return (index, nil, error.localizedDescription)
                    }
                }
            }

            var nextIndex = 0
            while nextIndex < min(parallelChecks, ids.count) { add(nextIndex); nextIndex += 1 }

            while let result = await group.next() {
                let (index, inspection, error) = result
                if Task.isCancelled { group.cancelAll(); return }
                if let inspection {
                    rows[index].heights = inspection.heights
                    if let title = inspection.title, !title.isEmpty { rows[index].video.title = title }
                    if inspection.heights.isEmpty {
                        rows[index].error = VideoInspector.InspectError.noCompatibleStream.localizedDescription
                    }
                } else {
                    rows[index].error = error ?? "Not available"
                }
                if rows[index].error != nil { rows[index].selected = false }

                done += 1
                if ids.count > 1 { phase = .working("Checking resolutions \(done) of \(ids.count)…") }
                if nextIndex < ids.count { add(nextIndex); nextIndex += 1 }
            }
        }
        if collectionTitle == nil, rows.count == 1 { collectionTitle = rows[0].video.title }
    }

    private func buildOptions() {
        var counts: [Int: Int] = [:]
        for row in rows {
            for h in row.heights ?? [] { counts[h, default: 0] += 1 }
        }
        options = counts.map { ResolutionOption(height: $0.key, availableCount: $0.value) }
            .sorted { $0.height > $1.height }

        // Sensible default: 1080p, or the best below it, or the lowest one.
        let heights = options.map(\.height)
        if selectedHeight == nil || !heights.contains(selectedHeight!) {
            selectedHeight = heights.filter { $0 <= 1080 }.max() ?? heights.min()
        }
    }
}
