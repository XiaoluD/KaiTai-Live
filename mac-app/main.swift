import AppKit
import WebKit
import Network

// MARK: - 极简静态文件服务（只绑 127.0.0.1，进程退出即消失）

final class StaticServer {
    private let queue = DispatchQueue(label: "iptv.static.server")
    private var listener: NWListener?
    private let root: URL
    /// 覆盖目录：/playlists/ 下的文件优先从这里读。
    /// app 打包后 Resources 是只读的，更新下来的列表只能写到用户目录，
    /// 用覆盖层就不用把整个站点复制出去。
    private let overlay: URL?
    private(set) var port: UInt16 = 0

    init(root: URL, overlay: URL? = nil) {
        self.root = root
        self.overlay = overlay
    }

    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let p = listener.port { self?.port = p.rawValue }
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)

        guard port > 0 else {
            throw NSError(domain: "iptv", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法监听 127.0.0.1"])
        }
        self.listener = listener
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                conn.cancel(); return
            }

            let requestLine = text.split(separator: "\r\n").first.map(String.init) ?? ""
            var path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            if let q = path.firstIndex(of: "?") { path = String(path[path.startIndex..<q]) }
            if path == "/" { path = "/index.html" }
            path = path.removingPercentEncoding ?? path
            if path.contains("..") { path = "/index.html" }

            let rel = String(path.dropFirst())
            var fileURL = self.root.appendingPathComponent(rel)
            // 更新下来的列表放用户目录，优先命中
            if rel.hasPrefix("playlists/"), let overlay = self.overlay {
                let candidate = overlay.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    fileURL = candidate
                }
            }
            let exists = FileManager.default.fileExists(atPath: fileURL.path)

            let status = exists ? "200 OK" : "404 Not Found"
            var body = exists ? ((try? Data(contentsOf: fileURL)) ?? Data()) : Data("not found".utf8)

            let header = [
                "HTTP/1.1 \(status)",
                "Content-Type: \(Self.mimeType(fileURL.pathExtension))",
                "Content-Length: \(body.count)",
                "Cache-Control: no-store",
                "Access-Control-Allow-Origin: *",
                "Connection: close",
                "", ""
            ].joined(separator: "\r\n")

            var out = Data(header.utf8)
            out.append(body)
            body.removeAll()

            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "m3u", "m3u8": return "application/vnd.apple.mpegurl"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - 外部播放器适配层
//
// app 内的 WKWebView 只能播 HLS / MP4；FLV、RTMP、组播这些必须交给原生播放器。
// 不绑死某一个：按 IINA → VLC → mpv 的顺序找第一个装了的，都没有就如实告诉前端。
// 迁移到新机器时，装其中任意一个即可，不用改代码。

struct ExternalPlayer {
    let name: String
    let bundleID: String
    /// IINA 支持 iina://weblink?url= 这种 scheme，比传命令行参数可靠
    let urlScheme: String?
}

enum PlayerBridge {
    static let candidates: [ExternalPlayer] = [
        ExternalPlayer(name: "IINA", bundleID: "com.colliderli.iina", urlScheme: "iina"),
        ExternalPlayer(name: "VLC", bundleID: "org.videolan.vlc", urlScheme: nil),
        ExternalPlayer(name: "mpv", bundleID: "io.mpv", urlScheme: nil),
    ]

    static func installed() -> [ExternalPlayer] {
        candidates.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    /// 返回实际使用的播放器名；找不到可用的返回 nil
    @discardableResult
    static func open(_ raw: String) -> String? {
        guard let url = URL(string: raw), !raw.isEmpty else { return nil }

        for p in installed() {
            if let scheme = p.urlScheme,
               let enc = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               let deep = URL(string: "\(scheme)://weblink?url=\(enc)") {
                NSWorkspace.shared.open(deep)
                return p.name
            }
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleID) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.arguments = [raw]
                NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, err in
                    if let err { NSLog("[IPTV] 启动播放器失败: %@", err.localizedDescription) }
                }
                return p.name
            }
        }
        _ = url
        return nil
    }
}

// MARK: - JS ↔ 原生 桥

