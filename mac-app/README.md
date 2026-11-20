# Mac 端：直播台.app（原生，788 KB）

打开才占资源，关窗即退出、端口立即释放。没有 Electron，没有 Docker，没有常驻后台进程。

## 构建与运行

```bash
./mac-app/build.sh
open "mac-app/build/直播台.app"
```

首次打开若被 Gatekeeper 拦，右键 → 打开（ad-hoc 签名，非开发者证书）。

## 架构（三句话）

1. 进程内起一个只绑 `127.0.0.1` 的极简静态服务（`NWListener`，随机端口）。
2. `WKWebView` 加载 `http://127.0.0.1:<随机端口>/`，页面与 ECS 版**完全同一套** `web/` 资产。
3. 关窗 → `applicationShouldTerminateAfterLastWindowClosed` 返回 true → 进程退出 → socket 随之关闭。

不用 `file://` 直开的原因：`file://` 下 `fetch('./sources.json')` 会被拦，而回环 HTTP 天然同源，两边资产零分叉。

## 更新频道列表

App 按这个顺序找内容目录：

1. `~/Library/Application Support/IPTVWeb/`（若存在 `index.html`）
2. App 包内 `Contents/Resources/web/`（构建时复制进去的快照）

所以更新列表不用重新打包：

```bash
./01-公共源/sync-public.sh
mkdir -p ~/Library/Application\ Support/IPTVWeb
rsync -a --delete web/ ~/Library/Application\ Support/IPTVWeb/
# 重启 App（⌘Q 后重开）生效
```

## 实测数据（2026-11-20，本机 arm64）

| 项目 | 结果 |
|---|---|
| 可执行文件 | 134 KB |
| 整个 .app | 788 KB（含 hls.min.js 529 KB + 339 频道列表 80 KB） |
| 内嵌服务绑定 | `127.0.0.1:<随机端口>`，仅回环，外部不可达 |
| 关窗释放 | 8 秒自检关窗后：进程消失、监听端口数 **0** ✅ |
| 列表解析 | 339 频道 ✅ |
| `Hls.isSupported()` | `true`（WebKit 支持 MSE） |
| 原生 HLS | `canPlayType` = `maybe` ✅ |
| 零 CORS 头源播测 | **2/2 成功**，1920×1080，currentTime 正常推进 |
| UI 点播链路 | 点 CCTV13 → 1920×1080、readyState 4、播放 10 秒、无错误遮罩 |

### 为什么这个数字比浏览器好

浏览器（Chrome）里必须用 hls.js（MSE），分片请求受同源策略约束——**抽样 60 条源只有 33% 带 CORS 头能播**。

WKWebView 的 `<video>` 走原生 HLS，媒体元素请求属于 no-cors，**不受 CORS 约束**——实测两条零 CORS 头的源全部播放成功。理论上限因此从 33% 提到约 45%（原因在于那 60 条里另有 12% 的源返回 200 但无 CORS 头，Chrome 播不了，这个 app 能），失败的大头仍是源本身失效（55%）。

代码上对应 `web/app.js` 的一行判断：

```js
const nativeHls = document.createElement('video').canPlayType('application/vnd.apple.mpegurl') !== '';
if (isHls && !nativeHls && window.Hls && window.Hls.isSupported()) { /* Chrome 走 MSE */ }
else { /* WebKit 走原生 */ }
```

## 关键配置：ATS 必须放开

`Info.plist` 里这几项是**必需**的，否则所有 `http://` 源直接失败：

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key><true/>
  <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
  <key>NSAllowsLocalNetworking</key><true/>
</dict>
```

## 与其它 Mac 方案的取舍

| 方案 | 形态 | 体积 | 关了是否释放 | 可播率 | 适合 |
|---|---|---|---|---|---|
| **本 App** | 原生 WKWebView | 788 KB | ✅ 完全释放 | 约 45% | 打开就看、不想装东西 |
| IPTVnator | Electron | 数百 MB | ✅ 进程退出 | 约 33%（Chromium，受 CORS） | 想要成熟 EPG/收藏界面 |
| VLC / IINA 直开 m3u | 播放器 | — | ✅ | 接近 100%（无 CORS 概念） | 只想验证源能不能用 |
| nodecast-tv 本机 | Node + Docker | 数百 MB | ❌ 常驻服务 | 近 100%（开 Force Backend Proxy） | 想看齐全、能接受常驻 |

注意最后一行：**`Force Backend Proxy` 在本机跑时成本是零**——本机流量不按 GB 计费。它只在 ECS 上才是每小时 1.4–2.9 元的成本。所以如果你发现某些台很想看但 app 播不了，正确做法是本地跑 nodecast-tv 并开 Proxy，而不是在 ECS 上开。

## 已知限制

- 只验证了 arm64 / macOS 26.6；Intel 机器需改 `build.sh` 的 target。
- 未做代码签名与公证，换机器需右键打开或 `xattr -cr`。
- 台标图片多数有防盗链，页面会隐藏加载失败的图标，不影响播放。
- 源失效只能靠重新同步列表解决，App 内没有一键更新按钮（避免引入网络请求与后台行为）。
