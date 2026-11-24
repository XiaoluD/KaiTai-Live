#!/usr/bin/env bash
# 构建「开台」.app（原生，无 Electron）
#
# 用法:
#   ./mac-app/build.sh                  # 内嵌版（默认）：内置 libmpv 播放内核，全格式直播
#
# 单一版本策略：内嵌 libmpv 的 Full 版是唯一分发版本（精简版已移除）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VARIANT="${VARIANT:-embedded}"
ARCH="$(uname -m)"
APP_VERSION="${APP_VERSION:-}"
# 版本号默认取最近的 v* tag，保证本地构建与线上同一版本（自更新只比较大小，
# 版本对不上会导致检查更新误判、旧逻辑甚至会降级覆盖）。无 tag 时退回 1.0.0。
if [ -z "$APP_VERSION" ]; then
  APP_VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)"
  APP_VERSION="${APP_VERSION:-1.0.0}"
fi

case "$VARIANT" in
  lite)
    APP_NAME="开台直播"
    BUNDLE_ID="io.github.xiaolud.kaitai"
    ;;
  embedded)
    APP_NAME="开台直播"
    BUNDLE_ID="io.github.xiaolud.kaitai.embedded"
    ;;
  *)
    echo "未知 VARIANT=${VARIANT}（可选 lite / embedded）" >&2
    exit 2
    ;;
esac

# 名字三分离（v1.0.9「开台」→「开台直播」，加品类词，一眼看出是直播类）：
#   APP_NAME         bundle 目录名 / zip 内文件名 / 构建产物名
#   APP_DISPLAY_NAME Dock / 启动台 / Finder 显示名
#   APP_MENU_NAME    菜单栏程序名（CFBundleName，太长会挤占菜单栏）
APP_DISPLAY_NAME="开台直播"
APP_MENU_NAME="开台"

APP="$HERE/build/$APP_NAME.app"
CONTENTS="$APP/Contents"
BIN_NAME="KaiTai"

echo "== 构建 ${APP_NAME} v${APP_VERSION}（VARIANT=$VARIANT, $ARCH, macOS 13+）"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "== 编译 Swift"
SRC=("$HERE/main.swift" "$HERE/Updater.swift")
FLAGS=(-O -swift-version 5 -target "${ARCH}-apple-macosx13.0")
FLAGS+=(-framework AppKit -framework WebKit -framework Network)

if [ "$VARIANT" = "embedded" ]; then
  # libmpv 从哪来找：显式指定 > 本仓库自带的独立前缀 > Homebrew 默认位置
  if [ -n "${MPV_PREFIX:-}" ]; then
    PREFIX="$MPV_PREFIX"
  elif [ -f "$HOME/.kaitai/mpv/opt/mpv/include/mpv/client.h" ]; then
    PREFIX="$HOME/.kaitai/mpv/opt/mpv"
  else
    PREFIX="/opt/homebrew"
  fi

  if [ ! -f "$PREFIX/include/mpv/client.h" ]; then
    echo "   找不到 $PREFIX/include/mpv/client.h" >&2
    echo "   内嵌版需要一个可链接的 libmpv，先跑：" >&2
    echo "     python3 mac-app/setup-mpv-local.py" >&2
    exit 3
  fi
  echo "   libmpv: $PREFIX"
  FLAGS+=(-D EMBEDDED)
  FLAGS+=(-import-objc-header "$HERE/mpv-bridge.h")
  FLAGS+=(-Xcc -I"$PREFIX/include")
  FLAGS+=(-L"$PREFIX/lib" -lmpv)
  # 运行时按绝对路径找 libmpv 及其依赖，本机直跑即可；打包时再由 dylibbundler 收进 app
  FLAGS+=(-Xlinker -rpath -Xlinker "$PREFIX/lib")
  # mpv 的 pkgconfig 里列了这些系统框架
  for fw in Cocoa IOKit QuartzCore CoreMedia AVFoundation CoreFoundation \
            CoreAudio AudioUnit AudioToolbox OpenGL CoreVideo VideoToolbox; do
    FLAGS+=(-framework "$fw")
  done
  SRC+=("$HERE/MpvPlayer.swift")
fi

swiftc "${FLAGS[@]}" -o "$CONTENTS/MacOS/$BIN_NAME" "${SRC[@]}"