final class JSBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "iptv"

    /// 更新源要写入的目录（app 包内只读，所以指到用户目录）
    var playlistsDir: () -> URL = { FileManager.default.temporaryDirectory }

    /// 内嵌版才有：libmpv 播放视图（精简版为 nil）
    var mpvView: (() -> NSView?)?
    /// 内嵌播放内核是否可用，决定 probe 回什么
    var embeddedAvailable = false
    /// 把原生事件回灌给网页（页面里是 window.__mpv）
    var notifyJS: ((String, String) -> Void)?

    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        // reply 统一异步投递：在 didPostMessage 调用栈内同步调 replyHandler，
        // WebKit 偶发不把 reply 传回 JS（Promise 永挂，v1.0.2 起反复踩坑）。
        // 先退出本调用栈再回调，实测恢复可靠。
        let reply: (Any?, String?) -> Void = { payload, err in
            DispatchQueue.main.async { replyHandler(payload, err) }
        }
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            NSLog("[IPTV] bridge: bad request")
            reply(nil, "bad request")
            return
        }
        NSLog("[IPTV] bridge msg: %@", action)

        switch action {
        case "probe":
            // 返回可用的外部播放器列表，前端据此决定按钮文案
            NSLog("[IPTV] probe: querying players")
            let playerNames = PlayerBridge.installed().map { $0.name }
            NSLog("[IPTV] probe: players=[%@] embedded=%d", playerNames.joined(separator: ","), embeddedAvailable ? 1 : 0)
            var payload: [String: Any] = ["players": playerNames]
            if embeddedAvailable { payload["embedded"] = true }
            payload["version"] = AppUpdate.currentVersion
            reply(payload, nil)
            NSLog("[IPTV] probe: replied")

        case "mpv":
            handleMpv(body, replyHandler)

        case "open":
            guard let raw = body["url"] as? String else {
                reply(nil, "missing url")
                return
            }
            if let used = PlayerBridge.open(raw) {
                NSLog("[IPTV] 已交给外部播放器: %@ ← %@", used, raw)
                reply(["player": used], nil)
            } else {
                reply(["player": NSNull()], nil)
            }

        case "download":
            guard let urls = body["urls"] as? [String], !urls.isEmpty else {
                reply(["texts": [:]], nil)
                return
            }
            Task {
                var texts: [String: String] = [:]
                var errors: [String: String] = [:]
                for u in urls {
                    do {
                        texts[u] = try await Updater.download(u)
                    } catch {
                        errors[u] = error.localizedDescription
                    }
                }
                NSLog("[IPTV] 下载列表 %d 成功 / %d 失败", texts.count, errors.count)
                await MainActor.run { reply(["texts": texts, "errors": errors], nil) }
            }

        case "save":
            guard let file = body["file"] as? String,
                  let content = body["content"] as? String else {
                reply(nil, "missing file/content")
                return
            }
            do {
                let path = try Updater.save(file: file, content: content, playlistsDir: playlistsDir())
                NSLog("[IPTV] 已写入 %@", path)
                reply(["path": path], nil)
            } catch {
                reply(nil, error.localizedDescription)
            }

        case "appupdate":
            let op = body["op"] as? String ?? "check"
            switch op {
            case "check":
                Task {
                    do {
                        if let info = try await AppUpdate.check() {
                            NSLog("[IPTV] update check: hasUpdate=%@ zip=%@", info.tag, info.zipURL)
                            await MainActor.run {
                                reply(["hasUpdate": true, "tag": info.tag,
                                              "zipURL": info.zipURL,
                                              "current": AppUpdate.currentVersion], nil)
                            }
                        } else {
                            NSLog("[IPTV] update check: no update (local=%@)", AppUpdate.currentVersion)
                            await MainActor.run {
                                reply(["hasUpdate": false,
                                              "current": AppUpdate.currentVersion], nil)
                            }
                        }
                    } catch {
                        NSLog("[IPTV] update check error: %@", error.localizedDescription)
                        await MainActor.run { reply(nil, error.localizedDescription) }
                    }
                }
            case "install":
                guard let tag = body["tag"] as? String,
                      let url = body["url"] as? String else {
                    reply(nil, "missing tag/url")
                    return
                }
                reply(["started": true], nil)
                Task {
                    try? await AppUpdate.install(AppUpdate.Info(tag: tag, zipURL: url))
                }
            default:
                reply(nil, "unknown appupdate op")
            }

        default:
            reply(nil, "unknown action")
        }
    }

    // MARK: - 内嵌播放内核的指令入口
    //
    // 网页只说三件事：播什么 / 视图放在哪 / 停。
    // 位置用 CSS 像素传进来，这里翻成 AppKit 坐标——网页的 y 向下、AppKit 的 y 向上，
    // 所以要拿容器高度减一次。
    private func handleMpv(_ body: [String: Any], _ reply: @escaping (Any?, String?) -> Void) {
        #if !EMBEDDED
        reply(["ok": false, "reason": "这是精简版，不含内嵌播放内核"], nil)
        #else
        guard let view = mpvView?() as? MpvPlayerView else {
            reply(["ok": false, "reason": "内嵌播放器未就绪"], nil)
            return
        }
        let op = body["op"] as? String ?? ""

        switch op {
        case "play":
            guard let url = body["url"] as? String, !url.isEmpty else {
                reply(nil, "missing url")
                return
            }
            DispatchQueue.main.async { view.play(url) }
            reply(["ok": true], nil)

        case "stop":
            DispatchQueue.main.async { view.stop() }
            reply(["ok": true], nil)

        case "rect":
            let x = body["x"] as? Double ?? 0
            let y = body["y"] as? Double ?? 0
            let w = body["w"] as? Double ?? 0
            let h = body["h"] as? Double ?? 0
            DispatchQueue.main.async {
                guard let host = view.superview else { return }
                let flippedY = host.isFlipped
                    ? y
                    : host.bounds.height - y - h
                view.frame = NSRect(x: x, y: flippedY, width: w, height: h)
            }
            reply(["ok": true], nil)

        case "pause":
            let paused = body["paused"] as? Bool ?? true
            DispatchQueue.main.async { view.setPaused(paused) }
            reply(["ok": true], nil)

        case "overlay":
            // 暂停时隐藏 mpv 层，露出网页里的暂停/播放状态图标
            let hidden = body["hidden"] as? Bool ?? false
            DispatchQueue.main.async { view.isHidden = hidden }
            reply(["ok": true], nil)

        case "volume":
            let v = body["value"] as? Double ?? 100
            DispatchQueue.main.async { view.setVolume(v) }
            reply(["ok": true], nil)

        case "fullscreen":
            DispatchQueue.main.async { view.window?.toggleFullScreen(nil) }
            reply(["ok": true], nil)

        case "logo":
            // 播放画面右上角的频道台标（网页层看不到，得贴在 mpv 视图上）
            let url = body["url"] as? String
            DispatchQueue.main.async { view.setLogo(url) }
            reply(["ok": true], nil)

        case "setopt":
            let key = body["key"] as? String ?? ""
            let value = body["value"] as? String ?? ""
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                reply(nil, "bad key")
                return
            }
            DispatchQueue.main.async {
                (view as? MpvPlayerView)?.setOption(key, value)
            }
            reply(["ok": true], nil)

        default:
            reply(nil, "unknown mpv op")
        }
        #endif
    }
}

