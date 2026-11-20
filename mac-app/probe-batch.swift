// 在真实 WKWebView 里批量试播，产出「哪些能在本 app 里播」的地面真相。
// curl 只能证明服务器有响应，证明不了 Safari 能解码（FLV 就是典型）。
//
// 用法:
//   swiftc -O mac-app/probe-batch.swift -o /tmp/probe-batch -framework AppKit -framework WebKit
//   /tmp/probe-batch <页面URL> <输入m3u> <输出TSV> [并发数] [超时秒]
//
// 判定：video 触发 playing 且 videoWidth>0 → 可播；否则记 error.code。

import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("用法: probe-batch <页面URL> <输入m3u> <输出TSV> [并发] [超时]\n".data(using: .utf8)!)
    exit(2)
}
let pageURL = URL(string: args[1])!
let inPath = args[2]
let outPath = args[3]
let conc = args.count > 4 ? (Int(args[4]) ?? 8) : 8
let tmo = args.count > 5 ? (Double(args[5]) ?? 7) : 7

// ---- 解析 m3u ----
struct Item { let name: String; let url: String }
var items: [Item] = []
do {
    let raw = try String(contentsOfFile: inPath, encoding: .utf8)
        .replacingOccurrences(of: "\r\n", with: "\n")
    var pending: String? = nil
    for lineSub in raw.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(lineSub)
        if line.hasPrefix("#EXTINF") {
            var n = ""
            if let r = line.range(of: "tvg-name=\"") {
                let rest = line[r.upperBound...]
                if let q = rest.firstIndex(of: "\"") { n = String(rest[..<q]) }
            }
            if n.isEmpty, let c = line.range(of: ",", options: .backwards) {
                n = String(line[c.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            pending = n
        } else if !line.hasPrefix("#") && line.contains("://") {
            if let n = pending {
                items.append(Item(name: n, url: line.trimmingCharacters(in: .whitespaces)))
            }
            pending = nil
        }
    }
} catch {
    FileHandle.standardError.write("读不了输入: \(error)\n".data(using: .utf8)!)
    exit(1)
}

FileHandle.standardError.write("待测 \(items.count) 条，并发 \(conc)，单条上限 \(Int(tmo))s\n".data(using: .utf8)!)

final class Runner: NSObject, WKNavigationDelegate {
    var wv: WKWebView!
    var win: NSWindow!

    func start() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: cfg)
        wv.navigationDelegate = self
        win = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1000, height: 700),
                       styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = wv
        win.orderFrontRegardless()
        wv.load(URLRequest(url: pageURL))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        run()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("页面加载失败: \(error.localizedDescription)\n".data(using: .utf8)!)
        NSApp.terminate(nil)
    }

    func run() {
        let payload: [[String: String]] = items.map { ["name": $0.name, "url": $0.url] }
        let js = """
        return await new Promise((resolve) => {
          const list = ITEMS;
          const CONC = CONC_VAL, TMO = TMO_VAL;
          const results = new Array(list.length);
          let next = 0, live = 0, done = 0;

          function probe(item, idx) {
            return new Promise((doneProbe) => {
              const v = document.createElement('video');
              v.muted = true; v.playsInline = true; v.preload = 'auto';
              let fin = false;
              const finish = (ok, w, h, err, at) => {
                if (fin) return; fin = true;
                results[idx] = { name: item.name, url: item.url, ok: ok, w: w, h: h, err: err, at: at };
                try { v.pause(); v.removeAttribute('src'); v.load(); } catch (e) {}
                doneProbe();
              };
              v.addEventListener('playing', () => finish(v.videoWidth > 0, v.videoWidth, v.videoHeight, 0, 'playing'));
              v.addEventListener('loadeddata', () => { if (v.videoWidth > 0) finish(true, v.videoWidth, v.videoHeight, 0, 'loadeddata'); });
              v.addEventListener('error', () => finish(false, 0, 0, (v.error || {}).code || -1, 'error'));
              setTimeout(() => finish(v.videoWidth > 0, v.videoWidth, v.videoHeight, (v.error||{}).code || 0, 'timeout'), TMO * 1000);
              v.src = item.url;
              v.load();
              v.play().catch(() => {});
            });
          }

          function pump() {
            while (live < CONC && next < list.length) {
              const i = next++;
              live++;
              probe(list[i], i).then(() => { live--; done++; if (done === list.length) resolve(results); else pump(); });
            }
          }
          pump();
        });
        """
        wv.callAsyncJavaScript(js,
                               arguments: ["ITEMS": payload, "CONC_VAL": conc, "TMO_VAL": tmo],
                               in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                guard let arr = value as? [[String: Any]] else {
                    FileHandle.standardError.write("返回格式异常\n".data(using: .utf8)!)
                    NSApp.terminate(nil); return
                }
                var lines = ["ok\tname\tres\terr\turl"]
                var okCount = 0
                for r in arr {
                    let name = (r["name"] as? String) ?? "?"
                    let url = (r["url"] as? String) ?? ""
                    let ok = (r["ok"] as? Bool) ?? false
                    let w = (r["w"] as? Int) ?? 0
                    let h = (r["h"] as? Int) ?? 0
                    let err = (r["err"] as? Int) ?? 0
                    let at = (r["at"] as? String) ?? "?"
                    if ok { okCount += 1 }
                    let res = ok ? "\(w)x\(h)" : at
                    lines.append("\(ok ? "Y" : "N")\t\(name)\t\(res)\t\(err)\t\(url)")
                }
                try? lines.joined(separator: "\n").appending("\n")
                    .write(toFile: outPath, atomically: true, encoding: .utf8)
                let pct = arr.isEmpty ? 0 : Double(okCount) / Double(arr.count) * 100
                print("WKWebView 实测可播 \(okCount) / \(arr.count) = \(String(format: "%.1f", pct))%")
                var codes: [Int: Int] = [:]
                for r in arr where !((r["ok"] as? Bool) ?? false) {
                    let e = (r["err"] as? Int) ?? 0
                    codes[e, default: 0] += 1
                }
                for (k, v) in codes.sorted(by: { $0.value > $1.value }) {
                    print("  失败 error.code=\(k) : \(v) 条")
                }
                print("明细: \(outPath)")
            case .failure(let e):
                FileHandle.standardError.write("JS 失败: \(e.localizedDescription)\n".data(using: .utf8)!)
            }
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let runner = Runner()
runner.start()
DispatchQueue.main.asyncAfter(deadline: .now() + Double(items.count) * 1.2 + 900) {
    print("总超时退出")
    NSApp.terminate(nil)
}
app.run()
