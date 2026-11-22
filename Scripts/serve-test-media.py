#!/usr/bin/env python3
"""Serves TestMedia/ over HTTP on 127.0.0.1 with Range support, for checking network playback.

Usage: Scripts/serve-test-media.py [port] [--throttle-kbps N]

  Scripts/serve-test-media.py 8765 &
  open -g Nebula.app --args -silent YES -play http://127.0.0.1:8765/sdr-h264-1080p.mp4

--throttle-kbps limits the transfer rate, to see how the player behaves on a slow connection.
Python's own http.server cannot be used for this: it ignores Range, so seeking would not work.
"""
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "TestMedia")
TYPES = {".mp4": "video/mp4", ".mkv": "video/x-matroska", ".srt": "application/x-subrip"}
CHUNK = 64 * 1024

args = [a for a in sys.argv[1:]]
throttle = 0
if "--throttle-kbps" in args:
    index = args.index("--throttle-kbps")
    throttle = int(args[index + 1]) * 1000 // 8
    del args[index:index + 2]
port = int(args[0]) if args else 8765


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_HEAD(self):
        self.respond(send_body=False)

    def do_GET(self):
        self.respond(send_body=True)

    def respond(self, send_body):
        name = os.path.basename(self.path.split("?", 1)[0])
        path = os.path.join(ROOT, name)
        if not name or not os.path.isfile(path):
            self.send_error(404)
            return
        size = os.path.getsize(path)
        start, end, status = 0, size - 1, 200
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range", "").strip())
        if match and (match.group(1) or match.group(2)):
            if match.group(1):
                start = int(match.group(1))
                end = min(int(match.group(2)), size - 1) if match.group(2) else size - 1
            else:
                start = max(size - int(match.group(2)), 0)
            if start >= size or start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", TYPES.get(os.path.splitext(name)[1], "application/octet-stream"))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if not send_body:
            return
        try:
            with open(path, "rb") as file:
                file.seek(start)
                remaining = length
                while remaining > 0:
                    data = file.read(min(CHUNK, remaining))
                    if not data:
                        break
                    self.wfile.write(data)
                    remaining -= len(data)
                    if throttle:
                        time.sleep(len(data) / throttle)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the player closed the connection (seek or quit); nothing to do

    def log_message(self, format, *arguments):
        sys.stderr.write("%s %s\n" % (self.command, format % arguments))


server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
print(f"serving {os.path.normpath(ROOT)} on http://127.0.0.1:{port}/" + (f" at {throttle * 8 // 1000} kbit/s" if throttle else ""))
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