# 内嵌版：把 libmpv 及其整条动态库依赖链收进 app 包。
# 不打包的话，分发给别人会因为他们机器上没有 /opt/homebrew 而直接起不来。
if [ "$VARIANT" = "embedded" ]; then
  BUNDLER=""
  for cand in "$HOME/.kaitai/bin/dylibbundler" "$(command -v dylibbundler 2>/dev/null || true)"; do
    [ -n "$cand" ] && [ -x "$cand" ] && BUNDLER="$cand" && break
  done
  if [ -n "$BUNDLER" ]; then
    echo "== 收拢 libmpv 依赖（dylibbundler）"
    mkdir -p "$CONTENTS/Frameworks"
    "$BUNDLER" -of -cd -b \
      -x "$CONTENTS/MacOS/$BIN_NAME" \
      -d "$CONTENTS/Frameworks" \
      -p "@executable_path/../Frameworks" >/dev/null
    echo "   已收拢 $(ls -1 "$CONTENTS/Frameworks" | wc -l | tr -d ' ') 个动态库"

    # dylibbundler 有时会给同一个库塞两条一模一样的 LC_RPATH，
    # 新版 dyld 遇到重复 rpath 会直接拒绝加载（duplicate LC_RPATH），必须去重
    dedup=0
    for f in "$CONTENTS/Frameworks"/*.dylib; do
      dups=$(otool -l "$f" 2>/dev/null | grep -A2 LC_RPATH | grep "path " | awk '{print $2}' | sort | uniq -d || true)
      [ -z "$dups" ] && continue
      for r in $dups; do
        cnt=$(otool -l "$f" | grep -A2 LC_RPATH | grep -c -- "path $r " || true)
        while [ "$cnt" -gt 1 ]; do
          install_name_tool -delete_rpath "$r" "$f" 2>/dev/null || break
          cnt=$((cnt - 1))
        done
      done
      codesign --force --sign - "$f" >/dev/null 2>&1 || true
      dedup=$((dedup + 1))
    done
    if [ "$dedup" -gt 0 ]; then echo "   已清理 $dedup 个库的重复 rpath"; fi
    codesign --force --sign - "$CONTENTS/MacOS/$BIN_NAME" >/dev/null 2>&1 || true
  else
    echo "   ⚠️  没找到 dylibbundler，本机可以跑，但发给别人会缺库"
    echo "      见 README「内嵌版怎么构建」"
  fi
fi

echo "== 复制前端资源"
cp -R "$ROOT/web" "$CONTENTS/Resources/web"
rm -rf "$CONTENTS/Resources/web/.DS_Store"

echo "== 复制图标"
# 图标带 LIVE 徽章（v1.0.9 起；旧版是区分变体的 Full 徽章）
ICON_SRC="$HERE/icon/icon.icns"
if [ "$VARIANT" = "embedded" ] && [ -f "$HERE/icon/icon-live.icns" ]; then
  ICON_SRC="$HERE/icon/icon-live.icns"
fi
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$CONTENTS/Resources/icon.icns"
else
  echo "   跳过（没找到 $ICON_SRC）"
fi

# 内嵌版链的是 GPL 构建的 libmpv + ffmpeg，分发时必须带上许可证原文
if [ "$VARIANT" = "embedded" ]; then
  cp "$ROOT/LICENSE-GPL-2.0.txt" "$CONTENTS/Resources/" 2>/dev/null || true
  cat > "$CONTENTS/Resources/THIRD-PARTY.txt" <<'NOTICE'
本程序（内嵌版）通过 libmpv 链接了以下第三方组件：

  mpv        https://mpv.io                      GPL-2.0-or-later / LGPL-2.1-or-later
  FFmpeg     https://ffmpeg.org                  GPL-2.0-or-later（Homebrew 构建启用了 GPL 部分）
  libass     https://github.com/libass/libass    ISC
  libplacebo https://github.com/haasn/libplacebo LGPL-2.1-or-later
  MoltenVK   https://github.com/KhronosGroup/MoltenVK  Apache-2.0
  LuaJIT     https://luajit.org                  MIT
  其他依赖见 /opt/homebrew/Cellar/mpv 下的各 formula

因此本程序整体按 GNU General Public License v2.0 或更新版本分发，
许可证原文见同目录 LICENSE-GPL-2.0.txt，源码见项目仓库。

精简版不含上述任何组件，不适用 GPL。
NOTICE
  echo "   已写入 GPL 许可证与第三方声明"
fi

echo "== 写入 Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$APP_MENU_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_DISPLAY_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$BIN_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleIconFile</key>
	<string>icon</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$APP_VERSION</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>GitHubRepo</key>
	<string>XiaoluD/KaiTai-Live</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
		<key>NSAllowsArbitraryLoadsInWebContent</key>
		<true/>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST

echo "== Ad-hoc 签名"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (签名跳过，不影响本机运行)"
xattr -cr "$APP" 2>/dev/null || true

echo "== 完成"
du -sh "$APP"
echo "   双击运行: $APP"
