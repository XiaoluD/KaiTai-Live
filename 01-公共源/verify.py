#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公共源校验器：逐条验证 m3u 里的频道是否真的能播。

判定逻辑（两段式，尽量省流量）：
  1) 拉 m3u8 清单（上限 256 KB），确认响应 200/206 且内容是 #EXTM3U
  2) 取清单里第一个分片地址（相对路径按清单 URL 解析），只取前 2 KB，
     确认返回 200/206 且不是 HTML 错误页

两段都过才算 OK。这样能排除「清单在、分片已死」和「返回 HTML 登录页/错误页」两类假活。

用法：
  python3 verify.py 输入.m3u              # 只打印报告
  python3 verify.py 输入.m3u --write 输出.m3u  # 同时写出只含活源的新 m3u
  可选：--workers 16  --timeout 10
"""
import argparse
import concurrent.futures as cf
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE  # 直播源证书普遍不靠谱，先不卡证书


def http_get(url, timeout, limit):
    """返回 (状态码, 内容类型, 前 limit 字节, 最终 URL)。失败抛异常。"""
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "*/*",
        "Range": "bytes=0-%d" % (limit - 1),
    })
    with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
        # 只读 limit 字节就断开，避免拖着整个分片下载
        body = r.read(limit)
        return r.status, r.headers.get("Content-Type", ""), body, r.geturl()


def resolve(base, ref):
    from urllib.parse import urljoin
    return urljoin(base, ref)


def check(url, timeout):
    """返回 (ok, reason, detail)。

    三种可播形态：
      A) HLS —— 正文含 #EXTM3U，再验第一个分片
      B) 直连渐进流 —— Content-Type 是 video/*|audio/*，验前 2 KB 不是网页
      C) 反盗链错误片 —— 重定向到 *error*/*pirated* 的 mp4，虽然是合法视频但内容是错的，判失败
    """
    # ---- 第一段：清单 / 流首包 ----
    try:
        code, ctype, body, final = http_get(url, timeout, 256 * 1024)
    except urllib.error.HTTPError as e:
        return False, "清单 HTTP %s" % e.code, ""
    except urllib.error.URLError as e:
        r = str(e.reason)
        if "timed out" in r or "Timeout" in r:
            return False, "超时", ""
        return False, "连不上(" + r[:60] + ")", ""
    except Exception as e:  # noqa: BLE001
        return False, "异常 " + type(e).__name__ + " " + str(e)[:50], ""

    if code >= 400:
        return False, "HTTP %s" % code, ""

    # 反盗链：源站跳去放「账号被盗用」提示片
    low_final = (final or "").lower()
    if "error" in low_final or "pirated" in low_final or "denied" in low_final:
        return False, "反盗链错误片(→%s)" % low_final.split("/")[-1], ""

    head = body[:4096]
    text = None
    for enc in ("utf-8", "gbk", "latin-1"):
        try:
            text = head.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    if text is None:
        text = head.decode("latin-1", "ignore")

    # --- B) 直连流 ---
    if "#EXTM3U" not in text:
        ct = (ctype or "").lower()
        if ct.startswith(("video/", "audio/")):
            if body[:512].lower().lstrip().startswith((b"<html", b"<!doctype")):
                return False, "直连流返回网页", ""
            return True, "OK", "直连 " + ct
        low = text.lower()
        if "<html" in low or "<!doctype" in low:
            return False, "返回 HTML", ""
        if "ftyp" in text[:64]:
            return True, "OK", "直连 mp4(无 ctype)"
        if not text.strip():
            return False, "空响应", ""
        return False, "非 m3u8(ctype=%s)" % (ctype or "?"), ""

    # --- A) HLS：验第一个分片 ---
    seg = None
    for line in text.splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            seg = s
            break
    if not seg:
        return False, "清单无分片", ""
    if not seg.lower().startswith(("http://", "https://")):
        seg = resolve(final, seg)

    try:
        code2, ctype2, body2, _ = http_get(seg, timeout, 2048)
    except urllib.error.HTTPError as e:
        return False, "分片 HTTP %s" % e.code, ""
    except Exception as e:  # noqa: BLE001
        return False, "分片失败 " + type(e).__name__, ""

    if code2 >= 400:
        return False, "分片 HTTP %s" % code2, ""

    if body2[:512].lower().lstrip().startswith((b"<html", b"<!doctype", b"{")):
        return False, "分片返回网页/JSON", ""

    return True, "OK", "HLS " + (ctype2 or "?")


def parse_m3u(path):
    """返回 [(原始行块, 名称, url)]，保持原始顺序与格式以便原样写回。"""
    with open(path, "rb") as f:
        raw = f.read().decode("utf-8", "replace")
    lines = raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    items = []
    i = 0
    while i < len(lines):
        if lines[i].startswith("#EXTINF"):
            block = [lines[i]]
            name = ""
            if 'tvg-name="' in lines[i]:
                name = lines[i].split('tvg-name="', 1)[1].split('"', 1)[0]
            if not name:
                name = lines[i].rsplit(",", 1)[-1].strip()
            j = i + 1
            extra = []
            while j < len(lines) and lines[j].startswith("#EXT") and not lines[j].startswith("#EXTINF"):
                extra.append(lines[j])
                j += 1
            if j < len(lines) and "://" in lines[j]:
                block.extend(extra)
                block.append(lines[j])
                items.append(("".join(x + "\n" for x in block), name, lines[j].strip()))
                i = j + 1
                continue
        i += 1
    return items


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--write", default="")
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--timeout", type=float, default=10)
    ap.add_argument("--app-safe", action="store_true",
                    help="按本 app（Safari/WKWebView 内核）的播放能力过滤：丢掉 FLV 等直连流、丢掉垃圾条目")
    args = ap.parse_args()

    items = parse_m3u(args.src)
    print("解析 %d 条，并发 %d，单条上限 %.0fs" % (len(items), args.workers, args.timeout))
    t0 = time.time()

    import re as _re
    JUNK = _re.compile(r"(支持作者|捐赠|打赏|广告|更新时间|^\d{4}-\d{2}-\d{2}|^\d{2}:\d{2}:\d{2})")

    results = []
    with cf.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(check, it[2], args.timeout): it for it in items}
        done = 0
        for fut in cf.as_completed(futs):
            it = futs[fut]
            try:
                ok, reason, detail = fut.result()
            except Exception as e:  # noqa: BLE001
                ok, reason, detail = False, "线程异常 " + type(e).__name__, ""
            # app-safe：Safari 内核播不了 FLV 等直连流，直接判死，别留着让人点
            if ok and args.app_safe and detail.startswith("直连") and "mp4" not in detail:
                ok, reason = False, "直连流浏览器不支持(" + detail + ")"
            if ok and args.app_safe and JUNK.search(it[1] or ""):
                ok, reason = False, "垃圾条目"
            results.append((it, ok, reason, detail))
            done += 1
            if done % 25 == 0 or done == len(items):
                sys.stderr.write("\r  进度 %d/%d" % (done, len(items)))
                sys.stderr.flush()

    sys.stderr.write("\n")
    el = time.time() - t0

    # 保持原顺序
    order = {id(it): n for n, it in enumerate(items)}
    results.sort(key=lambda x: order[id(x[0])])

    alive = [r for r in results if r[1]]
    print("\n耗时 %.1fs   可用 %d / %d = %.1f%%" % (el, len(alive), len(results), 100.0 * len(alive) / max(1, len(results))))

    from collections import Counter
    import re as _re
    reasons = Counter(_re.split(r"[(（ ]", r[2])[0] for r in results if not r[1])
    print("\n失败归因：")
    for k, v in reasons.most_common():
        print("  %-18s %d" % (k, v))

    kinds = Counter(r[3] for r in alive)
    if alive:
        print("\n可播形态：" + "，".join("%s %d 个" % (k, v) for k, v in kinds.most_common()))

    print("\n可用频道：" + "、".join(r[0][1] for r in alive) if alive else "\n无可用频道")

    if args.write:
        with open(args.write, "w", encoding="utf-8", newline="\n") as f:
            f.write("#EXTM3U\n")
            for it, ok, _r, _d in results:
                if ok:
                    f.write(it[0])
        print("\n已写出 %s（%d 条）" % (args.write, len(alive)))

    # 明细表落盘，便于复查
    detail_path = os.path.splitext(args.src)[0] + ".verify.tsv"
    with open(detail_path, "w", encoding="utf-8") as f:
        f.write("ok\tname\treason\tdetail\turl\n")
        for it, ok, reason, det in results:
            f.write("%s\t%s\t%s\t%s\t%s\n" % ("Y" if ok else "N", it[1], reason, det, it[2]))
    print("明细：%s" % detail_path)


if __name__ == "__main__":
    main()
