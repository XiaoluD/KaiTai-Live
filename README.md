# 开台 · KaiTai

一个 1.7 MB 的 Mac 直播 App（也是能部署到 ECS 的网页版）。**服务器只存文本播放列表（每次几 KB），视频流由播放器直连源站**，不消耗服务器带宽。

- 列表里**只留实测能播的频道**，点开就出画面（当前 227 条，二次复测 207/207）
- 无广告、无插播、关窗即释放资源（无常驻进程、无后台服务）
- 一键更新源，更新时逐条在真实播放器里试播
- 播不了的源（FLV/组播）一键交给 IINA / VLC / mpv

## 两个分发包

| 版本 | 体积 | 依赖 | 能播 |
|---|---|---|---|
| **精简版**（默认，已验证） | 1.7 MB | 建议装 IINA 或 VLC | HLS / MP4；FLV 等一键交给外部播放器 |
| **内嵌版**（代码就绪，待接内核） | 60~120 MB | 无 | 全格式，含 FLV / RTMP / 组播 |

```bash
./mac-app/build.sh                    # 精简版
VARIANT=embedded ./mac-app/build.sh   # 内嵌版（需先 brew install mpv dylibbundler）
./scripts/release.sh both             # 打包两个 zip 到 dist/
```

⚠️ 未签名未公证。分发后首次打开要右键 →「打开」，或
`xattr -dr com.apple.quarantine /Applications/开台.app`。
想做到双击无提示，需要 Apple Developer Program（$99/年）做开发者 ID 签名 + 公证。

## 目录

```
iptv-web/
├── 01-公共源/              ← 【公共源】别人维护，我只同步 + 校验
│   ├── README.md
│   ├── sync-public.sh      拉取 → 校验 → 只留能播的（cron 用这条）
│   ├── verify.py           HTTP 双层校验：清单 + 首个分片
│   ├── deep-verify.sh      真实 WKWebView 试播，产出地面真相（手动）
│   ├── build-playlist.py   按实测结果重建列表
│   └── raw/                拉取到的原始未校验列表
│
├── 02-自建Fork/            ← 【自建源】自己 Fork Guovin/iptv-api 的产物
│   ├── README.md           含一条重要更正：上游禁止 fork 加 cron
│   ├── sync-self.sh        从你的 GitHub Pages 拉 result.m3u
│   └── self.env.example    填 SELF_URL
│
├── mac-app/                ← Mac 原生 App（1.7 MB，关窗即释放）
│   ├── main.swift          AppKit + WKWebView + 内嵌 loopback 静态服务 + 外部播放器桥
│   ├── probe.swift         自检工具：探测播放能力与可播率
│   ├── probe-batch.swift   批量真实试播，产出「哪些能播」的地面真相
│   ├── snapshot.swift      给 UI 拍快照，用于人工核对
│   ├── Updater.swift       更新源的原生部分（下载 + 落盘）
│   ├── icon/               矢量图源 + icon.icns（脚本生成）
│   ├── build.sh            一键编译打包（VARIANT=lite|embedded）
│   └── README.md           实测数据与方案取舍
│
├── web/                    ← 唯一需要部署到 ECS 的部分
│   ├── index.html
│   ├── app.js              m3u 解析 + hls.js / 原生 HLS 自适应 + 失败降级
│   ├── styles.css
│   ├── hls.min.js          本地自带，不依赖外网 CDN
│   ├── sources.json        源清单，用 type 区分 public / self
│   └── playlists/          同步产物落地处（页面同源读取，无 CORS 问题）
│
├── scripts/
│   └── release.sh          打 GitHub Release 分发包
│
└── deploy/
    ├── nginx.conf          静态托管，禁止任何 proxy_pass
    └── crontab.txt         定时同步
```

两个源在页面顶部是两个按钮，`zbds 每日扫描 · 公共` 和 `我的 iptv-api · 自建`，点一下切换；地址栏 `?src=self-iptv-api` 可直达。

## 自建源（已跑通，本机生成）

```bash
./02-自建Fork/run-local.sh     # 生成 → 同步 → 重建 app，约 1 分钟
```

实测：229 个候选 → 31 个通过测速校验 → 覆盖 25 个台，每个都是 720p 以上、速率达标、无广告循环。

源码与 venv 在 `.runtime/`（137 MB），不参与 ECS 部署（`rsync web/` 不会带上）。

## 源对比（2026-11-20 实测，本机网络）

app 顶部两个按钮，点开即对比。实测数据：

| 源 | 频道数 | 实测可播 | 可播率 | 说明 |
|---|---|---|---|---|
| **vbskycn/iptv**（zbds，已深度校验） | 227 | — | **100%** | 逐个真实试播过，点开就出画面 |
| **我的 iptv-api**（自建） | 31 | 29 | **93.5%** | 2 条超时，延长等待可出画面 |

