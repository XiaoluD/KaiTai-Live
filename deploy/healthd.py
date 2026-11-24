#!/usr/bin/env python3
"""kaitai-healthd — 频道健康巡检守护进程（服务端只探「非央视频」，央视频交给客户端）

为什么在服务端做
----------------
客户端逐条探测 625 个频道，受 akira 央视频提取器「6 个不同频道 / 10 秒」的防探测
限制，串行最少也要 20 分钟以上；而且在浏览器里做会与用户的播放请求互相抢额度。
改成服务端常驻巡检，结果落成静态 JSON（/var/www/iptv/health.json），
前端一次请求就能给绝大多数频道打上徽标。

为什么央视频(ysp-*) 必须排除
----------------------------
实测：从 ECS 探测 ysp-* 频道会大面积拿到这样的 200 响应正文——
    CCTV1综合链接请求失败：主、备用 CDN 均不可用（live-dtocnc-cdn.ysp.cctv.cn:
    清单 HTTP 403；bklive-dtocnc-cdn.ysp.cctv.cn: 清单 HTTP 403），30 秒内暂停向官方请求
即 akira 向央视频官方取清单失败（机房 IP + 请求预算被巡检消耗）。后果有两个：
    1) 把明明是好的 CCTV1/3/4 全部标成异常（假阴性）；
    2) 耗尽 akira 的官方请求预算，连用户真实播放也一起变差。
所以 ysp-* 一律不进服务端巡检，改由客户端在用户家宽 IP 上探（见 web/app.js）。

akira 限流的真实形态（实测）
---------------------------
限流时不返回 429，而是 **HTTP 200 + 中文错误文本**。所以健康判定必须看正文，
并且对失败项做一次串行重测——并发下 akira 会瞬时返回错误文本，重测能滤掉这类误判。

健康判定
--------
只看能否取到有效流清单，兼容三种真实形态：
  * m3u8 → 正文以 #EXTM3U 开头
  * FLV  → 正文以 FLV\\x01 开头（凤凰系列等老源）
  * MPEG-TS → 首字节 0x47
正文是中文错误文本 = 坏。

部署
----
    install -d /opt/kaitai-health
    install -m 755 healthd.py /opt/kaitai-health/healthd.py
    systemctl enable --now kaitai-healthd
回退
----
    systemctl disable --now kaitai-healthd
    rm -f /var/www/iptv/health.json
"""
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

PLAYLIST = os.environ.get("KAITAI_PLAYLIST", "/var/www/iptv/playlists/kaitai-0x152k.m3u")
OUT = os.environ.get("KAITAI_HEALTH_OUT", "/var/www/iptv/health.json")

YSP_MARK = "/akira/relay/ysp-"     # 央视频 relay：机房 IP 探测必假阴性，交给客户端
OTHER_WORKERS = int(os.environ.get("KAITAI_OTHER_WORKERS", "4"))
RETRY_GAP = float(os.environ.get("KAITAI_RETRY_GAP", "0.4"))
TIMEOUT = float(os.environ.get("KAITAI_TIMEOUT", "8"))
# 一轮结束后到下一轮开始的最小间隔；0 = 连续巡检
INTERVAL = int(os.environ.get("KAITAI_INTERVAL", "0"))
UA = "kaitai-healthd/1.0 (+https://iptv.wusi321.top)"

LIMIT_MARK = "连续请求了".encode("utf-8")
log_lock = threading.Lock()


def is_ysp(url):
    return YSP_MARK in url


def log(msg):
    with log_lock:
        sys.stdout.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
        sys.stdout.flush()


def parse_playlist(path):
    """返回 [(name, url)]，按 URL 去重，保持清单顺序。"""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        log("读取清单失败：%s" % e)
        return []
    out, seen, name = [], set(), ""
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        if ln.startswith("#EXTINF"):
            name = ln.rsplit(",", 1)[-1].strip() if "," in ln else ""
            continue
        if ln.startswith("#"):
            continue
        if ln.startswith("http") and ln not in seen:
            seen.add(ln)
            out.append((name, ln))
        name = ""
    return out


def body_ok(body):
    if not body:
        return False
    if body.startswith(b"#EXTM3U"):
        return True
    if body.startswith(b"FLV"):
        return True
    if body[:1] == b"\x47":      # MPEG-TS sync byte
        return True
    return False


