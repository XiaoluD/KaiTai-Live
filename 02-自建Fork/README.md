# 02 · 自建源（Fork `Guovin/iptv-api`）

## 最终采用：本机跑，不走 GitHub Actions

一条命令重新生成并接入 app：

```bash
./02-自建Fork/run-local.sh
```

### 为什么放弃 Actions

| 选择 | 结论 | 依据 |
|---|---|---|
| GitHub Actions | ❌ 放弃 | ① 手动 token 权限不足，无法用 API 启用/触发 workflow（403 Resource not accessible by personal access token）；② 上游只给 `workflow_dispatch`，不给 fork 加 cron；③ 更根本的是 **runner 在海外机房，测速国内 IPTV 源的代表性差** |
| **本机跑** | ✅ 采用 | 测速结果等于你家宽带的真实体验，筛出来的源对你确实可用；GitHub 仓库只当"源码镜像" |

### 实测结果（2026-11-20 13:07，本机）

| 指标 | 数值 |
|---|---|
| 原料源 | zbds IPv4/IPv6 + imDazui `m3u/CCTV.m3u`（本地副本，413 频道） |
| 聚合候选 | 229 个接口 |
| 测速通过 | **31 个**（失败/过滤 198，其中超时 31、规则过滤 25） |
| 覆盖频道 | **25 个台**（部分台有多个备用源，故 31 条） |
| 单次耗时 | **46–73 秒** |
| 首条播放验证 | CCTV-1，1280×720，readyState 4，连续播放 38 秒 ✅ |

拿到的台：CCTV-1/2/9/10/12/13 + 广东、浙江、湖南、北京、黑龙江、安徽、重庆、东方、东南、吉林、江苏、辽宁、内蒙古、山东、山西、深圳、天津、新疆卫视 + 广州综合。

**每个条目都通过了 720p 以上 + 速率 ≥0.5 MiB/s + 广告循环过滤 + FFmpeg 可解码四道检查**，这也是它比原始公共源（33% 可播）更有价值的原因。

### 为什么只有 25 个台

不是筛选太严，是原料不够：zbds 缺央视 1–12 套（只有 CCTV13/17/怀旧剧场/CGTN），imDazui 的 CCTV.m3u 覆盖全但**大量候选已失效**（前 100 个候选 0 通过，越往后才有活源）。

补台办法：往 `config/subscribe.txt` 加更多订阅源，或把 m3u 丢进 `config/local/` 目录，再跑 `run-local.sh`。

---

## 先说一个必须更正的事实

上一轮我说「Fork 后开 Actions 就能每天自动跑」——**不准确，已核实并撤回**。

上游 `master/.github/workflows/main.yml` 的实际写法：

| 项 | 实际情况 |
|---|---|
| 触发条件 | `on: workflow_dispatch` —— **只有手动触发**，没有 schedule |
| 仓库明文提示 | 「请不要在 fork 的仓库中添加 `on: schedule` 定时任务（cron）」 |
| 发布方式 | Pages artifact + 每次运行独立的 Release，**不回写 Git** |
| 频繁更新的官方建议 | Docker、命令行、GUI 或外部对象存储 |

所以「Fork + 每日自动」这条路，要么自己加 cron（违背上游约定，且 fork 的定时任务常被 GitHub 静默停用），要么另给一台常开机器。下面三条都是真实可行的。

## 三条路径对比

| 路径 | 自动更新 | 成本 | 状态是否持久 | 适用 |
|---|---|---|---|---|
| **A. Fork + 手动点 Run** | ❌ 手动 | 0 | ❌ 每次重置 | 想先看效果、频道不多 |
| **B. 家里常开设备跑 Docker** | ✅ 12h 一次 | 0（电费） | ✅ 状态落盘 | **推荐**：NAS / 旧笔记本 / 树莓派 |
| **C. ECS 跑 Docker** | ✅ 12h 一次 | 极低（只出列表，几 KB） | ✅ | 没有常开设备时 |

⚠️ 路径 C 的固有缺陷（上一轮已列，此处复述因为直接影响选型）：**测速是在服务器上做的**，机房到你家的网络路径不同，筛出来的「快源」在你家可能最慢。若 ECS 选武汉本地域，偏差会小一些，但仍不等于家宽实测。

## 路径 A：Fork + 手动触发

1. Fork `https://github.com/Guovin/iptv-api`
2. 仓库 `Settings → Pages`，Source 选 **GitHub Actions**
3. `Actions → Generate playlist manually → Run workflow`
4. 跑完（首次 5–20 分钟）后，在 run 的 Summary 里能看到两条链接：
   ```
   https://<你的用户名>.github.io/iptv-api/result.m3u
   https://<你的用户名>.github.io/iptv-api/result.txt
   ```
5. 把这个地址填进 `self.env` 的 `SELF_URL`，再执行 `./02-自建Fork/sync-self.sh`

频道清单改 `config/demo.txt`（`频道名,地址` 或 `分组名,#genre#` 开头），或复制一份 `user_demo.txt` 再改，避免跟随上游更新时冲突。

## 路径 B / C：Docker 常驻

```bash
mkdir -p ~/iptv-api && cd ~/iptv-api
curl -o docker-compose.yml https://raw.githubusercontent.com/Guovin/iptv-api/master/docker-compose.yml
docker compose up -d
# 结果文件: ./output/result.m3u
# 自带 Web 页面: http://<host>:8080  （只是结果索引页，不是播放器）
```

默认 `update_mode = interval`、`update_interval = 12`，即每 12 小时跑一次，状态持久化在 `output/data/`。

## 要改的参数（键名已从上游 `config/config.ini` 核对）

```ini
; —— 直接决定「无广告 + 清晰 + 流畅」这三条 ——
open_speed_test      = True    ; 必须开，否则不测速不筛源
open_filter_speed    = True
min_speed            = 0.5     ; MiB/s，低于此值丢弃
open_filter_resolution = True
min_resolution       = 1280x720 ; 只要 720p 以上
open_filter_ad       = True    ; 广告过滤：识别无信号/广告循环占位源
sort_by              = speed   ; 按实测速率排序（想更清晰改 resolution）

; —— 输出 ——
open_m3u_result      = True
output_urls_limit    = 5       ; 每频道保留 5 个备用接口
open_url_info        = False   ; PotPlayer 解析 $ 后缀会出问题，保持 False

; —— 双栈 ——
ipv_type             = all     ; 家里有 IPv6 可设 ipv6 优先，源质量通常更好
```

## 产物同步

```bash
cp self.env.example self.env   # 填入你的 Pages 地址
./02-自建Fork/sync-self.sh
```

脚本会拉 `result.m3u` → 校验 → 覆盖 `web/playlists/self-iptv-api.m3u`。页面上「自建 · 我的 iptv-api」这个按钮读的就是它。

## 合规

上游 README 明确：本项目是**工具/框架，不含任何直播源**，源需自行添加，且「请确保所使用的数据源符合当地法律法规」。自建只是把筛选自动化，不改变源的授权状态。
