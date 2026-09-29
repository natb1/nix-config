"""Tests for media-fetch. Run by the package's checkPhase (`nix build .#media-fetch`,
`nix flake check`).

A fake slskd (the endpoints media-fetch calls, with the shapes slskd 0.26
returns) runs in a thread; "downloading" a file writes it where slskd would.
A fake itch.io (its site's search page, the API, and a file host behind a
redirect) runs beside it. The CLI is driven the way an agent drives it:
search, show, get, wait."""

import hashlib
import html
import io
import json
import os
import tempfile
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

import media_fetch as mf

KEY = "test-key"


class FakeSlskd:
    def __init__(self, downloads):
        self.downloads = Path(downloads)
        self.responses = []      # search responses
        self.transfers = {}      # user -> [transfer]
        self.offline = set()
        self.fail = set()        # remote filenames that fail when downloaded
        self.busy = set()        # remote filenames refused: "try again later"
        self.hold = False        # leave transfers queued
        self.lag = 0             # status polls before responses are saved
        self.searches = {}
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj=None):
                body = json.dumps(obj).encode() if obj is not None else b""
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _route(self, method):
                if self.headers.get("X-API-Key") != KEY:
                    return self._send(401)
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n)) if n else None
                path = urlparse(self.path).path.removeprefix("/api/v0")
                parts = [unquote(p) for p in path.strip("/").split("/")]
                return self._send(*fake.handle(method, parts, body))

            def do_GET(self):
                self._route("GET")

            def do_POST(self):
                self._route("POST")

            def do_PUT(self):
                self._route("PUT")

            def do_DELETE(self):
                self._route("DELETE")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def handle(self, method, parts, body):
        if parts[0] == "searches":
            if method == "POST":
                self.searches[body["id"]] = body["searchText"]
                return 200, {"id": body["id"], "isComplete": False}
            if method == "PUT":
                return 200, None
            if len(parts) == 3:
                return 200, [] if self.lag else self.responses
            if self.lag:
                self.lag -= 1
                return 200, {"id": parts[1], "isComplete": False, "responseCount": len(self.responses)}
            return 200, {"id": parts[1], "isComplete": True, "responseCount": len(self.responses)}
        if parts[:3] == ["transfers", "downloads", "batches"]:
            user = body["username"]
            if user in self.offline:
                return 404, "user offline"
            for i, f in enumerate(body["files"]):
                t = {"id": f"{body['id']}-{i}", "filename": f["filename"], "size": f["size"],
                     "state": "Queued, Remotely", "bytesTransferred": 0,
                     "requestedAt": f"2026-09-26T00:00:{len(self.transfers.get(user, [])):02d}",
                     "_dest": body["options"]["destination"]}
                self.transfers.setdefault(user, []).append(t)
            return 201, {"id": body["id"], "failures": []}
        if parts[:2] == ["transfers", "downloads"] and len(parts) == 3:
            ts = self.transfers.get(parts[2])
            if not ts:
                return 404, None
            self._advance(ts)
            return 200, {"username": parts[2], "directories": [
                {"directory": "x", "files": [{k: v for k, v in t.items() if k != "_dest"} for t in ts]}]}
        if parts[:2] == ["transfers", "downloads"] and method == "DELETE":
            self.transfers[parts[2]] = [t for t in self.transfers[parts[2]] if t["id"] != parts[3]]
            return 204, None
        return 404, None

    def _advance(self, ts):
        if self.hold:
            return
        for t in ts:
            if t["state"] != "Queued, Remotely":
                continue
            if t["filename"] in self.busy:
                t["state"] = "Completed, Rejected"
                t["exception"] = "Transfer rejected: Overwhelmed with requests; try again later."
                continue
            if t["filename"] in self.fail:
                self.fail.discard(t["filename"])  # a retry succeeds
                t["state"] = "Completed, TimedOut"
                continue
            p = self.downloads / t["_dest"] / t["filename"].rpartition("\\")[2]
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b"x" * t["size"])
            t["state"], t["bytesTransferred"] = "Completed, Succeeded", t["size"]


def response(user, folder, names, free=True, queue=0, speed=1_000_000, ext="flac"):
    return {"username": user, "hasFreeUploadSlot": free, "queueLength": queue, "uploadSpeed": speed,
            "fileCount": len(names), "lockedFileCount": 1,
            "files": [{"filename": f"{folder}\\{n}.{ext}", "size": 10 + i, "length": 200,
                       "bitDepth": 16, "sampleRate": 44100} for i, n in enumerate(names)],
            "lockedFiles": [{"filename": f"{folder}\\secret.flac", "size": 5}]}


ITCH_KEY = "itch-key"


