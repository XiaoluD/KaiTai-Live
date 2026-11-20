// 给页面拍快照，用于人工核对 UI。会注入一个「假桥」，让需要原生桥的按钮也正常显示。
// 用法:
//   swiftc -O mac-app/snapshot.swift -o /tmp/snapshot -framework AppKit -framework WebKit
//   /tmp/snapshot <页面URL> <输出PNG> [执行动作] [等待秒]
//   执行动作: none | clickfirst | fake-fail

import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: snapshot <url> <out.png> [action] [wait]\n".data(using: .utf8)!)
    exit(2)
}
let pageURL = URL(string: args[1])!
let outPath = args[2]
let action = args.count > 3 ? args[3] : "none"
let wait = args.count > 4 ? (Double(args[4]) ?? 4) : 4

/// 假装本机装了 IINA，让 app.js 走真实的分支把按钮显示出来
final class FakeBridge: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let body = message.body as? [String: Any]
        if (body?["action"] as? String) == "probe" {
            replyHandler(["players": ["IINA"]], nil)
        } else {
            replyHandler(["player": "IINA"], nil)
        }
    }
}

final class Shooter: NSObject, WKNavigationDelegate {
    var wv: WKWebView!
    var win: NSWindow!
    let bridge = FakeBridge()

    func start() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "iptv")
        wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 840), configuration: cfg)
        wv.navigationDelegate = self
        win = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1280, height: 840),
                       styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = wv
        win.orderFrontRegardless()
        wv.load(URLRequest(url: pageURL))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.act() }
    }

    func act() {
        var js = "return 1;"
        switch action {
        case "clickfirst":
            js = """
            const first = document.querySelector('.ch');
            if (first) first.click();
            return first ? 'clicked' : 'no-channel';
            """
        case "fake-fail":
            // 用一条真实的 FLV 直链，走真实的失败链路（WKWebView 播不了就是播不了）
            js = """
            playChannel({ name: '虎牙轮播 · 示例', url: 'https://live.metshop.top/huya/23734246', group: 'FLV 直连' });
            return 'played';
            """
        default:
            break
        }
        wv.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
            if case .failure(let e) = r {
                FileHandle.standardError.write("动作失败: \(e.localizedDescription)\n".data(using: .utf8)!)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.shoot() }
        }
    }

    func shoot() {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: 1280, height: 840)
        wv.takeSnapshot(with: cfg) { image, err in
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write("截图失败: \(err?.localizedDescription ?? "?")\n".data(using: .utf8)!)
                NSApp.terminate(nil); return
            }
            try? png.write(to: URL(fileURLWithPath: outPath))
            print("已保存 \(outPath) （\(png.count) 字节）")
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let s = Shooter()
s.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { print("超时"); NSApp.terminate(nil) }
app.run()
