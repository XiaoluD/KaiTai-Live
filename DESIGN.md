---
version: alpha
name: KaiTai Day Glass
description: 开台 IPTV 播放器的产品化设计系统。浅色为默认（Apple 风格），深色可选、可跟随系统；橙粉渐变品牌色（继承应用图标）。
---

## 设计理念

参考 APTV / iPlayTV / TiviMate 三款现代 IPTV 应用：**播放器是唯一主角**，频道区是「可扫读的卡片墙」而不是密集列表。整体深色 + 单一渐变强调色，所有控件只在与内容对比时浮现。

## Colors

```yaml
colors:
  bg: "#0E1014"            # 页面底色：近黑冷灰
  surface: "#151A21"       # 卡片/侧栏面板
  surfaceElevated: "#1C2230"
  line: "rgba(255,255,255,0.08)"
  ink: "#E9ECF0"           # 主文字
  ink2: "#98A2B3"          # 次级文字
  ink3: "#5D6676"          # 弱化文字/占位
  accentFrom: "#FF9F45"    # 品牌渐变起点（图标橙）
  accentTo: "#FF4E6B"      # 品牌渐变终点（图标粉）
  accent: "#FF7A54"        # 渐变中值，用于文字强调
  accentSoft: "rgba(255,122,84,0.14)"
  ok: "#3DD68C"
  warn: "#F5B94B"
  danger: "#FF5C5C"
  scrim: "rgba(6,8,11,0.62)"
```

## Typography

系统字体栈（PingFang SC / SF Pro），不引入外部字体。

```yaml
typography:
  brand: { fontSize: 17px, fontWeight: 700, letterSpacing: 0.01em }
  pageTitle: { fontSize: 13px, fontWeight: 600, color: ink2 }
  channelName: { fontSize: 14px, fontWeight: 600, color: ink }
  meta: { fontSize: 12px, fontWeight: 400, color: ink2 }
  micro: { fontSize: 11px, fontWeight: 500, color: ink3 }
  nowPlaying: { fontSize: 15px, fontWeight: 600 }
```

## Geometry

```yaml
radius:
  card: 14px
  button: 10px
  pill: 999px
  player: 16px
spacing: [4, 8, 12, 16, 20, 28]
```

## 组件规则

1. **顶栏**：左侧品牌（图标字标），中间搜索（圆角胶囊、聚焦时 accent 边框），右侧「检查更新 / 更新源」按钮。
2. **源轨道**：左侧竖向 rail，当前选中项为 accentSoft 底 + accent 左侧 3px 指示条；未选中透明。
3. **频道卡片**：CSS Grid（minmax(150px,1fr)）；卡片 = logo（48px，无 logo 用首字方块）+ 频道名 + 分组 micro；hover 抬升 2px + 边框 accent；当前播放卡片带 accent 描边与「正在播放」角标。
4. **播放器**：16px 圆角，四周 scrim 渐晕；底部控制条玻璃拟态（backdrop-filter: blur），包含 播放/暂停、音量、重试。
5. **状态色**：失败红、成功绿只用于文字与 8px 圆点，不做大面积色块。
6. **动效**：只允许 120–180ms ease-out 的 transform/opacity，禁止宽度/高度动画。
