#!/usr/bin/env python3
"""静态服务：所有响应带 no-cache 头，避免 Safari 缓存旧版页面（PWA 调试用）。"""
import http.server
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/web"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8090


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()


if __name__ == "__main__":
    os.chdir(ROOT)
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), NoCacheHandler).serve_forever()
