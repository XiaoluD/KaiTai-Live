// 自检工具：探测 WKWebView 的播放能力，以及能否播放「不返回 CORS 头」的源
// 用法: swiftc -O probe.swift -o /tmp/probe -framework AppKit -framework WebKit
//       /tmp/probe http://127.0.0.1:63190/ "http://example.com/no-cors.m3u8"

import AppKit
import WebKit

let args = CommandLine.arguments
let pageURL = URL(string: args.count > 1 ? args[1] : "http://127.0.0.1:63190/")!
let testURL = args.count > 2 ? args[2] : ""

final class Probe: NSObject, WKNavigationDelegate {
    var wv: WKWebView!
    var win: NSWindow!

    func start() {
        let cfg = WKWebViewConfiguration()
        wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650), configuration: cfg)
        wv.navigationDelegate = self
        win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 650),
                       styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = wv
        win.orderFrontRegardless()
        wv.load(URLRequest(url: pageURL))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.checkCapability() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("页面加载失败:", error.localizedDescription)
        finish()
    }

    func checkCapability() {
        let js = """
        [ typeof Hls !== 'undefined' && Hls.isSupported(),
          document.createElement('video').canPlayType('application/vnd.apple.mpegurl'),
          document.getElementsByClassName('ch').length ]
        """
        wv.evaluateJavaScript(js) { result, error in
            if let arr = result as? [Any], arr.count >= 3 {
                print("① hls.js MSE 支持 :", arr[0])
                print("② WebKit 原生 HLS :", "\(arr[1])".isEmpty ? "(不支持)" : arr[1])
                print("③ 列表已解析频道数 :", arr[2])
            } else {
                print("能力探测失败:", error?.localizedDescription ?? "unknown")
            }
            self.testStream()
        }
    }

    func testStream() {
        if CommandLine.arguments.contains("--click") {
            clickFirstChannel()
            return
        }
        guard !testURL.isEmpty else { finish(); return }
        print("④ 试播（无 CORS 头的源）:", testURL)
        let js = """
        return await new Promise((resolve) => {
          const v = document.createElement('video');
          v.muted = true; v.playsInline = true;
          let done = false;
          const fin = (r) => { if (!done) { done = true; resolve(r); } };
          v.addEventListener('error', () => fin({ ok: false, err: (v.error || {}).code || -1, msg: (v.error || {}).message || '' }));
          v.addEventListener('playing', () => setTimeout(() => fin({ ok: true, at: 'playing', t: v.currentTime, w: v.videoWidth, h: v.videoHeight, rs: v.readyState }), 2500));
          setTimeout(() => fin({ ok: v.videoWidth > 0 || v.currentTime > 0, at: 'timeout', t: v.currentTime, w: v.videoWidth, h: v.videoHeight, rs: v.readyState, net: v.networkState }), 12000);
          v.src = url;
          v.load();
          v.play().catch((e) => {});
        });
        """
        wv.callAsyncJavaScript(js, arguments: ["url": testURL], in: nil, in: .page) { result in
            switch result {
            case .success(let v):
                print("   结果:", v)
            case .failure(let e):
                print("   异常:", e.localizedDescription)
            }
            self.finish()
        }
    }

    /// 点第一个频道，走完整 UI 链路（app.js 选择播放器 → 真实播放）
    func clickFirstChannel() {
        let js = """
        return await new Promise((resolve) => {
          const first = document.querySelector('.ch');
          if (!first) { resolve({ ok: false, reason: 'no-channel' }); return; }
          const name = first.querySelector('.nm') ? first.querySelector('.nm').textContent : '?';
          first.click();
          setTimeout(() => {
            const v = document.getElementById('video');
            const ov = document.getElementById('overlay');
            resolve({
              ok: v.videoWidth > 0 && v.currentTime > 0,
              channel: name,
              url: (v.currentSrc || '').slice(0, 80),
              t: Math.round(v.currentTime * 10) / 10,
              w: v.videoWidth, h: v.videoHeight,
              rs: v.readyState,
              overlay: ov && !ov.classList.contains('hide')
                ? (ov.querySelector('.ov-title') || {}).textContent || ''
                : '',
              reason: ov && !ov.classList.contains('hide')
                ? (ov.querySelector('.ov-sub') || {}).textContent || ''
                : '',
              errCode: (v.error || {}).code || 0
            });
          }, 11000);
        });
        """
        wv.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let v): print("⑤ UI 链路点击播放:", v)
            case .failure(let e): print("   异常:", e.localizedDescription)
            }
            self.finish()
        }
    }

    func finish() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let probe = Probe()
probe.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    print("超时退出")
    NSApp.terminate(nil)
}
app.run()