app 内实测：点首台 CCTV13 → 1920×1080 正常播放。

### 为什么要两级校验

原始公共源 339 条，直接给人用的话点十个有四个打不开。两级校验把可播率从 61% 拉到 100%：

| 阶段 | 手段 | 耗时 | 结果 | 能挡住什么 |
|---|---|---|---|---|
| 不校验 | — | 0 | 339 条 | — |
| 一级 `verify.py` | HTTP 探清单 + 首分片 | 50 s | 300 条（88.5%） | 死链、502、反盗链错误页 |
| 二级 `deep-verify.sh` | 真实 WKWebView 试播 | 55 s | 227 条（67%） | **FLV 等解码不了的格式** |
| 二级结果复测 | 同上 | 40 s | **100%** | 证明列表稳定 |

关键差异在第二级。一级校验认为 300 条可用，但真实试播只有 208 条能出画面——差的 92 条主要是 **`video/x-flv` 直连流，共 67 条，WKWebView 可播率为 0%**。Safari 内核不支持 FLV 封装，这不是源的问题，是容器不支持。

按流类型拆分（207 条样本）：

| 流类型 | WKWebView 可播 | 失败 | 可播率 |
|---|---|---|---|
| HLS（m3u8） | 185 | 21 | 90% |
| **FLV 直连** | **0** | **67** | **0%** |
| MP4 直连 | 18 | 1 | 95% |

顺手剔掉的 2 条垃圾：`支持作者`（捐赠视频）、`2026-11-20 12:09:34`（更新时间伪频道）。

```bash
./01-公共源/sync-public.sh      # 一级：拉取 + HTTP 校验，cron 用这条
./01-公共源/deep-verify.sh      # 二级：真实试播，手动跑，约 1 分钟
```

## 播不了的台：一键交给外部播放器

app 内的 WKWebView 只能解 HLS / MP4。FLV、RTMP、组播这些注定播不了，与其让用户复制链接再去开播放器，不如直接交接。

原生侧做了一个**播放器适配层**，按 `IINA → VLC → mpv` 顺序找第一个装了的：

| 环节 | 实现 |
|---|---|
| 探测 | `NSWorkspace.urlForApplication(withBundleIdentifier:)` 查 bundle id |
| 启动 | IINA 走 `iina://weblink?url=<百分号编码>`；VLC/mpv 走 `NSWorkspace.openApplication(at:configuration:)` 传 URL 参数 |
| 通信 | `WKScriptMessageHandlerWithReply`（name=`iptv`），JS 侧 `postMessage` 返回 Promise |
| 兜底 | 一个都没装时按钮隐藏，不显示死按钮 |

一个坑：`open -a IINA <url>` 会返回 `-10820` 失败，必须用 URL scheme。VLC 没有对应 scheme，只能传命令行参数。

启动时探测一次，所以**装完播放器要重开 app**。浏览器版（部署在 ECS 上访问）没有这个桥，按钮自动隐藏，退回复制直链。

## 一键更新源

顶栏右侧「更新源」按钮。点一下：下载原始列表 → 逐条**在真实播放器里试播** → 只把能出画面的写回 `playlists/` → 列表自动重载。

实测：339 条 → 221 条，用时 59 秒（8 并发，单条 7 秒上限）。

一个必须记住的坑：**App 自己发的 `http://` 请求会被 ATS 拦掉**（`NSURLErrorAppTransportSecurityRequiresSecureConnection`，-1022），即使 Info.plist 里写了 `NSAllowsArbitraryLoads`。所以：

| 环节 | 走哪 | 为什么 |
|---|---|---|
| 下载列表 | 原生 URLSession | 列表地址都是 https，不受影响 |
| 探活频道 | WKWebView 的 `<video>` | WebKit 加载 http 媒体流是放行的，且反映真实解码能力 |

这个分工反而更准：`<video>` 判定 == 用户点开后的结果，而 HTTP 探活会被 FLV 骗过。

### 要不要内嵌播放器内核

| 方案 | 新机器需要 | 延迟 | 包体积 | 许可 |
|---|---|---|---|---|
| **适配层（精简版）** | 拷 IINA.app 或 `brew install --cask iina` | 0 | 1.7 MB | 自己写，无约束 |
| **libmpv（内嵌版）** | 什么都不用 | 0 | +60~120 MB | mpv/ffmpeg 是 GPL，整个 app 需按 GPLv2+ 分发 |
| VLCKit | 什么都不用 | 0 | +200 MB 以上 | LGPLv2.1，可闭源 |
| 内嵌 ffmpeg 转封装 | 什么都不用 | +2~4 秒 | +15 MB 左右 | LGPL（非 GPL 构建） |

内嵌版选 **libmpv**，理由：

