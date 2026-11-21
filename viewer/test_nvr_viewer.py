import base64
import json
import os
import secrets
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import nvr_viewer as v


def write(path, data, mode="wb"):
    with open(path, mode) as f:
        f.write(data)


def cfg_for(rec, **env):
    base = {"REC_DIR": rec, "CHANNELS": "1 2", "VIEWER_CACHE_DIR": os.path.join(rec, ".cache"), "VIEWER_STATIC": rec}
    base.update(env)
    return v.Config(base)


class Helpers(unittest.TestCase):
    def test_parse_start_is_utc(self):
        self.assertEqual(v.parse_segment_start("20261121-194336.mkv"), 1795290216)
        self.assertIsNone(v.parse_segment_start("junk.mkv"))
        self.assertIsNone(v.parse_segment_start("20261121-194336.mkv.part"))

    def test_range(self):
        self.assertIsNone(v.parse_range(None, 100))
        self.assertEqual(v.parse_range("bytes=0-9", 100), (0, 9))
        self.assertEqual(v.parse_range("bytes=90-", 100), (90, 99))
        self.assertEqual(v.parse_range("bytes=-10", 100), (90, 99))
        self.assertEqual(v.parse_range("bytes=0-999", 100), (0, 99))
        self.assertIs(v.parse_range("bytes=100-", 100), False)
        self.assertIs(v.parse_range("bytes=5-2", 100), False)
        self.assertIsNone(v.parse_range("garbage", 100))


class Listing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.rec = self.tmp.name
        os.makedirs(os.path.join(self.rec, "ch1"))
        os.makedirs(os.path.join(self.rec, "ch2"))

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, ch, name, data=b"x", age=0):
        p = os.path.join(self.rec, f"ch{ch}", name)
        write(p, data)
        t = time.time() - age
        os.utime(p, (t, t))

    def test_listing_sorted_and_live(self):
        from datetime import datetime, timedelta, timezone
        stamp = lambda mins: (datetime.now(timezone.utc) - timedelta(minutes=mins)).strftime("%Y%m%d-%H%M%S") + ".mkv"
        a, b, c = stamp(240), stamp(120), stamp(10)       # started 4 h, 2 h and 10 min ago
        self.put(1, b, age=1000)
        self.put(1, a, age=4000)
        self.put(1, "ignored.txt")
        self.put(1, c, age=1)
        segs = v.list_segments(cfg_for(self.rec))
        self.assertEqual([s["n"] for s in segs["1"]], [a, b, c])
        self.assertEqual([s["live"] for s in segs["1"]], [False, False, True])
        self.assertLessEqual(abs(segs["1"][2]["e"] - int(time.time())), 2)   # a live segment ends "now"
        self.assertLess(segs["1"][1]["e"], int(time.time()) - 900)           # a finished one ends at its last write
        self.assertEqual(segs["2"], [])

    def test_resolve_rejects_traversal_and_unknown_channel(self):
        self.put(1, "20261121-190000.mkv")
        cfg = cfg_for(self.rec)
        self.assertIsNotNone(v.resolve_source(cfg, "1", "20261121-190000.mkv"))
        self.assertIsNone(v.resolve_source(cfg, "3", "20261121-190000.mkv"))
        self.assertIsNone(v.resolve_source(cfg, "1", "../ch2/20261121-190000.mkv"))
        self.assertIsNone(v.resolve_source(cfg, "../x", "20261121-190000.mkv"))
        self.assertIsNone(v.resolve_source(cfg, "1", "20261121-190001.mkv"))


class Server(unittest.TestCase):
    def start(self, **env):
        self.tmp = tempfile.TemporaryDirectory()
        rec = self.tmp.name
        os.makedirs(os.path.join(rec, "ch1"))
        write(os.path.join(rec, "ch1", "20261121-190000.mkv"), b"0123456789")
        write(os.path.join(rec, "index.html"), "<html>ok</html>", "w")
        cfg = cfg_for(rec, **env)
        rm = v.Remuxer(cfg)
        rm.mp4_for = lambda ch, name, size=None: None  # no ffmpeg in unit tests
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), v.make_handler(cfg, rm))
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        self.tmp.cleanup()

    def get(self, path, headers=None):
        try:
            r = urllib.request.urlopen(urllib.request.Request(self.base + path, headers=headers or {}))
            return r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            return e.code, e.read(), e.headers

    def test_index_api_and_raw_range(self):
        self.start()
        self.assertEqual(self.get("/")[:2], (200, b"<html>ok</html>"))
        code, body, _ = self.get("/api/segments")
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["segments"]["1"][0]["n"], "20261121-190000.mkv")
        code, body, h = self.get("/raw/1/20261121-190000.mkv", {"Range": "bytes=2-4"})
        self.assertEqual((code, body, h["Content-Range"]), (206, b"234", "bytes 2-4/10"))
        self.assertEqual(self.get("/raw/9/20261121-190000.mkv")[0], 404)
        self.assertEqual(self.get("/media/1/20261121-190000.mkv")[0], 404)  # wrong extension for kind
        self.assertEqual(self.get("/media/1/20261121-190000.mp4")[0], 404)  # stub remux returns None
        self.assertEqual(self.get("/nope")[0], 404)

    def test_names_in_api(self):
        self.start(VIEWER_NAMES="Gate, ,Hall")
        d = json.loads(self.get("/api/segments")[1])
        self.assertEqual(d["names"], {"1": "Gate"})  # blank skipped; channel 2 has no name, extra names ignored

    def test_basic_auth(self):
        pw = secrets.token_urlsafe(16)  # generated per run, so no credential-looking literal lives in the repo
        self.start(VIEWER_PASSWORD=pw, VIEWER_USER="me")
        self.assertEqual(self.get("/")[0], 401)
        bad = "Basic " + base64.b64encode(f"me:{pw}x".encode()).decode()
        self.assertEqual(self.get("/", {"Authorization": bad})[0], 401)
        good = "Basic " + base64.b64encode(f"me:{pw}".encode()).decode()
        self.assertEqual(self.get("/", {"Authorization": good})[0], 200)


class Cache(unittest.TestCase):
    def test_pick_size_pins_snapshot(self):
        self.assertEqual(v.pick_size(None, 100), 100)
        self.assertEqual(v.pick_size(0, 100), 100)
        self.assertEqual(v.pick_size(60, 100), 60)    # file grew past what the page saw: pin to the page's snapshot
        self.assertEqual(v.pick_size(500, 100), 100)  # never beyond the file

    def test_prune_is_lru_and_keeps_the_requested_one(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = cfg_for(d, VIEWER_CACHE_MB="1")
            os.makedirs(cfg.cache_dir)
            rm = v.Remuxer(cfg)
            def mk(name, size, atime):
                p = os.path.join(cfg.cache_dir, name)
                write(p, b"\0" * size)
                os.utime(p, (atime, atime))
            now = time.time()
            mk("1-a-1.mp4", 700_000, now - 50)   # oldest
            mk("1-b-1.mp4", 700_000, now - 40)
            mk("1-c-1.mp4", 100, now)            # just requested
            rm._prune(keep="1-c-1.mp4")
            self.assertEqual(sorted(os.listdir(cfg.cache_dir)), ["1-b-1.mp4", "1-c-1.mp4"])


if __name__ == "__main__":
    unittest.main()
