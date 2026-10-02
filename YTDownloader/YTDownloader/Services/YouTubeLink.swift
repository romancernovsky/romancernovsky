import Foundation

/// Understands the different shapes of YouTube links.
///
/// Supported examples:
///  - https://www.youtube.com/watch?v=VIDEO_ID
///  - https://www.youtube.com/watch?v=VIDEO_ID&list=PLAYLIST_ID   (treated as playlist)
///  - https://www.youtube.com/playlist?list=PLAYLIST_ID
///  - https://youtu.be/VIDEO_ID
///  - https://www.youtube.com/shorts/VIDEO_ID
///  - https://www.youtube.com/embed/VIDEO_ID, /live/VIDEO_ID
///  - https://m.youtube.com/..., https://music.youtube.com/...
enum YouTubeLink: Equatable {
    case video(id: String)
    case playlist(id: String, startVideoID: String?)

    static func parse(_ text: String) -> YouTubeLink? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }

        // A bare 11-character video ID is accepted too.
        if raw.count == 11, raw.allSatisfy(isIDCharacter) {
            return .video(id: raw)
        }
        if !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }

        guard let components = URLComponents(string: raw),
              let host = components.host?.lowercased() else { return nil }

        let query = components.queryItems ?? []
        let v = query.first(where: { $0.name == "v" })?.value
        let list = query.first(where: { $0.name == "list" })?.value
        let pathParts = components.path.split(separator: "/").map(String.init)

        let isYouTube = host == "youtu.be" || host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com")
        guard isYouTube else { return nil }

        var videoID: String?
        if host == "youtu.be" {
            videoID = pathParts.first
        } else if let v {
            videoID = v
        } else if pathParts.count >= 2, ["shorts", "embed", "live", "v"].contains(pathParts[0]) {
            videoID = pathParts[1]
        }
        if let id = videoID, !isValidVideoID(id) { videoID = nil }

        if let list, !list.isEmpty {
            return .playlist(id: list, startVideoID: videoID)
        }
        if let videoID {
            return .video(id: videoID)
        }
        return nil
    }

    private static func isIDCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }

    private static func isValidVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy(isIDCharacter)
    }
}
