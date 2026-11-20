// libmpv 的 C 头文件桥接。
//
// 不写 `import Libmpv`，是因为 libmpv 的来源不止一种（MPVKit 的 xcframework、
// Homebrew 的 /opt/homebrew/include、自己编的 /usr/local/include），
// 每种的头文件位置和模块名都不一样。用桥接头 + -Xcc -I<头文件目录> 就统一了：
// 换库只要改一个 -I 路径，源码不用动。
#ifndef KAITAI_MPV_BRIDGE_H
#define KAITAI_MPV_BRIDGE_H

#include <mpv/client.h>
#include <mpv/render.h>

#endif
