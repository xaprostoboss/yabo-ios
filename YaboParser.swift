import Foundation

/// 链接识别 + JSON/HTML 媒体地址提取，规则与 Android 端 classes.dex 内正则一一对应
enum YaboParser {

    // MARK: 平台识别

    private static let idRules: [(Platform, String)] = [
        (.douyin,       #"(?:/share/(?:note|video|slides)/|/video/|/note/)(\d{15,25})"#),
        (.xiaohongshu,  #"(?:explore|discovery/item|item|note)/([0-9a-fA-F]{20,32})"#),
        (.kuaishou,     #"(?:short-video|photo|fw/photo|photoId=)/([A-Za-z0-9_-]{6,})"#),
    ]

    static func detect(_ text: String) -> (Platform, String) {
        for (pf, pattern) in idRules {
            if let m = firstMatch(pattern, in: text, group: 1) {
                return (pf, m)
            }
        }
        let low = text.lowercased()
        if low.contains("douyin") || low.contains("iesdouyin") { return (.douyin, "") }
        if low.contains("xiaohongshu") || low.contains("xhslink") { return (.xiaohongshu, "") }
        if low.contains("kuaishou") || low.contains("chenzhongtech") { return (.kuaishou, "") }
        return (.unknown, "")
    }

    /// 从分享文案里抽出第一个 http(s) 链接，去掉中文标点与尾部字符
    static func extractURL(from text: String) -> URL? {
        let pattern = #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#
        guard let raw = firstMatch(pattern, in: text, group: 0) else { return nil }
        var s = raw
        while let last = s.last, "，。,.;；)）】]》>\"'".contains(last) {
            s.removeLast()
        }
        return URL(string: s)
    }

    /// 分享短链 -> 可抓取的移动端落地页
    static func landingURL(platform: Platform, itemID: String, original: URL?) -> URL? {
        if let o = original, !o.absoluteString.contains("v.douyin.com/") {
            return o
        }
        switch platform {
        case .douyin:
            if !itemID.isEmpty { return URL(string: "https://www.iesdouyin.com/share/video/\(itemID)/") }
            return URL(string: "https://www.douyin.com/")
        case .xiaohongshu:
            if !itemID.isEmpty { return URL(string: "https://www.xiaohongshu.com/explore/\(itemID)") }
            return URL(string: "https://www.xiaohongshu.com/")
        case .kuaishou:
            if !itemID.isEmpty { return URL(string: "https://v.m.chenzhongtech.com/fw/photo/\(itemID)") }
            return URL(string: "https://www.kuaishou.com/")
        case .unknown:
            return original
        }
    }

    // MARK: 媒体提取

    private static let videoPatterns: [String] = [
        #""srcNoMark"\s*:\s*"([^"]+)""#,
        #""play_addr"\s*:\s*\{[\s\S]{0,800}?"url_list"\s*:\s*\[\s*"([^"]+)""#,
        #""playUrl"\s*:\s*"([^"]+)""#,
        #""photoUrl"\s*:\s*"([^"]+)""#,
        #""mainMvUrls"\s*:\s*\[[\s\S]{0,1200}?"url"\s*:\s*"([^"]+)""#,
        #""masterUrl"\s*:\s*"([^"]+)""#,
        #""backupUrls"\s*:\s*\[\s*"([^"]+)""#,
        #""adaptationSet"[\s\S]{0,1500}?"url"\s*:\s*"([^"]+)""#,
        #"(https?:\/\/[^"'\\\s]*(?:douyinvod|zjcdn|snssdk|xhscdn|kwaicdn|kscdn|yximgs)[^"'\\\s]*)"#,
        #"<video[^>]+src="(https?://[^"]+)""#,
        #""(https?://sns-video[^"]+)""#,
    ]

    private static let imagePatterns: [String] = [
        #""url_list"\s*:\s*\[\s*"(https?:[^"]*(?:douyinpic|byteimg|xhscdn|kwaicdn|kscdn|yximgs|kwimgs|ndcimgs)[^"]*)""#,
        #""(\/[^"]+?\.(?:jpg|jpeg|png|webp))""#,
    ]

    static func parseMedia(from text: String, baseURL: URL?) -> [MediaItem] {
        var seen = Set<String>()
        var out: [MediaItem] = []

        func append(_ raw: String, kind: MediaKind) {
            var s = raw
                .replacingOccurrences(of: #"\u002F"#, with: "/")
                .replacingOccurrences(of: #"\/"#, with: "/")
                .replacingOccurrences(of: #"\u0026"#, with: "&")
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)

            var absolute: URL?
            if s.hasPrefix("http") {
                absolute = URL(string: s)
            } else if s.hasPrefix("//") {
                absolute = URL(string: "https:" + s)
            } else if s.hasPrefix("/"), let base = baseURL {
                absolute = URL(string: s, relativeTo: base)?.absoluteURL
            }
            guard var url = absolute else { return }

            // 图片地址统一要原图
            if kind == .image, let u = URL(string: cleanImageURL(url.absoluteString)) { url = u }

            guard seen.insert(url.absoluteString).inserted else { return }
            out.append(MediaItem(kind: kind, url: url, host: url.host ?? "", title: ""))
        }

        for p in videoPatterns {
            for m in allMatches(p, in: text, group: 1) { append(m, kind: .video) }
        }
        for p in imagePatterns {
            for m in allMatches(p, in: text, group: 1) { append(m, kind: .image) }
        }

        // 视频优先，图片在后；同一 host 顺序稳定
        return out.sorted { a, b in
            if a.kind != b.kind { return a.kind == .video }
            return a.url.absoluteString < b.url.absoluteString
        }
    }

    /// 抖音/小红书图片直链去掉缩放系数，拿原图
    static func cleanImageURL(_ s: String) -> String {
        var u = s
        u = u.replacingOccurrences(of: #"~tplv-[^/]+"#, with: "~tplv-origin", options: .regularExpression)
        return u
    }

    // MARK: 正则工具

    static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        allMatches(pattern, in: text, group: group).first
    }

    static func allMatches(_ pattern: String, in text: String, group: Int) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out: [String] = []
        re.enumerateMatches(in: text, options: [], range: range) { result, _, _ in
            guard let r = result, group < r.numberOfRanges else { return }
            let g = r.range(at: group)
            guard g.location != NSNotFound else { return }
            out.append(ns.substring(with: g))
        }
        return out
    }
}
