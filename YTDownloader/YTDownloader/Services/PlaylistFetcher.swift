import Foundation

/// Reads the list of videos in a YouTube playlist using YouTube's internal web API ("InnerTube"),
/// the same API the youtube.com website uses.
///
/// YouTube changes the exact JSON layout from time to time, so instead of decoding a fixed
/// structure we walk the whole JSON tree and pick up every object that looks like a playlist entry.
struct PlaylistFetcher {

    enum FetchError: LocalizedError {
        case empty
        var errorDescription: String? {
            "The playlist is empty, private, or could not be read."
        }
    }

    private let endpoint = "https://www.youtube.com/youtubei/v1/"
    private let clientVersion = "2.20250925.01.00"
    /// Safety limit so a huge playlist cannot keep us busy forever.
    private let maxVideos = 1000

    func fetchVideos(playlistID: String, startVideoID: String?) async throws -> (title: String?, videos: [VideoInfo]) {
        var collected: [VideoInfo] = []
        var seen = Set<String>()
        var title: String?

        func absorb(_ json: Any) -> [String] {
            let page = Self.extract(from: json)
            for video in page.videos where !seen.contains(video.id) {
                seen.insert(video.id)
                collected.append(video)
            }
            if title == nil { title = page.playlistTitle }
            return page.continuations
        }

        // 1) Regular playlists: the "browse" endpoint, page by page.
        var tokens = absorb(try await post("browse", body: ["browseId": "VL" + playlistID]))
        var usedTokens = Set<String>()
        while let token = tokens.first(where: { !usedTokens.contains($0) }), collected.count < maxVideos {
            usedTokens.insert(token)
            let before = collected.count
            tokens = absorb(try await post("browse", body: ["continuation": token]))
            if collected.count == before { break }
        }

        // 2) Mixes / radio lists ("RD...") cannot be browsed; the watch-page queue works for them.
        if collected.isEmpty {
            var body: [String: Any] = ["playlistId": playlistID]
            if let startVideoID { body["videoId"] = startVideoID }
            _ = absorb(try await post("next", body: body))
        }

        guard !collected.isEmpty else { throw FetchError.empty }
        return (title, Array(collected.prefix(maxVideos)))
    }

    // MARK: - Networking

    private func post(_ path: String, body: [String: Any]) async throws -> Any {
        var request = URLRequest(url: URL(string: endpoint + path + "?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")

        var payload = body
        payload["context"] = [
            "client": [
                "clientName": "WEB",
                "clientVersion": clientVersion,
                "hl": "en",
                "gl": "US",
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - JSON walking

    private struct Page {
        var videos: [VideoInfo] = []
        var lockupVideos: [VideoInfo] = []
        var continuations: [String] = []
        var playlistTitle: String?
    }

    private static func extract(from json: Any) -> Page {
        var page = Page()
        walk(json, into: &page)
        // The newer layout is only trusted when the classic one is absent, so that
        // "recommended" videos elsewhere on the page are not mixed into the playlist.
        if page.videos.isEmpty { page.videos = page.lockupVideos }
        return page
    }

    private static func walk(_ node: Any, into page: inout Page) {
        if let dict = node as? [String: Any] {
            // Classic playlist row, and the queue row used on watch pages.
            for key in ["playlistVideoRenderer", "playlistPanelVideoRenderer"] {
                if let r = dict[key] as? [String: Any], let id = r["videoId"] as? String {
                    // Deleted / private videos have no playable title – skip them.
                    if let title = text(r["title"]), !title.isEmpty,
                       r["isPlayable"] as? Bool ?? true {
                        page.videos.append(VideoInfo(id: id, title: title))
                    }
                }
            }
            // Newer "view model" layout.
            if let lockup = dict["lockupViewModel"] as? [String: Any],
               let id = lockup["contentId"] as? String, id.count == 11,
               (lockup["contentType"] as? String)?.contains("VIDEO") ?? true {
                let meta = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
                let title = ((meta?["title"] as? [String: Any])?["content"] as? String) ?? id
                page.lockupVideos.append(VideoInfo(id: id, title: title))
            }
            // Next-page tokens.
            if let command = dict["continuationCommand"] as? [String: Any],
               let token = command["token"] as? String {
                page.continuations.append(token)
            }
            if page.playlistTitle == nil,
               let header = dict["playlistHeaderRenderer"] as? [String: Any] {
                page.playlistTitle = text(header["title"])
            }
            if page.playlistTitle == nil,
               let meta = dict["playlistMetadataRenderer"] as? [String: Any] {
                page.playlistTitle = meta["title"] as? String
            }
            for value in dict.values { walk(value, into: &page) }
        } else if let array = node as? [Any] {
            for value in array { walk(value, into: &page) }
        }
    }

    /// YouTube text is either {"simpleText": "..."} or {"runs": [{"text": "..."}, ...]}.
    private static func text(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return node as? String }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        if let content = dict["content"] as? String { return content }
        return nil
    }
}
