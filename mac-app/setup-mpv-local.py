#!/usr/bin/env python3
"""
把 libmpv 和它整条动态库依赖链装到一个独立前缀里，不碰系统的 Homebrew。

背景：本机 brew install 跑不了。Homebrew 解包 bottle 时要 exec 一层自己的
sandbox-exec，这一步在当前环境被系统拒掉（sandbox_apply: Operation not permitted），
外层再怎么放开也没用。而 bottle 里又都是 /opt/homebrew 的路径，直接手工解到
/opt/homebrew 会顶掉用户已装的 ffmpeg 之类。

所以：解到独立前缀，再把 Mach-O 里的 Homebrew 占位符重写成真实路径。

踩过的两个坑写在这里，免得再犯：
  1. bottle 里有**两种**占位符：@@HOMEBREW_PREFIX@@（/opt/homebrew）和
     @@HOMEBREW_CELLAR@@（/opt/homebrew/Cellar）。只替换前者会漏掉
     libavcodec → libavutil 这类 re-export 链，表现为运行时报
     "Symbol not found: _av_default_item_name"。
  2. ffmpeg 不能复用系统里已装的旧版本。mpv 会比对 libavcodec 的编译期/运行期
     版本，差一个补丁号就直接退出。所以缓存里有 bottle 的一律用解出来的那份。

用法:
    python3 mac-app/setup-mpv-local.py                  # 装/补齐
    python3 mac-app/setup-mpv-local.py --clean          # 删掉整个前缀
    KAITAI_MPV_PREFIX=/path python3 ...                 # 换前缀位置

默认前缀 ~/.kaitai/mpv。整条链（含 ffmpeg 全家桶）约 330 MB。
"""

import os
import re
import shutil
import subprocess
import sys

PREFIX = os.environ.get("KAITAI_MPV_PREFIX") or os.path.expanduser("~/.kaitai/mpv")
SYSTEM_BREW = "/opt/homebrew"
CACHE_DIR = os.path.expanduser("~/Library/Caches/Homebrew/downloads")

# 占位符 -> 在真实前缀里的相对位置
PLACEHOLDERS = {
    "@@HOMEBREW_PREFIX@@": "",
    "@@HOMEBREW_CELLAR@@": "/Cellar",
    "@@HOMEBREW_REPOSITORY@@": "/Homebrew",
}


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def is_macho(path):
    return "Mach-O" in run(["file", "-b", path]).stdout


def otool_deps(path):
    out = []
    for line in run(["otool", "-L", path]).stdout.splitlines()[1:]:
        line = line.strip()
        if line:
            out.append(line.split(" (")[0])
    return out


def otool_id(path):
    lines = [x.strip() for x in run(["otool", "-D", path]).stdout.splitlines() if x.strip()]
    return lines[1].split(" (")[0] if len(lines) >= 2 else None


def bottle_for(name):
    if not os.path.isdir(CACHE_DIR):
        return None
    best = None
    for f in os.listdir(CACHE_DIR):
        if f"--{name}--" in f and ".bottle" in f and f.endswith(".tar.gz"):
            best = os.path.join(CACHE_DIR, f)
    return best


def extract_formula(name):
    cells = os.path.join(PREFIX, "Cellar", name)
    if os.path.isdir(cells):
        vers = [d for d in os.listdir(cells) if os.path.isdir(os.path.join(cells, d))]
        if vers:
            return os.path.join(cells, vers[0])

    tb = bottle_for(name)
    if not tb:
        raise RuntimeError(
            f"缓存里没有 {name} 的 bottle。先只下载不解包：\n"
            f"    brew fetch --force --bottle-tag=arm64_tahoe {name}"
        )
    os.makedirs(os.path.join(PREFIX, "Cellar"), exist_ok=True)
    r = run(["tar", "xzf", tb, "-C", os.path.join(PREFIX, "Cellar")])
    if r.returncode != 0:
        raise RuntimeError(f"解压 {name} 失败: {r.stderr}")
    vers = [d for d in os.listdir(cells) if os.path.isdir(os.path.join(cells, d))]
    if not vers:
        raise RuntimeError(f"{name} 解压后找不到版本目录")
    return os.path.join(cells, vers[0])


def link_opt(name, keg):
    optdir = os.path.join(PREFIX, "opt")
    os.makedirs(optdir, exist_ok=True)
    dst = os.path.join(optdir, name)
    if os.path.islink(dst) or os.path.exists(dst):
        os.remove(dst)
    os.symlink(os.path.relpath(keg, optdir), dst)


