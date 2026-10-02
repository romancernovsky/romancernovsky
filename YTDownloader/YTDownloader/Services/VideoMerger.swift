import AVFoundation

/// Joins a picture-only file and a sound-only file into one normal .mp4.
/// Uses "passthrough" mode: nothing is re-encoded, so it is fast and keeps the original quality.
enum VideoMerger {

    enum MergeError: LocalizedError {
        case missingTrack
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .missingTrack: return "The downloaded video or audio part is damaged."
            case .exportFailed(let reason): return "Could not join video and audio: \(reason)"
            }
        }
    }

    static func merge(video videoURL: URL, audio audioURL: URL, into outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
        else { throw MergeError.missingTrack }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MergeError.missingTrack }

        try compositionVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        try compositionAudio.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(audioDuration, videoDuration)),
                                             of: audioTrack, at: .zero)

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MergeError.exportFailed("exporter unavailable")
        }

        if #available(iOS 18.0, *) {
            do {
                try await exporter.export(to: outputURL, as: .mp4)
            } catch {
                throw MergeError.exportFailed(error.localizedDescription)
            }
        } else {
            exporter.outputURL = outputURL
            exporter.outputFileType = .mp4
            await exporter.export()
            guard exporter.status == .completed else {
                throw MergeError.exportFailed(exporter.error?.localizedDescription ?? "unknown error")
            }
        }
    }
}
