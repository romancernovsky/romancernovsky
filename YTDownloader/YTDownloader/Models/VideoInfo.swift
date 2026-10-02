import Foundation

/// A single YouTube video found from the link the user entered.
struct VideoInfo: Identifiable, Hashable, Sendable {
    let id: String          // YouTube video ID, e.g. "dQw4w9WgXcQ"
    var title: String

    /// Thumbnail served by YouTube's image CDN. Always exists for public videos.
    var thumbnailURL: URL {
        URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!
    }
}

/// One resolution option that can be offered to the user.
struct ResolutionOption: Identifiable, Hashable {
    let height: Int                 // 360, 720, 1080 ...
    let availableCount: Int         // how many of the inspected videos offer exactly this height

    var id: Int { height }
    var label: String { "\(height)p" }
}
