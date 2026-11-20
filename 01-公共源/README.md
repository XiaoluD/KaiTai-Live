# 01 · 公共源（别人维护，我只做同步）

## 定位

这些 m3u 由第三方仓库的工作流自动扫描、验证、更新，我这边**只定时把它们下载到服务器本地**，不参与生成。

同步到本地的好处：页面 `fetch` 播放列表是同源请求，不会有 CORS 问题；视频流地址本身不变，仍然由浏览器直连源站。

## 当前收录

| 源 | 上游 | 更新频率 | 实测（2026-11-20） |
|---|---|---|---|
| `public-zbds-ipv4.m3u` | [vbskycn/iptv](https://github.com/vbskycn/iptv) 工作流 | 每 6 小时自动扫描 | 339 频道，80 KB，当日 10:35 更新 |
| `public-zbds-ipv6.m3u` | 同上，IPv6 版 | 同上 | **仅 1 个频道**——上游已声明「大部分 IPv6 源都关门了」，故未放进页面按钮 |

IPv6 版仍会同步（文件在 `web/playlists/`），但没挂到页面上，避免给人一种「有 1 个台可用」的错觉。等上游恢复后，在 `web/sources.json` 的 `sources` 数组里补一条即可：

```json
{
  "id": "public-zbds-v6",
  "name": "zbds IPv6",
  "type": "public",
  "file": "playlists/public-zbds-ipv6.m3u",
  "note": "家宽需有 IPv6"
}
```

上游直连地址（sync 脚本用的就是这些）：

```
https://live.zbds.top/tv/iptv4.m3u
https://live.zbds.top/tv/iptv6.m3u
```

域名被运营商污染时的备用通道：

```
https://gh-proxy.com/raw.githubusercontent.com/vbskycn/iptv/refs/heads/master/tv/iptv4.m3u
```

## 同步方式

```bash
# 手动跑一次
./01-公共源/sync-public.sh

# 或交给 cron，每 6 小时一次（见 deploy/crontab.txt）
```

脚本行为：`curl` 拉取 → 校验首行是否为 `#EXTM3U` → 校验通过才覆盖本地文件（防止把 502 错误页写成 m3u）→ 打印频道数。失败不动旧文件，页面继续用上一版。

## 已知边界

- **不保证可用**：这些源是别人扫出来的，随时失效。上游自己也在 README 里写「不保证可用性、稳定性和合法性」。
- **合规**：源全部收集自公开网络，转播权未授权。个人自用风险低但不为零，禁止对外分享或商用。
- **可播率实测**：抽 60 条探测，20 条（33%）返回 200 且带 `Access-Control-Allow-Origin: *`——只有这部分能在网页里直接播；其余仍需走「复制直链 → PotPlayer」。
