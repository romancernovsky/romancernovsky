import Foundation

/// The official YouTube Data API v3, used with the signed-in user's permission
/// to list *their own* playlists (including private ones) and the videos in them.
struct YouTubeAPI {

    struct Channel {
        let title: String
        let thumbnailURL: URL?
        let likesPlaylistID: String?
    }

    struct Playlist: Identifiable, Hashable {
        let id: String
        let title: String
        let itemCount: Int?
        let thumbnailURL: URL?
        let privacy: String?        // "public", "unlisted", "private"
    }

    enum APIError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(403, let message) where message.contains("quota"):
                return "Today's YouTube API quota is used up. Try again tomorrow."
            case .http(403, let message) where message.contains("accessNotConfigured") || message.contains("has not been used"):
                return "The YouTube Data API is not enabled in your Google Cloud project (see README)."
            case .http(let code, _):
                return "YouTube API error \(code)."
            }
        }
    }

    private let base = "https://www.googleapis.com/youtube/v3/"

    // MARK: - Calls

    func myChannel() async throws -> Channel {
        let json = try await get("channels", ["part": "snippet,contentDetails", "mine": "true"])
        guard let item = (json["items"] as? [[String: Any]])?.first else {
            throw APIError.http(404, "This Google account has no YouTube channel.")
        }
        let snippet = item["snippet"] as? [String: Any]
        let related = (item["contentDetails"] as? [String: Any])?["relatedPlaylists"] as? [String: Any]
        return Channel(
            title: snippet?["title"] as? String ?? "YouTube account",
            thumbnailURL: Self.thumbnail(in: snippet),
            likesPlaylistID: related?["likes"] as? String
        )
    }

    /// All playlists the user created, plus "Liked videos" first.
    func myPlaylists() async throws -> [Playlist] {
        var playlists: [Playlist] = []
        var pageToken: String?
        repeat {
            var params = ["part": "snippet,contentDetails,status", "mine": "true", "maxResults": "50"]
            if let pageToken { params["pageToken"] = pageToken }
            let json = try await get("playlists", params)
            for item in json["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                let snippet = item["snippet"] as? [String: Any]
                playlists.append(Playlist(
                    id: id,
                    title: snippet?["title"] as? String ?? "Playlist",
                    itemCount: (item["contentDetails"] as? [String: Any])?["itemCount"] as? Int,
                    thumbnailURL: Self.thumbnail(in: snippet),
                    privacy: (item["status"] as? [String: Any])?["privacyStatus"] as? String
                ))
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil && playlists.count < 1000

        if let likes = try? await myChannel().likesPlaylistID {
            playlists.insert(Playlist(id: likes, title: "Liked videos", itemCount: nil,
                                      thumbnailURL: nil, privacy: "private"), at: 0)
        }
        return playlists
    }

    /// Videos in a playlist the user can see (works for private playlists too).
    func playlistVideos(playlistID: String, limit: Int = 1000) async throws -> [VideoInfo] {
        var videos: [VideoInfo] = []
        var pageToken: String?
        repeat {
            var params = ["part": "snippet,status", "playlistId": playlistID, "maxResults": "50"]
            if let pageToken { params["pageToken"] = pageToken }
            let json = try await get("playlistItems", params)
            for item in json["items"] as? [[String: Any]] ?? [] {
                let snippet = item["snippet"] as? [String: Any]
                let resource = snippet?["resourceId"] as? [String: Any]
                guard let id = resource?["videoId"] as? String else { continue }
                let title = snippet?["title"] as? String ?? id
                // Deleted videos are still listed by YouTube with placeholder titles.
                if title == "Deleted video" || title == "Private video" { continue }
                videos.append(VideoInfo(id: id, title: title))
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil && videos.count < limit
        return videos
    }

    // MARK: - Plumbing

    private func get(_ path: String, _ params: [String: String]) async throws -> [String: Any] {
        let token = try await GoogleAuth.shared.validAccessToken()
        var components = URLComponents(string: base + path)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw APIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func thumbnail(in snippet: [String: Any]?) -> URL? {
        let thumbs = snippet?["thumbnails"] as? [String: Any]
        for size in ["medium", "high", "default"] {
            if let url = (thumbs?[size] as? [String: Any])?["url"] as? String {
                return URL(string: url)
            }
        }
        return nil
    }
}
