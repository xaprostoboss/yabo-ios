import Foundation

enum MediaKind: String, Codable, Hashable {
    case video
    case image
}

struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    let kind: MediaKind
    let url: URL
    var host: String = ""
    var title: String = ""

    var ext: String {
        let p = url.path.lowercased()
        if p.hasSuffix(".png") { return "png" }
        if p.hasSuffix(".webp") { return "webp" }
        if p.hasSuffix(".jpeg") || p.hasSuffix(".jpg") { return "jpg" }
        if kind == .video { return "mp4" }
        return "jpg"
    }
}

struct ParseOutcome {
    var platform: String = "unknown"
    var itemID: String = ""
    var pageURL: URL?
    var items: [MediaItem] = []
    var logs: [String] = []
}

enum Platform: String {
    case douyin, xiaohongshu, kuaishou, unknown

    var display: String {
        switch self {
        case .douyin: return "抖音"
        case .xiaohongshu: return "小红书"
        case .kuaishou: return "快手"
        case .unknown: return "未知来源"
        }
    }
}
