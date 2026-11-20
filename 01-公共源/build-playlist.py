#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
按「WKWebView 实测结果」重建播放列表 —— 只保留真的能在本 app 里播出来的频道。

输入：
  原始 m3u（保留 EXTINF 元数据，含台标、分组）
  probe-batch 产出的 TSV（ok / name / res / err / url）

处理：
  1) 只留 ok=Y
  2) 剔除垃圾条目：更新时间伪频道、捐赠/推广台、明显不是频道的名字
  3) 同名重复保留（app 会显示 ·1/·2），但完全相同的 URL 去重
  4) 原样保留 EXTINF 行，保证台标和分组不丢

用法：
  python3 build-playlist.py 原始.m3u 实测.tsv 输出.m3u
"""
import csv
import re
import sys

# 垃圾条目：名字命中即丢
JUNK_NAME = re.compile(
    r"(支持作者|捐赠|打赏|广告|更新时间|^\d{4}-\d{2}-\d{2}|^\d{2}:\d{2}:\d{2})"
)


def parse_blocks(path):
    """返回 {url: 完整行块}，按出现顺序。"""
    raw = open(path, "rb").read().decode("utf-8", "replace")
    lines = raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    out = []
    i = 0
    while i < len(lines):
        if lines[i].startswith("#EXTINF"):
            block = [lines[i]]
            name = ""
            m = re.search(r'tvg-name="([^"]*)"', lines[i])
            if m:
                name = m.group(1)
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
                out.append((name, lines[j].strip(), "\n".join(block) + "\n"))
                i = j + 1
                continue
        i += 1
    return out


def main():
    src, tsv, dst = sys.argv[1], sys.argv[2], sys.argv[3]

    blocks = parse_blocks(src)
    verdict = {}
    with open(tsv) as f:
        r = csv.reader(f, delimiter="\t")
        next(r, None)
        for row in r:
            if len(row) >= 5:
                verdict[row[4]] = (row[0] == "Y", row[2])

    kept, dropped_junk, dropped_dead, seen = [], [], [], set()
    for name, url, block in blocks:
        if JUNK_NAME.search(name or ""):
            dropped_junk.append(name)
            continue
        ok, _res = verdict.get(url, (False, ""))
        if not ok:
            dropped_dead.append(name)
            continue
        if url in seen:
            continue
        seen.add(url)
        kept.append((name, block))

    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        f.write("#EXTM3U\n")
        for _n, b in kept:
            f.write(b)

    print("原始 %d 条 → 保留 %d 条" % (len(blocks), len(kept)))
    print("  剔除垃圾条目 %d：%s" % (len(dropped_junk), "、".join(dropped_junk[:8]) or "无"))
    print("  剔除不可播 %d 条" % len(dropped_dead))
    print("已写出 %s" % dst)


if __name__ == "__main__":
    main()
