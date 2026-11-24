# 开台直播 · KaiTai Live

内置 libmpv 播放内核的 macOS 直播 App。点开频道就出画面，无广告、无依赖、关窗即释放资源。

**下载**：[GitHub Releases · v1.0.2](https://github.com/XiaoluD/kaitai/releases/latest)（约 65 MB，Apple Silicon）

## 特性

- **双视图**：频道视图（跨源聚合同名频道，一键换线路）与播放源视图，设置里切换
- **分类导航**：央视频道 / 卫视频道 / 港澳台 / 其他；央视按台号排序，卫视按热度排序
- **内嵌 libmpv**：HLS / FLV / RTMP / MPEG-TS 全格式直连，视频流直连源站，不消耗任何服务器带宽
- **多源聚合**：自动合并多个 m3u 源，同名频道（含不同清晰度变体）聚合为一条，线路一键切换
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
brew install mpv dylibbundler     # libmpv 内核 + 依赖收拢工具
./mac-app/build.sh                # 产出 mac-app/build/开台直播.app
```

libmpv 位置由 `MPV_PREFIX` 变量控制（默认 `~/.kaitai/mpv`），换库不用改源码。

## 未签名说明

App 未签名未公证，首次打开：右键 →「打开」，或

```bash
xattr -dr com.apple.quarantine "/Applications/开台直播.app"
```

## 目录结构

```
iptv-web/
├── web/                ← 界面层（WKWebView 加载）：index.html / app.js / styles.css / sources.json
├── mac-app/            ← 原生壳：main.swift（窗口/菜单/mpv 桥）、Updater.swift（自动更新）、build.sh
├── 01-公共源/          ← 公共源同步与校验脚本（sync-public.sh / verify.py / deep-verify.sh）
├── 02-自建Fork/        ← 自建 iptv-api 源同步
└── .github/workflows/  ← Release 自动构建（macos-15 runner）
```

## 自动更新

App 内「设置 → 关于 → 检查更新」会比对 GitHub Releases 最新版本，命中后自动下载、换包、重启。更新走 GitHub API，国内网络可能需要代理。

## 已知限制

- 公共源随时失效，属 IPTV 固有属性；App 内一键更新源可重新拉取可用列表
- 合规：源均为公开网络收集，个人自用，不得商用或对外分发源列表
