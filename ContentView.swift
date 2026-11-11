import SwiftUI
import UIKit

@MainActor
final class YaboViewModel: ObservableObject {
    @Published var input: String = ""
    @Published var status: String = "待命 // READY"
    @Published var items: [MediaItem] = []
    @Published var busy: Bool = false
    @Published var progress: Double = 0
    @Published var finished: Bool = false
    @Published var webURL: URL?
    @Published var showWeb: Bool = false
    @Published var savedCount: Int = 0
    @Published var platformName: String = "—"

    let bridge = WebBridge()

    var canDownload: Bool { !items.isEmpty && !busy }

    // MARK: 主流程

    func parse() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            status = "剪贴板是空的，先在小红书/快手/抖音里点“复制链接”"
            return
        }
        guard !busy else { return }

        busy = true
        progress = 0
        savedCount = 0
        items = []
        bridge.reset()
        webURL = nil
        showWeb = false
        finished = false

        Task { await run(text) }
    }

    private func run(_ text: String) async {
        let (platform, itemID) = YaboParser.detect(text)
        platformName = platform.display
        let original = YaboParser.extractURL(from: text)

        status = "识别：\(platform.display) \(itemID.isEmpty ? "" : "#\(itemID)")"
        progress = 0.05

        // 1) 直连抓页面
        var collected: [MediaItem] = []
        if let landing = YaboParser.landingURL(platform: platform, itemID: itemID, original: original) {
            do {
                let html = try await NetClient.text(landing, referer: original?.absoluteString)
                collected = YaboParser.parseMedia(from: html, baseURL: landing)
                bridge.logs.append("direct: \(html.count) bytes, \(collected.count) hits")
            } catch {
                bridge.logs.append("direct fail: \(error.localizedDescription)")
            }
        }
        progress = 0.35
        merge(collected)

        // 2) WebView 兜底抓取
        if items.isEmpty, let landing = YaboParser.landingURL(platform: platform, itemID: itemID, original: original) {
            status = "页面直取无结果，启动 WebView 抓取"
            webURL = landing
            showWeb = true
            await waitWebView()
            merge(bridge.liveItems)
        }

        progress = 1.0
        busy = false
        status = items.isEmpty
            ? "解析失败：链接可能需要登录或已失效"
            : "解析完成 // \(items.count) 项"
    }

    private func waitWebView() async {
        let deadline = Date().addingTimeInterval(25)
        var settled = 0.0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            settled += 0.5
            if finished, !bridge.liveItems.isEmpty, settled > 2 { break }
            if settled > 14, !bridge.liveItems.isEmpty { break }
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        webURL = nil
        showWeb = false
        finished = false
    }

    private func merge(_ list: [MediaItem]) {
        var seen = Set(items.map { $0.url.absoluteString })
        for it in list where seen.insert(it.url.absoluteString).inserted {
            items.append(it)
        }
        items.sort { a, b in
            if a.kind != b.kind { return a.kind == .video }
            return a.url.absoluteString < b.url.absoluteString
        }
    }

    // MARK: 下载

    func downloadAll() {
        guard !items.isEmpty, !busy else { return }
        busy = true
        savedCount = 0
        let snapshot = items
        let referer = webURL?.absoluteString
        Task {
            var ok = 0
            for (i, it) in snapshot.enumerated() {
                status = "下载 \(i + 1)/\(snapshot.count)"
                do {
                    let file = try await YaboDownloader.shared.download(
                        it, referer: referer, index: i + 1
                    )
                    try await YaboDownloader.shared.saveToAlbum(file, isVideo: it.kind == .video)
                    ok += 1
                    savedCount = ok
                    progress = Double(i + 1) / Double(snapshot.count)
                } catch {
                    bridge.logs.append("dl fail: \(error.localizedDescription)")
                }
            }
            progress = 1.0
            busy = false
            status = ok == snapshot.count
                ? "已保存 \(ok) 项到相册 // 鸭脖的传说"
                : "完成 \(ok)/\(snapshot.count)，失败项见日志"
        }
    }

    func pasteFromClipboard() {
        if let s = UIPasteboard.general.string, !s.isEmpty {
            input = s
            status = "已粘贴剪贴板内容"
        } else {
            status = "剪贴板是空的，先在快手/小红书里点“复制链接”"
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var vm = YaboViewModel()

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        inputBlock
                        actionBlock
                        statusBlock
                        if vm.showWeb, let u = vm.webURL {
                            webBlock(u)
                        }
                        resultBlock
                        logBlock
                    }
                    .padding(18)
                }
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .onAppear {
            UITextView.appearance().backgroundColor = .clear
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("鸭脖的传说")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("YABO NETWORK · iOS")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.green.opacity(0.9))
        }
    }

    private var inputBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("// TARGET LINK")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.gray)
            TextEditor(text: $vm.input)
                .frame(height: 92)
                .padding(10)
                .background(Color(white: 0.10))
                .cornerRadius(12)
                .foregroundStyle(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(white: 0.22), lineWidth: 1)
                )
            Text("粘贴抖音 / 小红书 / 快手 分享内容")
                .font(.system(size: 11))
                .foregroundStyle(.gray)
        }
    }

    private var actionBlock: some View {
        HStack(spacing: 10) {
            Button {
                vm.pasteFromClipboard()
            } label: {
                label("粘贴", "doc.on.clipboard", .gray)
            }
            .buttonStyle(.plain)

            Button {
                vm.parse()
            } label: {
                label("解析", "bolt.fill", .green)
            }
            .buttonStyle(.plain)
            .disabled(vm.busy)

            Button {
                vm.downloadAll()
            } label: {
                label("保存 \(vm.items.count)", "arrow.down.to.line", .blue)
            }
            .buttonStyle(.plain)
            .disabled(!vm.canDownload)
        }
    }

    private func label(_ t: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(t).font(.system(size: 13, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(white: 0.12))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.45), lineWidth: 1))
        .foregroundStyle(tint)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("> OUTPUT // 解析结果")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.gray)
                Spacer()
                Text(vm.platformName)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
            }
            Text(vm.status)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
            if vm.busy {
                ProgressView(value: vm.progress)
                    .tint(.green)
            }
        }
        .padding(12)
        .background(Color(white: 0.08))
        .cornerRadius(12)
    }

    private func webBlock(_ u: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("// WARNING · 后台抓取中")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
            YaboWebView(url: u,
                        bridge: vm.bridge,
                        progress: $vm.progress,
                        finished: $vm.finished)
                .frame(height: 180)
                .cornerRadius(10)
        }
    }

    private var resultBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.items.isEmpty {
                Text("暂无结果")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                ForEach(Array(vm.items.enumerated()), id: \.element.id) { idx, it in
                    HStack(spacing: 10) {
                        Image(systemName: it.kind == .video ? "play.rectangle.fill" : "photo.fill")
                            .foregroundStyle(it.kind == .video ? .green : .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(idx + 1). \(it.kind.rawValue) · \(it.ext)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                            Text(it.host)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.gray)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color(white: 0.09))
                    .cornerRadius(10)
                }
            }
        }
    }

    private var logBlock: some View {
        Group {
            if !vm.bridge.logs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("// LOG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.gray)
                    ForEach(vm.bridge.logs.suffix(6), id: \.self) { l in
                        Text(l)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.gray.opacity(0.8))
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}