def rel_of(dep):
    """把任意写法的依赖还原成「相对真实前缀的路径」；不是自家路径返回 None"""
    for ph, suffix in PLACEHOLDERS.items():
        if ph in dep:
            return suffix + dep.split(ph, 1)[1]
    if dep.startswith(PREFIX):
        return dep[len(PREFIX):]
    if dep.startswith(SYSTEM_BREW):
        return dep[len(SYSTEM_BREW):]
    return None


def owner_of(rel):
    parts = rel.strip("/").split("/")
    if len(parts) > 1 and parts[0] in ("opt", "Cellar"):
        return parts[1]
    return None


def resolve(dep):
    """统一成实际存在的绝对路径；系统库（/usr/lib、/System）返回 None 表示别动"""
    rel = rel_of(dep)
    if rel is None or not rel.startswith("/"):
        return None
    if rel.startswith("/usr/") or rel.startswith("/System/"):
        return None

    owner = owner_of(rel)
    # brew 只为「要装或要升级」的 formula 下 bottle；缓存里有就说明系统那份版本不对，必须用自己的
    if owner and bottle_for(owner):
        return PREFIX + rel
    if os.path.exists(SYSTEM_BREW + rel):
        return SYSTEM_BREW + rel
    return PREFIX + rel


def rewrite(path):
    changed = False

    mid = otool_id(path)
    if mid:
        want = resolve(mid)
        if want and want != mid:
            run(["install_name_tool", "-id", want, path])
            changed = True

    for dep in otool_deps(path):
        want = resolve(dep)
        if want and want != dep:
            run(["install_name_tool", "-change", dep, want, path])
            changed = True

    if changed:
        # arm64 上没签名的 dylib 加载不了，改完必须重新 ad-hoc 签名
        run(["codesign", "--force", "--sign", "-", path])


def missing_deps(path):
    out = []
    for dep in otool_deps(path):
        want = resolve(dep)
        if want is None:
            if rel_of(dep) is not None:
                out.append(dep)          # 占位符没认出来
            continue
        if not os.path.exists(want):
            out.append(want)
    return out


def dylibs_under(root):
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(dirpath, f)
            if os.path.islink(p) or not (".dylib" in f or ".so" in f):
                continue
            try:
                if is_macho(p):
                    out.append(p)
            except Exception:
                pass
    return out


def main():
    if "--clean" in sys.argv:
        shutil.rmtree(PREFIX, ignore_errors=True)
        print(f"已删除 {PREFIX}")
        return

    print(f"== 目标前缀 {PREFIX}")
    keg = extract_formula("mpv")
    print(f"   mpv -> {keg}")
    link_opt("mpv", keg)

    for round_no in range(1, 12):
        missing = set()
        for p in dylibs_under(PREFIX):
            missing.update(missing_deps(p))
        if not missing:
            break

        need = set()
        for dep in missing:
            rel = rel_of(dep)
            owner = owner_of(rel) if rel else None
            if not owner:
                raise RuntimeError(f"不认识的依赖路径: {dep}")
            need.add(owner)
        need.discard("mpv")
        if not need:
            break

        for name in sorted(need):
            k = extract_formula(name)
            link_opt(name, k)
            print(f"   第{round_no}轮 补 {name} -> {os.path.basename(k)}")
        for p in dylibs_under(PREFIX):
            rewrite(p)

    for p in dylibs_under(PREFIX):
        rewrite(p)

    left = set()
    for p in dylibs_under(PREFIX):
        left.update(missing_deps(p))
    if left:
        print("⚠️ 还有未解析依赖：")
        for d in sorted(left):
            print("   ", d)
        sys.exit(1)

    lib = os.path.join(PREFIX, "opt", "mpv", "lib", "libmpv.2.dylib")
    hdr = os.path.join(PREFIX, "opt", "mpv", "include", "mpv", "client.h")
    print("== 完成")
    print("   libmpv :", lib, "存在" if os.path.exists(lib) else "缺失")
    print("   headers:", hdr, "存在" if os.path.exists(hdr) else "缺失")
    size = run(["du", "-sh", PREFIX]).stdout.split()
    print("   体积   :", size[0] if size else "?")


if __name__ == "__main__":
    main()