class FakeItch:
    """itch.io: the site's search page, the API (/api/...), and the file
    host its download links redirect to (/cdn/...), which must never see
    the API key."""

    def __init__(self):
        self.games = {}     # id -> {title, url, author, price, key, uploads: [{id, filename, data}], listed}
        self.hits = []      # paths asked for
        self.leaks = []     # file host requests that carried the key
        self.corrupt = set()  # upload ids whose bytes come back wrong
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                u = urlparse(self.path)
                fake.hits.append(u.path)
                code, ctype, body, extra = fake.handle(u.path, parse_qs(u.query), self.headers)
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                for k, v in extra.items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def game(self, gid, title, price=None, key=None, uploads=(), listed=True, author="Kylmaenen"):
        self.games[gid] = {"title": title, "url": f"https://{author.lower()}.itch.io/g{gid}",
                           "author": author, "price": price, "key": key, "listed": listed,
                           "uploads": [{"id": gid * 10 + i, "filename": n, "data": d}
                                       for i, (n, d) in enumerate(uploads)]}

    def _can(self, g, q):
        return g["price"] is None or (g["key"] is not None and q.get("download_key_id") == [str(g["key"])])

    def handle(self, path, q, headers):
        js = lambda obj, code=200: (code, "application/json", json.dumps(obj).encode(), {})
        parts = path.strip("/").split("/")
        if parts == ["search"]:
            words = q["q"][0].lower().split()
            cells = "".join(
                f'<div class="game_cell" data-game_id="{gid}"><a class="thumb_link game_link" href="{g["url"]}">'
                f'</a><div class="game_title"><a data-label="game:{gid}:title" href="{g["url"]}" '
                f'class="title game_link">{html.escape(g["title"])}</a>'
                + (f'<div class="price_value">{g["price"]}</div>' if g["price"] else "")
                + f'</div><div class="game_author"><a href="x">{g["author"]}</a></div></div>'
                for gid, g in self.games.items()
                if g["listed"] and all(w in g["title"].lower() for w in words))
            return 200, "text/html", f"<html><body>{cells}</body></html>".encode(), {}
        if parts[0] == "cdn":
            if headers.get("Authorization"):
                self.leaks.append(path)
                return js({"error": "two auth mechanisms"}, 400)
            uid = int(parts[1])
            for g in self.games.values():
                for up in g["uploads"]:
                    if up["id"] == uid:  # corrupt: the right size, the wrong bytes
                        data = b"?" * len(up["data"]) if uid in self.corrupt else up["data"]
                        return 200, "application/octet-stream", data, {}
            return js({}, 404)
        if parts[0] != "api":
            return js({}, 404)
        if headers.get("Authorization") != f"Bearer {ITCH_KEY}":
            return js({"errors": ["invalid key"]}, 401)
        parts = parts[1:]
        if parts == ["profile", "owned-keys"]:
            keys = [{"id": g["key"], "game_id": gid,
                     "game": {"id": gid, "title": g["title"], "url": g["url"],
                              "user": {"display_name": g["author"]}}}
                    for gid, g in self.games.items() if g["key"] is not None]
            return js({"owned_keys": keys if q["page"] == ["1"] else [], "per_page": 50, "page": 1})
        if parts[0] == "games" and parts[2] == "uploads":
            g = self.games[int(parts[1])]
            if not self._can(g, q):
                return js({"uploads": {}})
            return js({"uploads": [{"id": up["id"], "filename": up["filename"], "size": len(up["data"]),
                                    "storage": "hosted", "md5_hash": hashlib.md5(up["data"]).hexdigest()}
                                   for up in g["uploads"]]})
        if parts[0] == "uploads" and parts[2] == "download":
            uid = int(parts[1])
            g = next(g for g in self.games.values() if any(up["id"] == uid for up in g["uploads"]))
            if not self._can(g, q):
                return js({"errors": ["invalid download key"]}, 400)
            return 302, "text/html", b"", {"Location": f"/cdn/{uid}?sig=x"}
        return js({}, 404)


class MediaFetchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.staging = root / "staging"
        self.downloads = self.staging / "corpus"
        self.fake = FakeSlskd(self.downloads)
        self.itch = FakeItch()
        self.library = root / "media"
        self.env = {"MEDIA_STAGING": str(self.staging), "MEDIA_FETCH_STATE": str(root / "state"),
                    "MEDIA_LIBRARY": str(self.library),
                    "CORPUS_URL": self.fake.url, "CORPUS_API_KEY": KEY,
                    "CORPUS_DOWNLOADS": str(self.downloads),
                    "ITCH_API_URL": self.itch.url + "/api", "ITCH_WEB_URL": self.itch.url,
                    "ITCH_API_KEY": ITCH_KEY}
        self.saved = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)

    def tearDown(self):
        for f in (self.fake, self.itch):
            f.server.shutdown()
            f.server.server_close()
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def cli(self, *args):
        out = io.StringIO()
        code = 0
        with redirect_stdout(out), redirect_stderr(out):
            try:
                mf.main(list(args))
            except SystemExit as e:
                code = e.code if isinstance(e.code, int) else 1
                if isinstance(e.code, str):
                    out.write(e.code)
        return code, out.getvalue()

    def search(self, *extra, kind="music"):
        """The corpus fetch table."""
        return self.tables(*extra, kind=kind)["corpus fetch"]

    def tables(self, *extra, kind="music", query="artist album"):
        code, out = self.cli("search", query, "--kind", kind, "--json", *extra)
        self.assertEqual(code, 0, out)
        r = json.loads(out)
        return {t["name"]: t for t in r["tables"]}

    def test_search_ranks_and_hides_the_network(self):
        self.fake.responses = [
            response("slow", "Music\\Artist\\Album", ["01", "02"], free=False, queue=5),
            response("mp3", "Music\\Artist\\Album", ["01", "02"], ext="mp3"),
            response("best", "D:\\Artist - Album (2001)\\CD1", ["01", "02"]),
        ]
        r = self.search()
        titles = [c["title"] for c in r["candidates"]]
        self.assertEqual(titles, ["Artist - Album (2001) - CD1", "Album", "Album"])
        self.assertTrue(r["candidates"][0]["lossless"])
        self.assertFalse(r["candidates"][1]["lossless"])
        self.assertFalse(r["candidates"][2]["ready"])
        # Locked files are not offered, and nothing names the peer or the path.
        text = json.dumps(r)
        for word in ("slow", "best", "Music\\\\", "secret", "source", "user"):
            self.assertNotIn(word, text)
        self.assertEqual(r["candidates"][0]["files"][0],
                         {"name": "01.flac", "size": 10, "duration": 200, "bitdepth": 16, "samplerate": 44100})

    def test_search_stopped_at_timeout_waits_for_its_responses(self):
        # Still running at --timeout: stopped, then saved a moment later.
        self.fake.responses = [response("a", "X\\Album", ["01"])]
        self.fake.lag = 3
        r = self.search("--timeout", "0")
        self.assertEqual([c["title"] for c in r["candidates"]], ["Album"])

    def test_ext_filter_and_min_files(self):
        self.fake.responses = [response("a", "X\\Books", ["b1"], ext="epub"),
                               response("b", "X\\Album", ["01", "02"])]
        r = self.search("--ext", "epub")
        self.assertEqual([c["title"] for c in r["candidates"]], ["Books"])
        r = self.search("--min-files", "2")
        self.assertEqual([c["title"] for c in r["candidates"]], ["Album"])

    def test_get_wait_delivers_into_the_batch(self):
        self.fake.responses = [response("peer", "Music\\Artist\\Album (2001)", ["01 One", "02 Two", "03 Three"])]
        cid = self.search()["candidates"][0]["id"]
        code, out = self.cli("show", cid)
        self.assertIn("02 Two.flac", out)
        code, out = self.cli("get", cid, "--batch", "slsk-test", "--files", "1,3")
        self.assertEqual(code, 0, out)
        code, out = self.cli("wait", "slsk-test", "--timeout", "5", "--interval", "0", "--json")
        self.assertEqual(code, 0, out)
        [s] = json.loads(out)
        self.assertEqual(s["state"], "delivered")
        self.assertEqual((s["bytes"], s["size"]), (22, 22))  # all of it, though the backend forgot it
        self.assertRegex(self.cli("status", cid)[1], r"delivered +100%")
        album = self.staging / "slsk-test" / "Album (2001)"
        self.assertEqual(sorted(p.name for p in album.iterdir()), ["01 One.flac", "03 Three.flac"])
        self.assertFalse((self.downloads / cid).exists())
        self.assertEqual(self.fake.transfers["peer"], [])  # forgotten by the backend too

    def test_failed_file_is_retried_by_get(self):
        self.fake.responses = [response("peer", "M\\Album", ["01", "02"])]
        cid = self.search()["candidates"][0]["id"]
        self.fake.fail.add("M\\Album\\02.flac")
        self.cli("get", cid, "--batch", "b")
        code, out = self.cli("wait", cid, "--timeout", "5", "--interval", "0")
        self.assertEqual(code, 1)
        self.assertIn("failed: 02.flac (timed out)", out)
        code, out = self.cli("status", cid, "--json")
        self.assertEqual(json.loads(out)[0]["failures"], {"02.flac": "timed out"})
        self.assertFalse((self.staging / "b").exists())
        code, out = self.cli("get", cid)
        self.assertIn("retrying 1", out)
        code, out = self.cli("wait", cid, "--timeout", "5", "--interval", "0")
        self.assertEqual(code, 0, out)
        self.assertTrue((self.staging / "b" / "Album" / "02.flac").is_file())

    def test_one_file_at_a_time_per_source(self):
        self.fake.responses = [response("peer", "M\\A", ["01", "02"]),
                               response("peer", "M\\B", ["01"]),
                               response("other", "N\\C", ["01"])]
        ids = [c["id"] for c in self.search()["candidates"]]
        self.fake.hold = True
        for cid in ids:
            code, out = self.cli("get", cid, "--batch", "b")
            self.assertEqual(code, 0, out)
        asked = lambda user: [t["filename"] for t in self.fake.transfers.get(user, [])]
        self.assertEqual(asked("peer"), ["M\\A\\01.flac"])  # the rest wait here
        self.assertEqual(asked("other"), ["N\\C\\01.flac"])  # a source of its own
        code, out = self.cli("status", "--json")
        self.assertEqual({s["title"]: s["state"] for s in json.loads(out)},
                         {"A": "queued", "B": "queued", "C": "queued"})
        self.assertEqual(len(asked("peer")), 1)
        self.fake.hold = False
        code, out = self.cli("wait", "b", "--timeout", "5", "--interval", "0")
        self.assertEqual(code, 0, out)
        moves, _, final = out.partition("--\n")
        self.assertEqual(sum("delivered" in l for l in moves.splitlines()), 3)  # as each arrived
        self.assertEqual(sum("delivered" in l for l in final.splitlines()), 3)
        self.assertEqual(asked("peer"), [])  # all delivered, then forgotten
        self.assertEqual(sorted(p.name for p in (self.staging / "b").iterdir()), ["A", "B", "C"])

    def test_pump_alone_finishes_a_job_and_status_changes_nothing(self):
        # What desk's service does between an agent's commands.
        self.fake.responses = [response("peer", "M\\A", ["01", "02"])]
        cid = self.search()["candidates"][0]["id"]
        self.fake.hold = True
        self.cli("get", cid, "--batch", "b")
        self.fake.hold = False
        self.cli("status")  # 01 arrives, but status asks for nothing more
        self.assertEqual(len(self.fake.transfers["peer"]), 1)
        code, out = self.cli("pump")  # asks for 02
        self.assertEqual((code, out), (0, ""))
        self.assertEqual(len(self.fake.transfers["peer"]), 2)
        code, out = self.cli("pump")  # 02 arrives: delivered
        self.assertIn(f"{cid}: delivered to", out)
        self.assertEqual(sorted(p.name for p in (self.staging / "b" / "A").iterdir()), ["01.flac", "02.flac"])
        code, out = self.cli("wait", "b", "--timeout", "0", "--json")
        self.assertEqual((code, json.loads(out)[0]["state"]), (0, "delivered"))

    def test_estimates_count_the_jobs_ahead_at_the_source(self):
        # Offered at 1 B/s; the files are 10 and 11 bytes, then 10.
        self.fake.responses = [response("peer", "M\\A", ["01", "02"], speed=1),
                               response("peer", "M\\B", ["01"], speed=1)]
        ids = [c["id"] for c in self.search()["candidates"]]
        self.fake.hold = True
        code, out = self.cli("get", ids[0], "--batch", "b", "--json")
        self.assertEqual(json.loads(out)["eta"], 21)
        self.cli("get", ids[1], "--batch", "b")
        eta = lambda: {s["title"]: s.get("eta") for s in json.loads(self.cli("status", "--json")[1])}
        self.assertEqual(eta(), {"A": 21, "B": 31})
        # Measured speed wins once a file is under way: 7 B/s, 3 bytes in.
        [t] = self.fake.transfers["peer"]
        t.update(state="InProgress", averageSpeed=7, bytesTransferred=3)
        self.assertEqual(eta()["A"], 3)  # (7 + 11) / 7
        self.assertIn("(under a minute left)", self.cli("status")[1])

    def test_per_source_limit_is_configurable(self):
        self.fake.responses = [response("peer", "M\\A", ["01", "02", "03"])]
        cid = self.search()["candidates"][0]["id"]
        self.fake.hold = True
        os.environ["MEDIA_FETCH_PER_SOURCE"] = "2"
        self.addCleanup(os.environ.pop, "MEDIA_FETCH_PER_SOURCE", None)
        self.cli("get", cid, "--batch", "b")
        self.assertEqual(len(self.fake.transfers["peer"]), 2)
        os.environ["MEDIA_FETCH_PER_SOURCE"] = "0"
        self.assertIn("MEDIA_FETCH_PER_SOURCE", self.cli("wait", "--timeout", "0")[1])

    def test_refusal_while_waiting_fails_the_rest(self):
        self.fake.responses = [response("peer", "M\\A", ["01", "02"])]
        cid = self.search()["candidates"][0]["id"]
        self.cli("get", cid, "--batch", "b")
        self.fake.offline.add("peer")
        code, out = self.cli("wait", cid, "--timeout", "5", "--interval", "0")
        self.assertEqual(code, 1)
        self.assertIn("failed: 02.flac (the source is offline", out)
        self.fake.offline.discard("peer")
        self.assertIn("retrying 1", self.cli("get", cid)[1])
        code, out = self.cli("wait", cid, "--timeout", "5", "--interval", "0")
        self.assertEqual(code, 0, out)

    def test_busy_source_is_asked_for_nothing_more(self):
        self.fake.responses = [response("peer", "M\\A", ["01", "02", "03"])]
        cid = self.search()["candidates"][0]["id"]
        self.fake.busy.add("M\\A\\01.flac")
        self.cli("get", cid, "--batch", "b")
        code, out = self.cli("wait", cid, "--timeout", "5", "--interval", "0", "--json")
        self.assertEqual(code, 1)
        [s] = json.loads(out)
        self.assertEqual(s["state"], "failed")
        busy = "Transfer rejected: Overwhelmed with requests; try again later."
        self.assertEqual(s["failures"], {"01.flac": busy,
                                         "02.flac": f"not asked, the source is busy: {busy}",
                                         "03.flac": f"not asked, the source is busy: {busy}"})
        self.assertEqual(len(self.fake.transfers["peer"]), 1)  # one request, one refusal
        # Later, a retry asks again, from the first file.
        self.fake.busy.clear()
        self.assertIn("retrying 3", self.cli("get", cid)[1])
        code, out = self.cli("wait", cid, "--timeout", "5", "--interval", "0")
        self.assertEqual(code, 0, out)

    def test_file_the_source_never_queued_says_so(self):
        self.fake.responses = [response("peer", "M\\Album", ["01"])]
        cid = self.search()["candidates"][0]["id"]
        self.cli("get", cid, "--batch", "b")
        self.fake.transfers["peer"] = []
        code, out = self.cli("status", cid)
        self.assertIn("failed: 01.flac (never started: the source has no record of it)", out)

    def test_failure_shows_the_sources_message(self):
        self.fake.responses = [response("peer", "M\\Album", ["01"])]
        cid = self.search()["candidates"][0]["id"]
        self.cli("get", cid, "--batch", "b")
        [t] = self.fake.transfers["peer"]
        t["state"], t["exception"] = "Completed, Rejected", "Transfer rejected: Overwhelmed with requests"
        code, out = self.cli("status", cid)
        self.assertIn("failed: 01.flac (Transfer rejected: Overwhelmed with requests)", out)

    def test_status_and_cancel(self):
        self.fake.responses = [response("peer", "M\\Album", ["01"])]
        cid = self.search()["candidates"][0]["id"]
        self.fake.hold = True
        self.cli("get", cid, "--batch", "b")
        code, out = self.cli("status", "--json")
        self.assertEqual(json.loads(out)[0]["state"], "queued")
        code, out = self.cli("wait", "--timeout", "0")
        self.assertEqual(code, 1)
        code, out = self.cli("cancel", "b")
        self.assertIn("cancelled", out)
        self.assertEqual(self.fake.transfers["peer"], [])
        self.assertEqual(self.cli("status")[1].strip(), "no downloads")

    def test_refusals(self):
        self.fake.responses = [response("peer", "M\\Album", ["01"])]
        cid = self.search()["candidates"][0]["id"]
        self.assertIn("--batch is required", self.cli("get", cid)[1])
        self.assertIn("a download directory", self.cli("get", cid, "--batch", "corpus")[1])
        self.assertIn("one plain directory", self.cli("get", cid, "--batch", "a/b")[1])
        self.staging.mkdir(parents=True, exist_ok=True)
        (self.staging / "old.manifest.jsonl").touch()
        self.assertIn("already scanned", self.cli("get", cid, "--batch", "old")[1])
        self.assertIn("outside 1-1", self.cli("get", cid, "--batch", "b", "--files", "2")[1])
        self.assertIn("no candidate", self.cli("show", "ffffff.1")[1])
        self.fake.offline.add("peer")
        self.assertIn("source is offline", self.cli("get", cid, "--batch", "b")[1])
        self.assertEqual(self.cli("status")[1].strip(), "no downloads")  # nothing asked for: forgotten

    def test_job_that_cannot_be_delivered_fails_alone(self):
        # Two sources' folders of one name, into one batch: the second can't
        # be moved in. It fails by itself; other jobs go on.
        self.fake.responses = [response("u1", "X\\Album", ["01", "02"]),
                               response("u2", "Y\\Album", ["01", "02"]),
                               response("u3", "Z\\Other", ["01"])]
        ids = [c["id"] for c in self.search()["candidates"]]
        for cid in ids[:2]:
            self.cli("get", cid, "--batch", "b")
        code, out = self.cli("wait", "b", "--timeout", "5", "--interval", "0", "--json")
        self.assertEqual(code, 1, out)
        by = {s["state"]: s for s in json.loads(out)}
        self.assertEqual(sorted(by), ["delivered", "failed"])
        stuck = by["failed"]
        self.assertIn(f"{self.staging}/b/Album/01.flac already exists", stuck["undeliverable"])
        self.assertIn("not delivered:", self.cli("status", stuck["id"])[1])
        self.assertEqual(self.cli("pump"), (0, ""))  # not tried again every round
        code, out = self.cli("get", ids[2], "--batch", "c")
        self.assertEqual(code, 0, out)
        code, out = self.cli("wait", "c", "--timeout", "5", "--interval", "0")
        self.assertEqual(code, 0, out)
        self.assertTrue((self.staging / "c" / "Other" / "01.flac").is_file())
        # Once the folder in the way is gone, get moves it in.
        (self.staging / "b" / "Album").rename(self.staging / "b" / "Album (the other)")
        code, out = self.cli("get", stuck["id"])
        self.assertEqual(code, 0, out)
        self.assertIn("delivered to", out)
        self.assertEqual(sorted(p.name for p in (self.staging / "b" / "Album").iterdir()), ["01.flac", "02.flac"])

    def test_long_title_is_cut_to_fit_a_file_name(self):
        # 90 characters, 270 bytes: more than a file name may hold.
        self.fake.responses = [response("peer", "M\\" + "完" * 90, ["01"])]
        cid = self.search()["candidates"][0]["id"]
        self.cli("get", cid, "--batch", "b")
        code, out = self.cli("wait", "b", "--timeout", "5", "--interval", "0")
        self.assertEqual(code, 0, out)
        self.assertTrue((self.staging / "b" / ("完" * 80) / "01.flac").is_file())

    def test_locate_falls_back_to_name_and_size(self):
        # An slskd that ignored the destination option: the remote folder's name.
        be = mf.Slskd()
        job = {"id": "abc.1", "files": [], "source": {}}
        p = self.downloads / "Album" / "01_639012345.flac"
        p.parent.mkdir(parents=True)
        p.write_bytes(b"x" * 10)
        self.assertEqual(be.locate(job, {"name": "01.flac", "size": 10}), p)
        self.assertIsNone(be.locate(job, {"name": "01.flac", "size": 11}))


    # ---- itch.io, for rpg --------------------------------------------------

    def unravel(self):
        self.fake.responses = [response("peer", "RPG\\Unravel", ["Unravel"], ext="pdf")]
        self.itch.game(1, "Unravel: Second Edition", uploads=[("Unravel 2e_ENG.pdf", b"u" * 30),
                                                              ("Dreamwalker sheets.pdf", b"d" * 7)])
        self.itch.game(2, "Unravel Deluxe", price="$9", key=77, listed=False,
                       uploads=[("Unravel Deluxe.pdf", b"x" * 12)])
        self.itch.game(3, "Unravel Zine", price="$3", uploads=[("zine.pdf", b"z")])
        self.itch.game(4, "Unravel Online", uploads=[])  # a web game: nothing to fetch

    def test_rpg_search_lists_itch_beside_corpus(self):
        self.unravel()
        t = self.tables(kind="rpg", query="unravel")
        self.assertEqual(list(t), ["corpus fetch", "media share", "itch.io"])
        self.assertEqual([c["id"].partition(".")[2] for c in t["corpus fetch"]["candidates"]], ["1"])
        itch = {c["title"]: c for c in t["itch.io"]["candidates"]}
        self.assertEqual(sorted(itch), ["Unravel Deluxe", "Unravel Zine", "Unravel: Second Edition"])
        free, mine, zine = itch["Unravel: Second Edition"], itch["Unravel Deluxe"], itch["Unravel Zine"]
        self.assertEqual((free["price"], free["ready"], len(free["files"]), free["size"]), ("free", True, 2, 37))
        self.assertEqual((mine["price"], mine["ready"]), ("owned", True))  # from the library, not the site
        self.assertEqual((zine["price"], zine["ready"], zine["files"], zine["buy"]), ("$3", False, [], True))
        self.assertEqual(free["from"], "itch.io")
        self.assertEqual(t["corpus fetch"]["candidates"][0]["from"], "corpus fetch")
        self.assertEqual([c["id"].partition(".")[2] for c in t["itch.io"]["candidates"]], ["2", "3", "4"])
        code, out = self.cli("search", "unravel", "--kind", "rpg")
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r"^corpus fetch\n")
        self.assertIn("\nmedia share\n  nothing found", out)
        self.assertIn("\nitch.io\n", out)
        self.assertRegex(out, r"\$3 +  \? files.*Unravel Zine \(Kylmaenen\)")

    def test_nothing_printed_names_the_corpus_network(self):
        self.unravel()
        outs = [self.cli("--help")[1], self.cli("search", "--help")[1],
                self.cli("search", "unravel", "--kind", "rpg")[1],
                self.cli("search", "unravel", "--kind", "rpg", "--json")[1]]
        cid = json.loads(outs[-1])["tables"][0]["candidates"][0]["id"]
        outs += [self.cli("show", cid)[1], self.cli("show", cid, "--json")[1],
                 self.cli("get", cid, "--batch", "b", "--json")[1],
                 self.cli("wait", "b", "--timeout", "5", "--interval", "0", "--json")[1],
                 self.cli("status")[1]]
        for out in outs:
            for word in ("slsk", "soulseek", "peer"):
                self.assertNotIn(word, out.lower())

    def test_other_kinds_do_not_search_itch(self):
        self.unravel()
        for kind in ("music", "book", "tv", "other"):
            self.assertEqual(list(self.tables(kind=kind, query="unravel")), ["corpus fetch", "media share"])
        self.assertEqual(self.itch.hits, [])
        self.assertIn("--kind", self.cli("search", "unravel")[1])  # required

    def wait(self, *sel):
        return self.cli("wait", *sel, "--timeout", "10", "--interval", "0.05")

    def test_itch_get_wait_delivers_without_leaking_the_key(self):
        self.unravel()
        itch = {c["title"]: c for c in self.tables(kind="rpg", query="unravel")["itch.io"]["candidates"]}
        cid = itch["Unravel: Second Edition"]["id"]
        code, out = self.cli("get", cid, "--batch", "rpg-b")
        self.assertEqual(code, 0, out)
        code, out = self.wait("rpg-b")
        self.assertEqual(code, 0, out)
        d = self.staging / "rpg-b" / "Unravel_ Second Edition"
        self.assertEqual(sorted(p.name for p in d.iterdir()), ["Dreamwalker sheets.pdf", "Unravel 2e_ENG.pdf"])
        self.assertEqual((d / "Unravel 2e_ENG.pdf").read_bytes(), b"u" * 30)
        self.assertEqual(self.itch.leaks, [])
        self.assertFalse((self.staging / ".itch" / cid).exists())

    def test_itch_owned_game_uses_its_download_key(self):
        self.unravel()
        itch = {c["title"]: c for c in self.tables(kind="rpg", query="unravel")["itch.io"]["candidates"]}
        self.cli("get", itch["Unravel Deluxe"]["id"], "--batch", "b")
        code, out = self.wait()
        self.assertEqual(code, 0, out)
        self.assertTrue((self.staging / "b" / "Unravel Deluxe" / "Unravel Deluxe.pdf").is_file())

    def test_itch_game_not_owned_is_refused(self):
        self.unravel()
        itch = {c["title"]: c for c in self.tables(kind="rpg", query="unravel")["itch.io"]["candidates"]}
        code, out = self.cli("get", itch["Unravel Zine"]["id"], "--batch", "b")
        self.assertEqual(code, 1)
        self.assertIn("is $3 on itch.io and not owned: buy it at https://kylmaenen.itch.io/g3", out)
        self.assertEqual(self.cli("status")[1].strip(), "no downloads")

    def test_itch_checksum_mismatch_fails_then_retries(self):
        self.unravel()
        itch = {c["title"]: c for c in self.tables(kind="rpg", query="unravel")["itch.io"]["candidates"]}
        cid = itch["Unravel: Second Edition"]["id"]
        self.itch.corrupt.add(11)  # Dreamwalker sheets.pdf
        self.cli("get", cid, "--batch", "b")
        code, out = self.wait(cid)
        self.assertEqual(code, 1, out)
        self.assertIn("failed: Dreamwalker sheets.pdf (the file's checksum does not match itch.io's)", out)
        self.itch.corrupt.clear()
        self.assertIn("retrying 1", self.cli("get", cid)[1])
        code, out = self.wait(cid)
        self.assertEqual(code, 0, out)

    def test_itch_down_still_lists_the_corpus(self):
        self.unravel()
        os.environ["ITCH_WEB_URL"] = os.environ["ITCH_API_URL"] = "http://127.0.0.1:9"
        t = self.tables(kind="rpg", query="unravel")
        self.assertEqual(len(t["corpus fetch"]["candidates"]), 1)
        self.assertIn("cannot reach itch.io", t["itch.io"]["error"])
        self.assertIn("  not searched: cannot reach itch.io", self.cli("search", "unravel", "--kind", "rpg")[1])

    def test_old_jobs_are_the_corpus(self):
        # A job saved before candidates carried a backend.
        self.fake.responses = [response("peer", "M\\Album", ["01"])]
        cid = self.search()["candidates"][0]["id"]
        self.fake.hold = True
        self.cli("get", cid, "--batch", "b")
        p = Path(self.env["MEDIA_FETCH_STATE"]) / "jobs" / f"{cid}.json"
        job = json.loads(p.read_text())
        del job["backend"]
        p.write_text(json.dumps(job))
        self.fake.hold = False
        code, out = self.cli("wait", "b", "--timeout", "5", "--interval", "0")
        self.assertEqual(code, 0, out)

    # ---- the media share ---------------------------------------------------

    def put(self, path, size=3):
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x" * size)

    def test_media_share_lists_what_is_filed_and_staged(self):
        lib, st = self.library, self.staging
        self.put(lib / "music/Julian Bream/Guitarra (1985)/01 Fantasia.mp3")
        self.put(lib / "music/Julian Bream/Guitarra (1985)/02 Pavan.mp3")
        self.put(lib / "music/Julian Bream/Baroque Guitar (1966)/01 Prelude.flac")
        self.put(lib / "music/Other/Bream Lake (2001)/01 Bream.mp3")
        self.put(lib / "music/Other/Unrelated (2001)/01 x.mp3")
        self.put(lib / "rpg/Julian Bream Quest/Core (A4).pdf")  # another kind's folder
        self.put(st / "bream-2026-09-27/Julian Bream - Live/01.flac")
        self.put(st / "corpus/job/Julian Bream 01.flac")  # a download, not a batch
        self.put(st / "trash/Julian Bream/01.flac")
        self.put(st / "README.md")
        self.fake.responses = [response("peer", "M\\Julian Bream\\Guitarra", ["01"])]
        t = self.tables(kind="music", query="julian bream", *["--ext", "flac"])
        share = {c["title"]: c for c in t["media share"]["candidates"]}
        self.assertEqual(sorted(share), [str(st / "bream-2026-09-27"),
                                         "music/Julian Bream/Baroque Guitar (1966)",
                                         "music/Julian Bream/Guitarra (1985)"])
        g = share["music/Julian Bream/Guitarra (1985)"]
        self.assertEqual((g["where"], g["formats"], len(g["files"])), ("filed", "2 mp3", 2))  # --ext aside
        self.assertEqual(share[str(st / "bream-2026-09-27")]["where"], "staged")
        self.assertEqual(g["path"], str(lib / "music/Julian Bream/Guitarra (1985)"))
        # One word matching the file, the other its folder: still a match.
        t = self.tables(kind="rpg", query="bream core")
        self.assertEqual([c["title"] for c in t["media share"]["candidates"]], ["rpg/Julian Bream Quest"])
        code, out = self.cli("search", "julian bream", "--kind", "music")
        self.assertRegex(out, r"filed +2 files +6 B  2 mp3 +music/Julian Bream/Guitarra \(1985\)")
        code, out = self.cli("get", g["id"], "--batch", "b")
        self.assertEqual(code, 1)
        self.assertIn("is already on the media share (filed)", out)
        self.assertIn("filed, " + g["path"], self.cli("show", g["id"])[1])

    def test_kind_picks_the_corpus_file_types(self):
        self.fake.responses = [response("a", "Ado\\unravel", ["01 unravel"], ext="flac"),
                               response("b", "RPG\\Unravel", ["Unravel"], ext="pdf")]
        self.assertEqual([c["title"] for c in self.search(kind="rpg")["candidates"]], ["Unravel"])
        self.assertEqual([c["title"] for c in self.search(kind="music")["candidates"]], ["unravel"])
        self.assertEqual(len(self.search("--ext", "all", kind="rpg")["candidates"]), 2)
        self.assertEqual(len(self.search(kind="other")["candidates"]), 2)

if __name__ == "__main__":
    unittest.main()