// MARK: - 原生 → 网页 的事件通道

extension WKWebView {
    /// 调页面里的 window.__mpv(kind, text)。参数走 JSON 序列化，省得手工拼引号。
    func notifyMPV(_ kind: String, _ text: String) {
        let arr = (try? JSONSerialization.data(withJSONObject: [kind, text]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\",\"\"]"
        evaluateJavaScript("window.__mpv && window.__mpv.apply(null, \(arr));",
                           completionHandler: nil)
    }
}

// MARK: - 顶栏拖动条：WKWebView 吃掉所有鼠标事件，窗口拖不动；
// 在顶部放一条透明视图，把鼠标按下转成窗口拖动（避开左侧红绿灯 80px）。
// 双击 = 最大化 / 还原（系统标题栏的 zoom 行为）

final class DragStripView: NSView {
    private var lastClick = Date.distantPast

    override func mouseDown(with event: NSEvent) {
        let now = Date()
        if now.timeIntervalSince(lastClick) < 0.35 {
            window?.performZoom(nil)   // 双击：最大化 / 窗口化切换
        } else {
            window?.performDrag(with: event)
        }
        lastClick = now
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var server: StaticServer?
    private var webView: WKWebView?
    private var bridge: JSBridge?
    #if EMBEDDED
    private var player: MpvPlayerView?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let root = Self.contentRoot()
        NSLog("[IPTV] 内容目录: %@", root.path)
        let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        NSLog("[IPTV] Bundle=%@  ATS=%@", Bundle.main.bundlePath, ats?.description ?? "缺失")

        // 更新下来的列表写这里（app 包内是只读的）
        let writable = Self.writableRoot()
        NSLog("[IPTV] 可写目录: %@", writable.path)

        var pageURL: URL?
        do {
            let s = StaticServer(root: root, overlay: writable)
            let p = try s.start()
            self.server = s
            pageURL = URL(string: "http://127.0.0.1:\(p)/")
            NSLog("[IPTV] 本地服务已启动: %@", pageURL?.absoluteString ?? "-")
        } catch {
            NSLog("[IPTV] 本地服务启动失败: %@", error.localizedDescription)
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // 标题栏融入界面：内容延伸到标题栏下、透明标题栏、隐藏标题文字，
        // 红绿灯直接悬浮在网页顶栏上（顶栏给左侧留出 80px）
        win.styleMask.insert(.fullSizeContentView)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.title = "开台"
        win.minSize = NSSize(width: 900, height: 600)
        win.center()

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // 注入 JS 桥：前端可用 window.webkit.messageHandlers.iptv 调外部播放器 / 更新源
        self.bridge = JSBridge()
        if let bridge {
            bridge.playlistsDir = { Self.writableRoot().appendingPathComponent("playlists", isDirectory: true) }
            config.userContentController.addScriptMessageHandler(
                bridge, contentWorld: .page, name: JSBridge.name)
        }
        // 注入当前版本号：设置-关于的「版本详情」启动即显示，不用等检查更新
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        if ProcessInfo.processInfo.environment["KAITAI_NO_USERSCRIPT"] == nil {
            let verScript = WKUserScript(
                source: "window.__appVersion = '\(ver)';",
                injectionTime: .atDocumentStart, forMainFrameOnly: true)
            config.userContentController.addUserScript(verScript)
        }

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 840), configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.allowsBackForwardNavigationGestures = false

        if let pageURL {
            wv.load(URLRequest(url: pageURL))
        } else {
            wv.loadHTMLString(
                "<meta charset='utf-8'><body style='font:14px -apple-system;padding:40px'>"
                + "本地服务启动失败，请检查 127.0.0.1 是否被占用。</body>", baseURL: nil)
        }

        // 网页和播放视图放同一个容器里：播放视图叠在网页上方，位置由网页报上来的
        // #screen 矩形决定。容器本身不设 wantsLayer，避免把整条层级带成 layer-backed。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 840))
        container.autoresizingMask = [.width, .height]
        container.addSubview(wv)

        #if EMBEDDED
        let player = MpvPlayerView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        player.isHidden = true
        container.addSubview(player, positioned: .above, relativeTo: wv)
        self.player = player
        if let bridge {
            bridge.mpvView = { [weak player] in player }
            bridge.embeddedAvailable = true
        }
        player.onFirstFrame = { [weak player, weak wv] in
            player?.isHidden = false
            wv?.notifyMPV("firstframe", "")
        }
        player.onFailed = { [weak player, weak wv] msg in
            player?.isHidden = true
            wv?.notifyMPV("fail", msg)
        }
        player.onEnded = { [weak player, weak wv] in
            player?.isHidden = true
            wv?.notifyMPV("ended", "")
        }

        // 自检：IPTV_PLAY_URL=<直链> 时直接起播并播报结果，用来验证「内核接得通」
        if let u = ProcessInfo.processInfo.environment["IPTV_PLAY_URL"], !u.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSLog("[IPTV] 自检播放: %@", u)
                player.isHidden = false
                player.play(u)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 18) {
                NSLog("[IPTV] 自检结束，退出")
                NSApp.terminate(nil)
            }
        }
        #endif

        win.contentView = container

        // 顶栏拖动条：盖在所有视图最上层（含 mpv 层），只占顶部 52px 且避开红绿灯
        let dragStrip = DragStripView(frame: NSRect(x: 80, y: 840 - 52, width: 1280 - 80, height: 52))
        dragStrip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(dragStrip, positioned: .above, relativeTo: nil)

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
        self.webView = wv

        // 诊断：定时轮询网页里的 window.__diag，观察 JS 侧桥挂点
        if ProcessInfo.processInfo.environment["IPTV_DIAG"] != nil {
            for delay in [5.0, 12.0, 25.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.webView?.evaluateJavaScript("String(window.__diag || '(undefined)')") { r, e in
                        NSLog("[IPTV] diag@%ds: %@ err=%@", Int(delay), r as? String ?? "nil", e?.localizedDescription ?? "-")
                    }
                }
            }
        }