def probe(url):
    """返回 (state, ms)：state ∈ ok / bad / limited"""
    t0 = time.time()
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            body = r.read(4096)
            ms = int((time.time() - t0) * 1000)
            if LIMIT_MARK in body:
                return "limited", ms
            if r.status == 200 and body_ok(body):
                return "ok", ms
            return "bad", ms
    except urllib.error.HTTPError:
        return "bad", int((time.time() - t0) * 1000)
    except Exception:
        return "bad", -1


def sweep(items, results):
    """第一遍：并发探测，无防探测的源可以放开。"""
    done = [0]
    lock = threading.Lock()

    def work(item):
        name, url = item
        state, ms = probe(url)
        if state == "limited":
            time.sleep(6)
            state, ms = probe(url)
        with lock:
            results[url] = {"state": state, "ms": ms}
            done[0] += 1
            if done[0] % 100 == 0:
                log("第一遍 %d/%d" % (done[0], len(items)))
        return None

    with ThreadPoolExecutor(max_workers=OTHER_WORKERS) as ex:
        list(ex.map(work, items))


def retry_bad(items, results):
    """第二遍：只重测失败的，串行 + 0.4s 间隔。

    并发下 akira 偶尔会瞬时返回错误文本，重测能把这些误判滤掉；
    真死链重测也还是死，成本只是每条多一次请求。
    """
    bad = [(n, u) for n, u in items if (results.get(u) or {}).get("state") in ("bad", "limited")]
    if not bad:
        return 0
    log("第二遍重测 %d 条失败项" % len(bad))
    fixed = 0
    for i, (name, url) in enumerate(bad):
        state, ms = probe(url)
        if state == "ok":
            results[url] = {"state": "ok", "ms": ms}
            fixed += 1
        elif state == "bad":
            results[url] = {"state": "bad", "ms": ms}
        time.sleep(RETRY_GAP)
        if (i + 1) % 40 == 0:
            log("第二遍 %d/%d，已纠正 %d 条" % (i + 1, len(bad), fixed))
    return fixed


def write_out(payload):
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)


def main():
    log("启动 | 清单=%s 输出=%s 并发=%d 超时=%.0fs 重测间隔=%.1fs"
        % (PLAYLIST, OUT, OTHER_WORKERS, TIMEOUT, RETRY_GAP))
    prev = {}
    while True:
        t_cycle = time.time()
        all_items = parse_playlist(PLAYLIST)
        if not all_items:
            time.sleep(60)
            continue
        # 央视频(ysp-*) 从机房探必然 403，且会耗尽 akira 的官方请求预算 → 不进服务端巡检
        items = [it for it in all_items if not is_ysp(it[1])]
        skipped = len(all_items) - len(items)
        results = {}
        sweep(items, results)
        fixed = retry_bad(items, results)

        now = int(time.time())
        out = {}
        for name, url in items:
            r = results.get(url) or {"state": "unknown", "ms": -1}
            st = r["state"]
            if st == "unknown":
                old = prev.get(url)
                if old:
                    out[url] = old
                else:
                    out[url] = {"ok": 0, "ms": -1, "at": now, "unk": 1}
            else:
                out[url] = {"ok": 1 if st == "ok" else 0, "ms": r["ms"], "at": now}
        prev = out
        okc = sum(1 for v in out.values() if v["ok"] and not v.get("unk"))
        badc = sum(1 for v in out.values() if not v["ok"] and not v.get("unk"))
        try:
            write_out({
                "ts": now,
                "took": int(time.time() - t_cycle),
                "count": len(items),
                "ok": okc,
                "bad": badc,
                "retryFixed": fixed,
                "skipYsp": skipped,     # 央视频交给客户端探，不计入本文件
                "items": out,
            })
            log("完成 %d/%d 在线（重测纠正 %d，央视频 %d 条交给客户端），用时 %ds"
                % (okc, len(items), fixed, skipped, time.time() - t_cycle))
        except OSError as e:
            log("写入失败：%s" % e)
        gap = INTERVAL - (time.time() - t_cycle)
        if gap > 0:
            time.sleep(gap)


if __name__ == "__main__":
    main()
