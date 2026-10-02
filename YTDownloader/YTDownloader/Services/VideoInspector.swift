import Foundation
import YouTubeKit

/// `Stream` alone would clash with Foundation's `Stream` class.
typealias YTStream = YouTubeKit.Stream

/// What exactly to download for one video at one resolution.
enum DownloadPlan: Sendable {
    /// One file that already contains picture and sound (YouTube offers this only for low resolutions).
    case single(YTStream, height: Int)
    /// Separate picture and sound files that are joined after download (all HD resolutions).
    case separate(video: YTStream, audio: YTStream, height: Int)

    var height: Int {
        switch self {
        case .single(_, let h), .separate(_, _, let h): return h
        }
    }
}

/// Asks YouTube which streams (resolutions) exist for a video.
///
/// Only formats that iPhone can play natively and that can be saved as a standard `.mp4`
/// are considered: H.264 ("avc1") video and AAC ("m4a") audio.
actor VideoInspector {

    struct Inspection: Sendable {
        let videoID: String
        let title: String?
        let streams: [YTStream]
        let fetchedAt: Date
        var heights: Set<Int> { VideoInspector.availableHeights(in: streams) }
    }

    enum InspectError: LocalizedError {
        case noCompatibleStream
        var errorDescription: String? {
            "YouTube offers no iPhone-compatible (MP4) version of this video."
        }
    }

    static let shared = VideoInspector()

    /// YouTube stream addresses expire after a few hours, so cached results are reused only briefly.
    private let cacheLifetime: TimeInterval = 60 * 60
    private var cache: [String: Inspection] = [:]

    func inspect(videoID: String, forceRefresh: Bool = false) async throws -> Inspection {
        if !forceRefresh, let cached = cache[videoID],
           Date().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached
        }
        let (streams, title) = try await Self.fetch(videoID: videoID)
        let inspection = Inspection(videoID: videoID, title: title, streams: streams, fetchedAt: Date())
        cache[videoID] = inspection
        return inspection
    }

    private nonisolated static func fetch(videoID: String) async throws -> ([YTStream], String?) {
        // Local extraction first; if YouTube changed something, fall back to YouTubeKit's remote helper.
        let youtube = YouTube(videoID: videoID, methods: [.local, .remote])
        let streams = try await youtube.streams
        let title = try? await youtube.metadata?.title
        return (streams, title)
    }

    // MARK: - Stream selection

    nonisolated static func isCompatibleVideo(_ s: YTStream) -> Bool {
        s.includesVideoTrack && s.fileExtension == .mp4 && s.videoCodec == .avc1 && s.videoResolution != nil
    }

    nonisolated static func isCompatibleAudio(_ s: YTStream) -> Bool {
        !s.includesVideoTrack && s.includesAudioTrack && s.fileExtension == .m4a
    }

    nonisolated static func availableHeights(in streams: [YTStream]) -> Set<Int> {
        let video = streams.filter(isCompatibleVideo)
        let hasAudio = streams.contains(where: isCompatibleAudio)
        var heights = Set<Int>()
        for s in video {
            guard let h = s.videoResolution else { continue }
            if s.includesAudioTrack || hasAudio { heights.insert(h) }
        }
        return heights
    }

    /// Picks the requested height or, if that video does not have it, the closest lower one
    /// (or the lowest available one when everything is higher).
    nonisolated static func plan(for streams: [YTStream], preferredHeight: Int) throws -> DownloadPlan {
        let heights = availableHeights(in: streams)
        guard !heights.isEmpty else { throw InspectError.noCompatibleStream }

        let height: Int
        if heights.contains(preferredHeight) {
            height = preferredHeight
        } else if let lower = heights.filter({ $0 < preferredHeight }).max() {
            height = lower
        } else {
            height = heights.min()!
        }

        let candidates = streams.filter { isCompatibleVideo($0) && $0.videoResolution == height }

        if let single = candidates.filter(\.includesAudioTrack).max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) {
            return .single(single, height: height)
        }
        guard let video = candidates.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }),
              let audio = streams.filter(isCompatibleAudio).max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) })
        else { throw InspectError.noCompatibleStream }
        return .separate(video: video, audio: audio, height: height)
    }
}
