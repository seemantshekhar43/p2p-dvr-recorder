#!/usr/bin/env python3
"""nvr-viewer: browse and play the segments written by nvr-record.

Single file, standard library only. Browsers cannot play MKV, so a segment is
remuxed to MP4 on first request (`ffmpeg -c copy`, about a tenth of a second per
segment) into a size-capped cache and then served with Range support.

Environment (shared with the other nvr-* tools, see deploy/nvr-recorder.env.example):
  REC_DIR           recordings root                          (default /mnt/recordings)
  CHANNELS          channels to show                         (default "1 2 3 4 5 6")
  VIEWER_NAMES      camera names, comma separated, in CHANNELS order, e.g. "Gate,Hall,Garden" (default: CH1, CH2, ...)
  VIEWER_BIND       listen address                           (default 127.0.0.1)
  VIEWER_PORT       listen port                              (default 8080)
  VIEWER_USER       basic-auth user                          (default viewer)
  VIEWER_PASSWORD   basic-auth password; unset = no auth
  VIEWER_CACHE_MB   remux cache size cap                     (default 2048)
  VIEWER_CACHE_DIR  remux cache location                     (default $CACHE_DIRECTORY or /var/cache/nvr-viewer)
  VIEWER_STATIC     directory holding index.html             (default: next to this file)
"""
import base64
import hmac
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SEGMENT_RE = re.compile(r"^(\d{8})-(\d{6})\.mkv$")
CHANNEL_RE = re.compile(r"^\d{1,3}$")
LIVE_WINDOW_S = 90  # a segment written to within this many seconds is "live"


def env(name, default):
    v = os.environ.get(name)
    return v if v not in (None, "") else default


class Config:
    def __init__(self, environ=None):
        e = environ if environ is not None else os.environ
        g = lambda k, d: e.get(k) if e.get(k) not in (None, "") else d
        self.rec_dir = g("REC_DIR", "/mnt/recordings")
        self.channels = g("CHANNELS", "1 2 3 4 5 6").split()
        names = [n.strip() for n in g("VIEWER_NAMES", "").split(",")]
        self.names = {ch: n for ch, n in zip(self.channels, names) if n}
        self.bind = g("VIEWER_BIND", "127.0.0.1")
        self.port = int(g("VIEWER_PORT", "8080"))
        self.user = g("VIEWER_USER", "viewer")
        self.password = g("VIEWER_PASSWORD", None)
        self.cache_mb = int(g("VIEWER_CACHE_MB", "2048"))
        self.cache_dir = g("VIEWER_CACHE_DIR", g("CACHE_DIRECTORY", "/var/cache/nvr-viewer"))
        self.static_dir = g("VIEWER_STATIC", os.path.dirname(os.path.abspath(__file__)))


def parse_segment_start(name):
    """Start time (epoch seconds, UTC) from a segment file name, or None."""
    m = SEGMENT_RE.match(name)
    if not m:
        return None
    dt = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def list_segments(cfg, now=None):
    """{channel: [{n, s, e, b, live}]} oldest first. s/e are epoch seconds."""
    now = time.time() if now is None else now
    out = {}
    for ch in cfg.channels:
        rows = []
        d = os.path.join(cfg.rec_dir, "ch" + ch)
        try:
            names = os.listdir(d)
        except FileNotFoundError:
            names = []
        for name in names:
            start = parse_segment_start(name)
            if start is None:
                continue
            try:
                st = os.stat(os.path.join(d, name))
            except FileNotFoundError:
                continue
            end = max(int(st.st_mtime), start)
            rows.append({"n": name, "s": start, "e": end, "b": st.st_size, "live": now - st.st_mtime < LIVE_WINDOW_S})
        rows.sort(key=lambda r: r["s"])
        out[ch] = rows
    return out


def resolve_source(cfg, ch, name):
    """Absolute path of a segment, or None. Only exact, validated names ever reach the filesystem."""
    if ch not in cfg.channels or not CHANNEL_RE.match(ch) or not SEGMENT_RE.match(name):
        return None
    p = os.path.join(cfg.rec_dir, "ch" + ch, name)
    return p if os.path.isfile(p) else None


