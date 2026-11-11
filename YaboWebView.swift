import SwiftUI
import WebKit

/// 承接 WKWebView 的 JS 回传
@MainActor
final class WebBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var liveItems: [MediaItem] = []
    @Published var logs: [String] = []
    @Published var pageText: String = ""
    @Published var pageTitle: String = ""

    private var seen = Set<String>()
    private var detailBuffer = ""

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let op = body["op"] as? String else { return }
        let kindStr = body["kind"] as? String ?? "video"
        let urlStr = body["url"] as? String ?? ""
        let text = body["text"] as? String ?? ""

        Task { @MainActor in
            switch op {
            case "data":
                let kind: MediaKind = (kindStr == "image") ? .image : .video
                self.accept(kind: kind, raw: urlStr)
            case "detail":
                self.detailBuffer += text
                if self.detailBuffer.count > 2_000_000 {
                    self.detailBuffer = String(self.detailBuffer.suffix(1_000_000))
                }
                self.scanBuffer()
            case "log":
                self.logs.append(text)
                if self.logs.count > 80 { self.logs.removeFirst(self.logs.count - 80) }
            default:
                break
            }
        }
    }

    private func scanBuffer() {
        for item in YaboParser.parseMedia(from: detailBuffer, baseURL: nil) {
            if seen.insert(item.url.absoluteString).inserted {
                liveItems.append(item)
            }
        }
    }

    private func accept(kind: MediaKind, raw: String) {
        var s = raw
            .replacingOccurrences(of: #"\u002F"#, with: "/")
            .replacingOccurrences(of: #"\/"#, with: "/")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("http") else { return }
        if kind == .image { s = YaboParser.cleanImageURL(s) }
        guard let url = URL(string: s) else { return }
        guard seen.insert(url.absoluteString).inserted else { return }
        liveItems.append(MediaItem(kind: kind, url: url, host: url.host ?? ""))
    }

    func reset() {
        liveItems.removeAll()
        logs.removeAll()
        detailBuffer = ""
        seen.removeAll()
    }
}

struct YaboWebView: UIViewRepresentable {
    let url: URL
    let bridge: WebBridge
    @Binding var progress: Double
    @Binding var finished: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(bridge, name: "yabo")
        cfg.userContentController.addUserScript(
            WKUserScript(source: JSPayload.bridgeShim, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        cfg.userContentController.addUserScript(
            WKUserScript(source: JSPayload.networkHook, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.allowsInlineMediaPlayback = true

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.addObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: [.new], context: nil)
        wv.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if context.coordinator.currentURL != url.absoluteString {
            context.coordinator.currentURL = url.absoluteString
            wv.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }
    }

    static func dismantleUIView(_ wv: WKWebView, coordinator: Coordinator) {
        wv.stopLoading()
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "yabo")
        wv.removeObserver(coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: YaboWebView
        var currentURL: String?

        init(_ parent: YaboWebView) {
            self.parent = parent
            self.currentURL = parent.url.absoluteString
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            guard keyPath == #keyPath(WKWebView.estimatedProgress),
                  let wv = object as? WKWebView else { return }
            DispatchQueue.main.async { self.parent.progress = wv.estimatedProgress }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(JSPayload.domScanner, completionHandler: nil)
            DispatchQueue.main.async { self.parent.finished = true }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.finished = true }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.finished = true }
        }
    }
}