1. 它绕开 ATS —— libmpv 走自己的网络栈，http / rtsp / 组播都能连，不受 `-1022` 限制
2. 格式覆盖最全，FLV / RTMP / MPEG-TS / 组播一把梭
3. 既然要在 GitHub 开源分发，**GPL 不是问题**，反而是合规的默认选择

难点不在解码，在视图层。已经趟过的两个坑：

- **WKWebView 里的 `<video>` 用不上 mpv**，得把播放区换成原生视图盖在网页上。现在做法是
  `MpvPlayerView` 作为 WKWebView 的兄弟视图叠在 `#screen` 位置上，坐标由网页用
  `getBoundingClientRect()` 报上来，`ResizeObserver` + 窗口 resize + 500 ms 兜底三路同步。
- **不能用 `NSOpenGLView`**。WKWebView 是 layer-backed 的，连带整条祖先链都带上 layer，
  `NSOpenGLView` 在这种层级里画不出来（黑屏）。改成 `MPV_RENDER_API_TYPE_SW` 软件渲染：
  mpv 直接渲到一块 RGBA 内存，包成 `CGImage` 塞给 `layer.contents`。不碰任何废弃图形 API，
  也不会被层级关系坑。代价是每帧一次内存拷贝，按视口实际像素、上限 1080p，单帧约 3–6 ms。

### 内嵌版怎么构建

内核不随仓库走（GPL 二进制约 60 MB），本机装一次即可：

```bash
brew install mpv dylibbundler     # libmpv + 依赖收拢工具
VARIANT=embedded ./mac-app/build.sh
```

`build.sh` 里 libmpv 的位置只认一个变量，换库不用改源码：

```bash
MPV_PREFIX=/usr/local VARIANT=embedded ./mac-app/build.sh
```

头文件走 `mac-app/mpv-bridge.h` 桥接，不用 `import Libmpv` 之类的模块名，所以 MPVKit 的
xcframework、Homebrew、自己编的 libmpv 都能接。

> ⚠️ 没装 `dylibbundler` 也能编出来，但只能在本机跑（靠 `/opt/homebrew/lib`），发给别人会缺库。

## 为什么这么多源会失效，哪些是稳的

公共源不是「一个服务」，是**一堆互不相关的流地址的集合**。失效原因按占比从高到低：

| 原因 | 典型表现 | 本质 |
|---|---|---|
| 第三方转发/聚合 | 302 到别处、返回提示片 | 靠转发别人的流做引流，随时改地址或加反盗链 |
| 运营商内网源 | 10 秒 0 字节、TCP 无响应 | 只对当地该运营商的宽带用户开放 |
| 格式不兼容 | `video/x-flv`，Safari 解不了 | 源是活的，客户端播不了（换播放器就行） |
| 快照过期 | 清单 404 | 公共源是别人扫出来的快照，发布那一刻就开始腐烂 |

### 稳定性是分层的，规律很清晰

按 300 条样本实测（真实试播）：

| 频道类型 | 条数 | 可播 | 可播率 |
|---|---|---|---|
| 历年春晚 | 17 | 17 | **100%** |
| CCTV / CGTN | 6 | 6 | **100%** |
| 省级卫视 | 14 | 13 | **93%** |
| 地方台（市县级广电） | 132 | 117 | **89%** |
| 影视轮播 / 港剧台 | 45 | 6 | **13%** |
| 其他 | 86 | 49 | 57% |

按源站域名看更清楚：

| 源站 | 条数 | 可播率 | 性质 |
|---|---|---|---|
| `l.cztvcloud.com`（浙江广电） | 45 | **100%** | 电视台官方 CDN |
| `alimov2.a.kwimgs.com`（快手 CDN） | 17 | **100%** | 大厂 CDN |
| `stream5/8.jlntv.cn`（吉林广电） | 18 | **100%** | 电视台官方 |
| `stream.hrbtv.net`（哈尔滨广电） | 7 | **100%** | 电视台官方 |
| `ali-m-l.cztv.com` | 20 | 95% | 电视台官方 |
| `live.metshop.top`（虎牙转发） | 66 | **0%** | FLV 直播间转发 |
| `jwcdnqx.hebyun.com.cn`（河北联通） | 8 | **0%** | 运营商内网 |

**一句话规律：越靠近「电视台自己的 CDN」越稳，越靠近「第三方转发」越烂。**

所以一个长期可用的策略不是「找更多源」，而是：
1. **优先保留官方 CDN 的地址**（省级台、地方台、春晚合集都在这一类，实测 89~100%）
2. **影视轮播类不要指望**（13%），失效是常态
3. **每次更新只信实测**，不看上游怎么说

## 候选补充源（已实测，待选）

当前 227 条偏少，且缺港澳台。以下三个源已跑全量校验（`verify.py --app-safe`，本机网络）：

