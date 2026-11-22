#!/usr/bin/env python3
"""A stand-in stream add-on for checking the app by hand, on this machine only.

It offers the same streams for every film and episode it is asked about, so a real title's
page (its metadata comes from the catalog add-on) gets something to play or download that
was generated here.

    Scripts/serve-test-addon.py 8123 --url http://127.0.0.1:8765/sdr-h264-1080p.mp4
    Scripts/serve-test-addon.py 8123 --torrent <40 hex> --name "4K HDR 600 MB"

Install it into a scratch profile:  -profile <folder> -installNow http://127.0.0.1:8123/manifest.json
"""

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MANIFEST = {
    "id": "local.test.streams",
    "version": "1.0.0",
    "name": "Test Streams",
    "description": "Generated media served from this machine, for checks.",
    "resources": ["stream"],
    "types": ["movie", "series"],
    "idPrefixes": ["tt", "kitsu"],
    "catalogs": [],
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("port", type=int)
    parser.add_argument("--url", action="append", default=[], help="a direct stream (repeatable)")
    parser.add_argument("--torrent", action="append", default=[], help="a torrent's info hash (repeatable)")
    parser.add_argument("--name", default="1080p", help="what the streams are called")
    parser.add_argument("--description", default="Generated sample\n👤 12 💾 40 MB", help="the text under the name")
    arguments = parser.parse_args()

    streams = [{"url": url, "name": arguments.name, "description": arguments.description} for url in arguments.url]
    streams += [{"infoHash": infohash, "name": arguments.name, "description": arguments.description} for infohash in arguments.torrent]

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 (the base class names it)
            if self.path == "/manifest.json":
                body = MANIFEST
            elif self.path.startswith("/stream/"):
                body = {"streams": streams}
            else:
                self.send_error(404)
                return
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_: object) -> None:
            pass

    ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