        // 自检：设置 IPTV_SELFTEST=1 时 8 秒后自动关窗，
        // 用于验证「关窗 → 进程退出 → 端口释放」这条链路。
        if ProcessInfo.processInfo.environment["IPTV_SELFTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                NSLog("[IPTV] 自检：关闭窗口")
                win.close()
            }
        }

        // 自检：IPTV_BRIDGE_TEST=1 探测 JS 桥；IPTV_BRIDGE_URL=... 真的调外部播放器；
        // IPTV_EVAL="<js>" 直接跑一段自定义 JS（用来点真实按钮，验证接线）
        if ProcessInfo.processInfo.environment["IPTV_BRIDGE_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let openURL = ProcessInfo.processInfo.environment["IPTV_BRIDGE_URL"] ?? ""
                let custom = ProcessInfo.processInfo.environment["IPTV_EVAL"] ?? ""
                let js: String
                if !custom.isEmpty {
                    js = custom
                } else if openURL.isEmpty {
                    js = "return await window.webkit.messageHandlers.iptv.postMessage({action:'probe'});"
                } else {
                    js = "return await window.webkit.messageHandlers.iptv.postMessage({action:'open', url: U});"
                }
                wv.callAsyncJavaScript(js, arguments: ["U": openURL], in: nil, in: .page) { result in
                    switch result {
                    case .success(let v):
                        // 压成单行 JSON，否则 NSLog 会把多行字典截断
                        var s = String(describing: v)
                        if JSONSerialization.isValidJSONObject(v),
                           let d = try? JSONSerialization.data(withJSONObject: v),
                           let j = String(data: d, encoding: .utf8) {
                            s = j
                        }
                        NSLog("[IPTV] 桥自检结果: %@", s)
                    case .failure(let e):
                        NSLog("[IPTV] 桥自检失败: %@", e.localizedDescription)
                    }
                    // 点按钮这类动作是异步的，留 3 秒再退，别把链路掐断
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { NSApp.terminate(nil) }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // 自检：IPTV_MENU_TEST=1 时 3 秒后逐个检查菜单接线并触发「设置…」，
    // 验证 target/action → menuAction → evaluateJavaScript 这条链路
    func applicationDidBecomeActive(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["IPTV_MENU_TEST"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let main = NSApp.mainMenu else {
                NSLog("[IPTV] 菜单自检失败: mainMenu 为空")
                return
            }
            for item in main.items {
                guard let sub = item.submenu else { continue }
                for it in sub.items {
                    NSLog("[IPTV] 菜单自检: [%@] %@ | target=%@ enabled=%@",
                          item.title, it.title,
                          it.target.map { String(describing: type(of: $0)) } ?? "nil",
                          it.isEnabled ? "yes" : "no")
                    if it.title.contains("设置"), let act = it.action {
                        let ok = NSApp.sendAction(act, to: it.target, from: it)
                        NSLog("[IPTV] 菜单自检: sendAction(设置…) = %@", ok ? "true" : "false")
                    }
                }
            }
            // 先探一下 JS 环境状态，再看动作效果
            self?.webView?.evaluateJavaScript(
                "(function(){" +
                "var out={};out.menu=typeof window.__kaitaiMenu;" +
                "var btn=document.getElementById('settingsBtn');out.btn=!!btn;" +
                "btn.click();" +
                "out.scrimAfterClick=document.getElementById('settingsScrim').hidden;" +
                "out.listener=typeof window.__bindDone;" +
                "return JSON.stringify(out);})()",
                completionHandler: { r, _ in
                    NSLog("[IPTV] 菜单自检: JS分解测试 = %@", String(describing: r))
                })
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.webView?.evaluateJavaScript(
                    "document.getElementById('settingsScrim').hidden",
                    completionHandler: { r, _ in
                        NSLog("[IPTV] 菜单自检: settingsScrim.hidden = %@", String(describing: r))
                        NSApp.terminate(nil)
                    })
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        server = nil
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于开台", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("检查更新", action: "checkupd", key: "u"))
        appMenu.addItem(menuItem("设置…", action: "settings", key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏开台", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出开台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let playItem = NSMenuItem()
        let playMenu = NSMenu(title: "播放")
        playMenu.addItem(menuItem("暂停 / 继续", action: "pause", key: "p"))
        playMenu.addItem(menuItem("重试当前频道", action: "retry", key: "r", shift: true))
        playMenu.addItem(menuItem("复制当前频道直链", action: "copy", key: "c", shift: true))
        playMenu.addItem(menuItem("在浏览器打开当前直链", action: "", key: "o", shift: true,
                                  selector: #selector(openCurrentURLInBrowser(_:))))
        playItem.submenu = playMenu
        mainMenu.addItem(playItem)

        let srcItem = NSMenuItem()
        let srcMenu = NSMenu(title: "源")
        srcMenu.addItem(menuItem("更新播放源", action: "update", key: "u", shift: true))
        srcItem.submenu = srcMenu
        mainMenu.addItem(srcItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let rl = NSMenuItem(title: "重新载入", action: #selector(reload(_:)), keyEquivalent: "r")
        rl.target = self  // 不设 target 走 responder chain 无人响应 reload:，菜单会一直无效
        viewMenu.addItem(rl)
        viewMenu.addItem(.separator())
        viewMenu.addItem(menuItem("播放源视图", action: "view-sources", key: "1"))
        viewMenu.addItem(menuItem("频道视图", action: "view-channels", key: "2"))
        viewMenu.addItem(.separator())
        let fs = NSMenuItem(title: "全屏", action: #selector(toggleFullScreen(_:)),
                            keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fs)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }

    /// 菜单项统一走 representedObject 里的动作名，转发给网页端的 window.__kaitaiMenu
    private func menuItem(_ title: String, action: String, key: String, shift: Bool = false,
                          selector: Selector? = nil) -> NSMenuItem {
        let act = selector ?? #selector(menuAction(_:))
        let item = NSMenuItem(title: title, action: act, keyEquivalent: key)
        item.target = self
        item.representedObject = action
        if shift { item.keyEquivalentModifierMask = [.command, .shift] }
        return item
    }

    /// 「在浏览器打开当前直链」：先从网页取当前频道的 url，再交给系统默认浏览器
    /// （WKWebView 不会自动响应 target=_blank，必须走 NSWorkspace）
    @objc private func openCurrentURLInBrowser(_ sender: NSMenuItem) {
        webView?.evaluateJavaScript(
            "window.__kaitaiCurrentURL ? window.__kaitaiCurrentURL() : '';",
            completionHandler: { result, _ in
                guard let s = result as? String, !s.isEmpty,
                      let url = URL(string: s) else {
                    NSLog("[IPTV] 浏览器打开失败：当前没有可打开的直链")
                    return
                }
                NSLog("[IPTV] 交给浏览器: %@", url.absoluteString)
                NSWorkspace.shared.open(url)
            })
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let act = sender.representedObject as? String,
              let data = try? JSONSerialization.data(withJSONObject: [act]),
              let json = String(data: data, encoding: .utf8) else {
            NSLog("[IPTV] 菜单动作缺失 representedObject")
            return
        }
        NSLog("[IPTV] 菜单动作: %@", act)
        webView?.evaluateJavaScript(
            "window.__kaitaiMenu && window.__kaitaiMenu(\(json));",
            completionHandler: { _, err in
                if let err {
                    NSLog("[IPTV] 菜单 JS 执行失败: %@", err.localizedDescription)
                }
            })
    }

    @objc private func toggleFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(nil)
    }

    @objc private func reload(_ sender: Any?) {
        webView?.reload()
    }

    /// 优先用外部可写目录（便于 sync 脚本更新列表），否则用 app 内置副本
    private static func contentRoot() -> URL {
        let fm = FileManager.default
        let external = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IPTVWeb", isDirectory: true)
        if fm.fileExists(atPath: external.appendingPathComponent("index.html").path) {
            return external
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true),
           fm.fileExists(atPath: res.appendingPathComponent("index.html").path) {
            return res
        }
        return Bundle.main.bundleURL
    }

    /// 可写目录：只放更新下来的 playlists/，不复制整站
    private static func writableRoot() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IPTVWeb", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
