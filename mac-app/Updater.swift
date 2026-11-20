import Foundation

// MARK: - 源更新器的原生部分
//
// 只做两件原生才能做的事：下载远程列表、写入可写目录。
// 「哪些频道真能播」的判断放在前端用 <video> 实测——原因有两个：
//   1. ATS 会拦掉 app 自己发出的 http:// 请求（NSURLErrorAppTransportSecurity -1022），
//      但 WKWebView 里加载 http 媒体流是放行的，探活只能走 WebKit。
//   2. video 元素反映的是真实解码能力，比 HTTP 探活准（FLV 能 200 但播不了）。
//
// 注意：下载列表要求 https。纯 http 的列表地址在 app 内拿不到。

enum Updater {

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    enum UpdateError: LocalizedError {
        case notHTTPS
        case badStatus(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .notHTTPS: return "列表地址不是 https，App 内无法下载"
            case .badStatus(let c): return "HTTP \(c)"
            case .empty: return "拉到的内容是空的"
            }
        }
    }

    /// 下载一段文本（m3u 列表），上限 4 MB
    static func download(_ raw: String, limit: Int = 4 * 1024 * 1024,
                         timeout: TimeInterval = 30) async throws -> String {
        guard let url = URL(string: raw) else { throw Updater.UpdateError.notHTTPS }
        guard url.scheme?.lowercased() == "https" else { throw Updater.UpdateError.notHTTPS }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw Updater.UpdateError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw Updater.UpdateError.empty }
        let body = data.count > limit ? data.prefix(limit) : data
        return String(decoding: body, as: UTF8.self)
    }

    /// 写到可写的 playlists 目录，返回落盘路径
    @discardableResult
    static func save(file: String, content: String, playlistsDir: URL) throws -> String {
        var name = file
        if name.hasPrefix("playlists/") {
            name = String(name.dropFirst("playlists/".count))
        }
        // 只允许写到 playlists 目录下的扁平文件名，挡掉 ../ 之类的路径穿越
        name = (name as NSString).lastPathComponent
        try FileManager.default.createDirectory(at: playlistsDir, withIntermediateDirectories: true)
        let target = playlistsDir.appendingPathComponent(name)
        try content.write(to: target, atomically: true, encoding: .utf8)
        return target.path
    }
}

// MARK: - 应用自更新（GitHub Releases）
//
// 机制：App 启动后前端点「检查更新」→ 拉 releases/latest 比对版本 →
// 下载对应 variant 的 zip → 解压 → 用一段延迟脚本换包重启。
// 脚本在本进程退出后才动手，避免「自己删自己」。

enum AppUpdate {

    /// 发布仓库；build.sh 会在 Info.plist 里写 GitHubRepo，这里读它，读不到用默认
    static var repo: String {
        (Bundle.main.infoDictionary?["GitHubRepo"] as? String) ?? "XiaoluD/kaitai"
    }

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    static var variant: String {
        #if EMBEDDED
        return "full"
        #else
        return "lite"
        #endif
    }

    struct Info {
        let tag: String
        let zipURL: String
    }

    enum AppUpdateError: LocalizedError {
        case noMatchingAsset
        var errorDescription: String? {
            switch self {
            case .noMatchingAsset: return "Release 里没有适配本机（\(variant) / arm64）的安装包"
            }
        }
    }

    /// 查最新版本；有更新返回 Info，无更新返回 nil
    ///
    /// 主路径不走 api.github.com（匿名 60 次/小时/IP，代理出口 IP 极易被打爆，
    /// 2026-11-21 实测踩坑）：用 releases/latest 页面的 302 Location 拿 tag。
    /// github.com 的页面重定向没有这个限流，直连和代理都通。
    /// Location 拿不到（被墙改写/网络异常）时回退 API。
    static func check() async throws -> Info? {
        let tag: String
        if let viaRedirect = try? await latestTagViaRedirect() {
            tag = viaRedirect
        } else {
            let text = try await Updater.download(
                "https://api.github.com/repos/\(repo)/releases/latest", limit: 1 << 20)
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = obj["tag_name"] as? String else { return nil }
            tag = t
        }

        // 与本地同版本视为无更新（比较标准化后的三段数字）
        guard normalized(tag) != normalized(currentVersion) else { return nil }

        // 资产名固定 ASCII（GitHub 上传中文资产名会丢前缀，v1.0.2 实测踩坑）
        let zipURL = "https://github.com/\(repo)/releases/download/\(tag)/kaitai-\(variant)-arm64.zip"
        return Info(tag: tag, zipURL: zipURL)
    }

    /// HEAD 请求 releases/latest，跟随重定向到最终 tag 页，从最终 URL 提取 /tag/vX.Y.Z。
    /// 注意不能用「阻止重定向的 delegate」拿 302 Location：delegate 返回 nil 后
    /// async data(for:) 会以 NSURLErrorCancelled 收尾（v1.0.4 实测踩坑），任务直接失败。
    /// HEAD 跟随重定向 body 为空，最终 resp.url 即 /releases/tag/<tag>。
    static func latestTagViaRedirect() async throws -> String {
        guard let url = URL(string: "https://github.com/\(repo)/releases/latest") else {
            throw AppUpdateError.noMatchingAsset
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "HEAD"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = resp.url?.absoluteString,
              let range = finalURL.range(of: "/tag/") else {
            throw AppUpdateError.noMatchingAsset
        }
        let tag = String(finalURL[range.upperBound...])
        guard tag.hasPrefix("v"), tag.count <= 32,
              tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
            throw AppUpdateError.noMatchingAsset
        }
        return tag
    }

    /// 下载并换包重启；返回后 App 会自行退出
    static func install(_ info: Info) async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("kaitai-update-\(info.tag)", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 二进制下载（Updater.download 是文本上限 4MB，这里不适用）
        var req = URLRequest(url: URL(string: info.zipURL)!, timeoutInterval: 300)
        req.setValue(Updater.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              data.count > 1024 else {
            throw Updater.UpdateError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let zip = tmp.appendingPathComponent("app.zip")
        try data.write(to: zip)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", "-o", zip.path, "-d", tmp.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Updater.UpdateError.badStatus(-2) }

        let entries = try fm.contentsOfDirectory(atPath: tmp.path).filter { $0.hasSuffix(".app") }
        guard let appName = entries.first else { throw AppUpdateError.noMatchingAsset }
        let newPath = tmp.appendingPathComponent(appName).path
        let curPath = Bundle.main.bundlePath

        let scriptPath = tmp.appendingPathComponent("swap.sh")
        let script = """
        #!/bin/bash
        sleep 1
        pkill -x KaiTai
        sleep 1
        rm -rf "\(curPath)"
        ditto "\(newPath)" "\(curPath)"
        open "\(curPath)"
        """
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)

        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/bash")
        sh.arguments = [scriptPath.path]
        try sh.run()
        exit(0)
    }

    private static func normalized(_ v: String) -> String {
        let parts = v.lowercased().hasPrefix("v")
            ? v.dropFirst() : v[...]
        return parts.split(separator: ".").map { $0.filter(\.isNumber) }.joined(separator: ".")
    }
}