class Remuxer:
    """MKV -> MP4 (stream copy) with a size-capped on-disk cache."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.key_locks = {}
        os.makedirs(cfg.cache_dir, exist_ok=True)

    def mp4_for(self, ch, name):
        src = resolve_source(self.cfg, ch, name)
        if src is None:
            return None
        st = os.stat(src)
        key = f"{ch}-{name[:-4]}-{st.st_size}-{st.st_mtime_ns}.mp4"
        dst = os.path.join(self.cfg.cache_dir, key)
        with self.lock:
            klock = self.key_locks.setdefault(key, threading.Lock())
        with klock:
            if not os.path.isfile(dst):
                self._remux(src, dst)
                self._prune(keep=key, prefix=f"{ch}-{name[:-4]}-")
            else:
                os.utime(dst)  # LRU touch
        return dst

    def _remux(self, src, dst):
        fd, tmp = tempfile.mkstemp(dir=self.cfg.cache_dir, suffix=".part")
        os.close(fd)
        try:
            # hvc1 tag: Safari/Chrome only accept HEVC-in-MP4 tagged hvc1. A growing file may end mid-cluster; that is fine.
            r = subprocess.run(
                ["ffmpeg", "-nostdin", "-v", "error", "-i", src, "-c", "copy", "-an", "-tag:v", "hvc1",
                 "-movflags", "+faststart", "-f", "mp4", "-y", tmp],
                capture_output=True, text=True, timeout=300)
            if r.returncode != 0 or os.path.getsize(tmp) == 0:
                raise RuntimeError("ffmpeg failed: " + r.stderr.strip()[-300:])
            os.replace(tmp, dst)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def _prune(self, keep, prefix):
        d = self.cfg.cache_dir
        entries = []
        for f in os.listdir(d):
            p = os.path.join(d, f)
            if f.endswith(".part") or not f.endswith(".mp4"):
                continue
            if f.startswith(prefix) and f != keep:  # stale version of the same segment
                os.unlink(p)
                continue
            st = os.stat(p)
            entries.append((st.st_atime, st.st_size, p))
        total = sum(e[1] for e in entries)
        limit = self.cfg.cache_mb * 1024 * 1024
        for _, size, p in sorted(entries):
            if total <= limit:
                break
            if os.path.basename(p) == keep:
                continue
            os.unlink(p)
            total -= size


def parse_range(header, size):
    """(start, end) inclusive for a single 'bytes=a-b' range, None if absent, False if unsatisfiable."""
    if not header:
        return None
    m = re.match(r"^bytes=(\d*)-(\d*)$", header.strip())
    if not m or (m.group(1) == "" and m.group(2) == ""):
        return None
    if m.group(1) == "":
        n = int(m.group(2))
        if n == 0:
            return False
        return (max(size - n, 0), size - 1)
    start = int(m.group(1))
    end = int(m.group(2)) if m.group(2) else size - 1
    if start >= size or start > end:
        return False
    return (start, min(end, size - 1))


def make_handler(cfg, remuxer):
    expected = None
    if cfg.password:
        expected = base64.b64encode(f"{cfg.user}:{cfg.password}".encode()).decode()

    class Handler(BaseHTTPRequestHandler):
        server_version = "nvr-viewer"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

        def _authorized(self):
            if expected is None:
                return True
            h = self.headers.get("Authorization", "")
            if h.startswith("Basic ") and hmac.compare_digest(h[6:].strip(), expected):
                return True
            self.send_response(HTTPStatus.UNAUTHORIZED)
            self.send_header("WWW-Authenticate", 'Basic realm="nvr-viewer", charset="UTF-8"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False

        def _send_bytes(self, code, body, ctype, head=False, extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if not head:
                self.wfile.write(body)

        def _send_file(self, path, ctype, head=False, download_name=None):
            size = os.path.getsize(path)
            rng = parse_range(self.headers.get("Range"), size)
            if rng is False:
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            start, end = rng if rng else (0, size - 1)
            self.send_response(HTTPStatus.PARTIAL_CONTENT if rng else HTTPStatus.OK)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Cache-Control", "private, max-age=60")
            if rng:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            if download_name:
                self.send_header("Content-Disposition", f'attachment; filename="{download_name}"')
            self.end_headers()
            if head:
                return
            with open(path, "rb") as f:
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = f.read(min(1 << 20, left))
                    if not chunk:
                        break
                    try:
                        self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        return
                    left -= len(chunk)

        def _route(self, head):
            if not self._authorized():
                return
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html"):
                try:
                    with open(os.path.join(cfg.static_dir, "index.html"), "rb") as f:
                        body = f.read()
                except FileNotFoundError:
                    return self._send_bytes(HTTPStatus.INTERNAL_SERVER_ERROR, b"index.html missing", "text/plain", head)
                return self._send_bytes(HTTPStatus.OK, body, "text/html; charset=utf-8", head)
            if path == "/api/segments":
                body = json.dumps({"now": int(time.time()), "channels": cfg.channels, "names": cfg.names,
                                   "segments": list_segments(cfg)}).encode()
                return self._send_bytes(HTTPStatus.OK, body, "application/json", head)
            m = re.match(r"^/(media|raw)/(\d{1,3})/(\d{8}-\d{6})\.(mp4|mkv)$", path)
            if m:
                kind, ch, stem, ext = m.groups()
                if (kind == "media") != (ext == "mp4"):
                    return self._send_bytes(HTTPStatus.NOT_FOUND, b"not found", "text/plain", head)
                name = stem + ".mkv"
                if kind == "raw":
                    src = resolve_source(cfg, ch, name)
                    if src is None:
                        return self._send_bytes(HTTPStatus.NOT_FOUND, b"not found", "text/plain", head)
                    return self._send_file(src, "video/x-matroska", head, download_name=f"ch{ch}-{name}")
                try:
                    mp4 = remuxer.mp4_for(ch, name)
                except Exception as e:  # remux failure: report, keep serving
                    self.log_message("remux failed: %s", e)
                    return self._send_bytes(HTTPStatus.BAD_GATEWAY, b"remux failed", "text/plain", head)
                if mp4 is None:
                    return self._send_bytes(HTTPStatus.NOT_FOUND, b"not found", "text/plain", head)
                return self._send_file(mp4, "video/mp4", head)
            return self._send_bytes(HTTPStatus.NOT_FOUND, b"not found", "text/plain", head)

        def do_GET(self):
            self._route(head=False)

        def do_HEAD(self):
            self._route(head=True)

    return Handler


def main():
    cfg = Config()
    remuxer = Remuxer(cfg)
    srv = ThreadingHTTPServer((cfg.bind, cfg.port), make_handler(cfg, remuxer))
    srv.daemon_threads = True
    auth = "basic auth on" if cfg.password else "NO AUTH"
    print(f"nvr-viewer on http://{cfg.bind}:{cfg.port} ({auth}), recordings {cfg.rec_dir}, channels {' '.join(cfg.channels)}",
          file=sys.stderr, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