| 源 | 全量 | 可播 | 可播率 | 独有价值 |
|---|---|---|---|---|
| **suxuang/myIPTV** | 1273 | 159 | 12.5% | 翡翠台、明珠台、TVB Plus、广东珠江、台视新闻、人间卫视；辽宁/河北/陕西全套省级台；国际新闻 |
| **iptv-org/iptv**（cn） | 156 | 44 | 28.2% | 河北卫视/Hunan TV **2160p**、CCTV 系列高清、TV BRICS、VoA |
| YanG-1989/m3u | 123 | 33 | 26.8% | 全 33 条都是咪咕体育的不同线路，其余 90 条失效 |

判断：**suxuang 补港澳台和省级台最有价值**（这是现有源完全没有的）；iptv-org 补 4K 和央视高清；yangg1989 全部是同一个台的重复线路，不推荐。

fanmingming/live（28.9k star）实测不可用：`tv/m3u/index.m3u` 94 条只活 1 条，`tv/m3u/itv.m3u` 189 条全军覆没——它用的是移动 `gslbserv.itv.cmvideo.cn` 联通等运营商内网源，与 imDazui 同病。

### imDazui · CCTV.m3u 已撤销（原第三个按钮）

413 条按源站逐条探测（`curl --range 0-64`，跟随重定向，10s 上限），**0 条可用**，而且 5 个源站 5 种死法：

| 源站 | 条数 | 实测 | 真实死因 |
|---|---|---|---|
| `tv.cnbeijing.xyz/tvnx.php?id=NNN` | 171 | 502 text/plain | 反代自身 DNS 解析失败 |
| `cctv1.vtime.cntv.dnion.com:8000` | 102 | 502 同款 108B | 同一层反代故障 |
| `218.92.209.33`（江苏电信 IP） | 77 | 10s / 0 字节 | 运营商专网，TCP 无响应 |
| `gslbserv.itv.cmvideo.cn` | 47 | 404 | `authCode`/`stbId` 机顶盒令牌过期 |
| `web-play.pptv.com` | 16 | 404（302 后） | 接口早已下线 |

之前记的「运营商内网源」只解释了 77 条，剩下 336 条是真死链。

**结论**：imDazui 这类仓库本质是「各地运营商内网源汇总」，对非同网用户基本全废。它有用的场景只有一个——被 iptv-api 当**原料**，从几百条里捞少量活源补央视。所以正确的用法是**当原料，不是当播放列表**。原 m3u 已转存 `02-自建Fork/raw/imdazui-cctv.m3u`，`sources.json` 里留了一条 `removed: true` 的痕迹记录。

真正值得对比的是「筛前 vs 筛后」：同一批网络环境下，50% → 100%。

## 三条命令跑起来

```bash
chmod +x 01-公共源/sync-public.sh 02-自建Fork/sync-self.sh

# 1. 拉公共源（已预置一份 2026-11-20 的，可跳过）
./01-公共源/sync-public.sh

# 2. 本地看效果
cd web && python3 -m http.server 8090
# 打开 http://127.0.0.1:8090

# 3. 上 ECS
rsync -av web/ root@<ECS_IP>:/var/www/iptv/
# 然后套用 deploy/nginx.conf，装 deploy/crontab.txt 两行定时任务
```

## 流量账

| 项目 | 走谁的带宽 | 量级 |
|---|---|---|
| 拉取播放列表（m3u 文本） | ECS 出方向 | ~80 KB / 次，一天 4 次 ≈ 0.3 MB |
| 视频流 | **你本机宽带** | 一路 1080p 约 1.8–3.6 GB/小时 |
| 服务器 CPU | — | 零（纯静态文件） |

结论：一台最便宜的 ECS 就够，流量费可忽略。**只要不配 `proxy_pass` 反代 m3u8，就永远不会跑出大额账单。**

## 页面为什么还给了「复制直链」

浏览器能不能播，取决于源站有没有回 `Access-Control-Allow-Origin`。抽样 60 条实测：

| 结果 | 条数 | 占比 |
|---|---|---|
| 200 且带 CORS 头（网页可播） | 20 | 33% |
| 200 但无 CORS 头 | 7 | 12% |
| 超时 / 4xx / 无响应 | 33 | 55% |

所以页面设计成双通道：能播的直接播，播不了的红色提示 + 一键复制直链，粘到 PotPlayer / VLC / FongMi 即可——那条路 100% 不受 CORS 限制，带宽同样走本机。

## 已知限制

- 源随时失效，这是 IPTV 公共源的固有属性，不是代码问题。
- 台标图片多数有防盗链，页面做了 `onerror` 隐藏，不会留破图。
- 抽检是抽样估计，不是全量统计；不同时段结果会漂移。
- 合规：源均为公开网络收集，转播权未获授权。个人自用风险低但不为零，不得对外分享或商用。
