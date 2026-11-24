# 开台直播 · KaiTai Live

内置 libmpv 播放内核的网络电视直播客户端（macOS / Windows）。点开频道就出画面，无广告、无依赖、关窗即释放资源。

**下载**：[GitHub Releases · latest](https://github.com/XiaoluD/kaitai/releases/latest)

| 平台 | 文件 | 大小 |
|---|---|---|
| macOS arm64 | `kaitai-full-arm64.zip` | 约 28 MB |
| Windows 10/11 x64 | `kaitai-windows-x64.zip` | 约 116 MB |

## 特性

- **双视图**：频道视图（跨源聚合同名频道，一键换线路）与播放源视图，设置里切换
- **分类导航**：央视频道 / 卫视频道 / 港澳台 / 其他；央视按台号排序，卫视按热度排序
- **内嵌 libmpv**：HLS / FLV / RTMP / MPEG-TS 全格式直连，视频流直连源站，不消耗任何服务器带宽
- **多源聚合**：自动合并多个 m3u 源，同名频道（含不同清晰度变体）聚合为一条，线路一键切换
- **源自动同步**：服务端精选清单（已在服务端逐条抓帧验台标）更新后，App 启动静默比对并落盘，无需重新打包
- **一键更新源**：手动重新拉取公共源并用 `<video>` 实测筛选，只留点开就能播的线路
- **画质台标**：CCTV 系列用高清台标图床，自动适配深浅色主题
- **播放器交互**：点击画面暂停/播放（中央状态徽标）、全屏、音量、快捷键齐全
- **原生菜单栏**：复制/打开当前频道直链、更新播放源、检查更新（支持应用内自动更新）
- **双击标题栏**：最大化 / 窗口化切换；标题栏整体融入界面

## 快捷键

| 键 | 功能 |
|---|---|
| `空格` | 暂停 / 播放 |
| `↑` / `↓` | 切换频道 |
| `←` / `→` | 音量 - / + |
| `M` | 静音 |
| `F` | 全屏 |
| `R` | 重试当前频道 |

菜单栏快捷键：设置 `⌘,`、检查更新 `⌘U`、更新播放源 `⇧⌘U`、复制直链 `⇧⌘C`、浏览器打开 `⇧⌘O`。

## 构建

```bash
brew install mpv dylibbundler          # libmpv 内核 + 依赖收拢工具
./mac-app/build.sh                     # 产出 mac-app/build/开台直播.app
APP_VERSION=1.0.10 ./mac-app/build.sh  # 指定版本号
```

libmpv 位置由 `MPV_PREFIX` 变量控制（默认 `~/.kaitai/mpv`），换库不用改源码。

## 打包与发布

正常发版走 CI，不需要本地构建：

| 方式 | 命令 | 说明 |
|---|---|---|
| CI（推荐） | `git tag v1.0.10 && git push origin v1.0.10` | Actions 在 macos-15 上构建并发 Release |
| CI（Windows） | `git tag windows-1.0.10 && git push origin windows-1.0.10` | tag 会被映射成 `v1.0.10`，资产并入**同一个** Release |
| 本地备用 | `./scripts/release.sh [版本]` | 版本默认取最近 `v*` tag，产物 `dist/kaitai-full-arm64.zip` |

两条硬约束（改动前先看）：

1. **资产名固定** `kaitai-full-arm64.zip`——App 自更新按 `kaitai-{variant}-arm64.zip` 拼下载地址，改名会让所有客户端更新 404；
2. **两个平台的资产必须同属一个 Release**——App 用 `releases/latest` 的 302 跳转取 tag，latest 只有一条，独立发两个 Release 会指向错误资产。

## 未签名说明

App 未签名未公证，首次打开：右键 →「打开」，或

```bash
xattr -dr com.apple.quarantine "/Applications/开台直播.app"
```

Windows 版解压到任意目录运行 `KaiTai.exe` 即可；建议避开 `C:\Program Files`（本地静态服务需要写 `web/playlists`）。

## 目录结构

```
iptv-web/
├── web/                ← 界面层（WKWebView / WebView2 加载）：index.html / app.js / styles.css / sources.json / playlists
├── mac-app/            ← macOS 原生壳：main.swift（窗口/菜单/mpv 桥）、Updater.swift（自动更新）、MpvPlayer.swift、build.sh、icon/
├── windows-app/KaiTai/ ← Windows 原生壳：.NET 8 WinForms + WebView2 + libmpv(P/Invoke)
├── scripts/            ← update-sources.sh（拉取公共源）、release.sh（本地出包）
├── deploy/             ← ECS 部署：sync.sh（rsync + 远端 chmod）、nginx.conf、crontab.txt、healthd.py（频道巡检守护）
├── 01-公共源/          ← 公共源同步与校验（sync-public.sh / verify.py / deep-verify.sh）
├── 02-自建Fork/        ← 自建 iptv-api 源同步
└── .github/workflows/  ← release.yml（macOS）、windows-build.yml、update-sources.yml（每日更新公共源）
```

## 更新机制

两条独立通道，别混：

| 通道 | 触发 | 行为 |
|---|---|---|
| 应用本体 | 设置 → 关于 → 检查更新，或启动静默检查 | 比对 `releases/latest` 的 tag 与 `CFBundleShortVersionString`，命中则下载 zip、换包、重启 |
| 频道源 | App 启动 / 菜单「更新播放源」 | 静默比对服务端 `playlists/self-iptv-api.m3u`（按频道集合 diff，仅注释差异不写盘），有变化落盘并提示；手动更新则会重新实测公共源 |

## 频道健康度巡检（服务端）

前端不给每条频道单独发探测请求（625 条串行要 20 分钟以上，还会和播放抢源站配额）。
改由 ECS 上常驻的 `deploy/healthd.py` 巡检，产出静态文件 `/var/www/iptv/health.json`，
前端一次请求（App 走原生桥 download）即可点亮全部徽标。

- 服务：`kaitai-healthd.service`（systemd，`systemctl status kaitai-healthd`）
- 强度：并发 3、一轮约 8–10 分钟、随后歇 3 分钟（每条频道约 12 分钟刷新一次），
  失败项串行重测一次（滤掉并发误判）
- **央视频（`/akira/relay/ysp-*`）刻意不巡检**：清单由 akira 在机房向央视频官方取，
  机房 IP 会被官方 CDN 回 403；探测既探不出真实状态，又会占满 akira 的官方配额
  导致真实播放取流失败。这类频道徽标显示为「—」。
- 回退：`systemctl disable --now kaitai-healthd && rm -f /var/www/iptv/health.json`

## 已知限制

- 公共源随时失效，属 IPTV 固有属性；App 内一键更新源可重新拉取可用列表
- 合规：源均为公开网络收集，个人自用，不得商用或对外分发源列表
