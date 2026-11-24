# 开台直播 · KaiTai Live

内置 libmpv 播放内核的网络电视直播客户端（macOS / Windows）。点开频道就出画面，无广告、无依赖、关窗即释放资源。

**下载**：[GitHub Releases · latest](https://github.com/XiaoluD/KaiTai-Live/releases/latest)

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
- **播放器交互**：点击画面暂停/播放（中央状态徽标）、**点音量图标一键静音**（再点恢复静音前的实际音量）、全屏、快捷键齐全
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

音量图标本身就是静音开关：点一次静音（图标转橙色叉号、滑块归零），再点恢复**静音前的实际音量**（不是固定回到 100）。图标可用 Tab 聚焦，聚焦后 `Enter` / `空格` 同效，且不会误触空格暂停。

## 构建

```bash
brew install mpv dylibbundler          # libmpv 内核 + 依赖收拢工具
./mac-app/build.sh                     # 产出 mac-app/build/开台直播.app
APP_VERSION=1.0.10 ./mac-app/build.sh  # 指定版本号
```

libmpv 位置由 `MPV_PREFIX` 变量控制（默认 `~/.kaitai/mpv`），换库不用改源码。

> **本地构建后前端不生效？** App 启动时优先加载 `~/Library/Application Support/IPTVWeb/` 下的前端文件（只要该目录存在 `index.html`），打包进 App 的新前端会被忽略。改完 `web/` 后需同步过去——`sources.json` 和 `playlists/` 是你的源配置与频道列表，别一起覆盖：
>
> ```bash
> cp web/{index.html,app.js,styles.css,manifest.json} ~/Library/Application\ Support/IPTVWeb/
> ```

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
├── deploy/             ← ECS 部署：sync.sh（rsync + 远端 chmod）、nginx.conf、crontab.txt
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

## 已知限制

- 公共源随时失效，属 IPTV 固有属性；App 内一键更新源可重新拉取可用列表
- 合规：源均为公开网络收集，个人自用，不得商用或对外分发源列表
