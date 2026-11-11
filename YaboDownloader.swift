import Foundation
import Photos
import UIKit

enum NetError: LocalizedError {
    case badStatus(Int)
    case empty
    case denied

    var errorDescription: String? {
        switch self {
        case .badStatus(let c): return "HTTP \(c)"
        case .empty: return "响应为空"
        case .denied: return "未获得相册写入权限"
        }
    }
}

enum NetClient {
    static let desktopUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    static func text(_ url: URL, referer: String? = nil) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
                     forHTTPHeaderField: "Accept")
        if let r = referer { req.setValue(r, forHTTPHeaderField: "Referer") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NetError.badStatus(http.statusCode)
        }
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw NetError.empty
        }
        return s
    }
}

/// 下载 + 落盘 + 写相册
actor YaboDownloader {
    static let shared = YaboDownloader()

    private var dir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("yabo", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func download(_ item: MediaItem, referer: String?, index: Int) async throws -> URL {
        var target = item.url
        // 抖音带水印地址换无水印
        if target.absoluteString.contains("playwm") {
            target = URL(string: target.absoluteString.replacingOccurrences(of: "playwm", with: "play")) ?? target
        }

        var req = URLRequest(url: target, timeoutInterval: 60)
        req.setValue(NetClient.desktopUA, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        if let r = referer { req.setValue(r, forHTTPHeaderField: "Referer") }

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NetError.badStatus(http.statusCode)
        }

        let uid = String(UUID().uuidString.prefix(8))
        let name = String(format: "yabo_%03d_%@.%@", index, uid, item.ext)
        let fileURL = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(262_144)
        var written: Int64 = 0
        for try await b in bytes {
            buffer.append(b)
            if buffer.count >= 262_144 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        guard written > 0 else { throw NetError.empty }
        return fileURL
    }

    func saveToAlbum(_ fileURL: URL, isVideo: Bool) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw NetError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opt = PHAssetResourceCreationOptions()
            opt.shouldMoveFile = false
            if isVideo {
                req.addResource(with: .video, fileURL: fileURL, options: opt)
            } else {
                req.addResource(with: .photo, fileURL: fileURL, options: opt)
            }
        }
    }

    func clearCache() {
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }
}
