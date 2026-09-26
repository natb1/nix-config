"""Tests for media-fetch. Run by the package's checkPhase (`nix build .#media-fetch`,
`nix flake check`).

A fake slskd (the endpoints media-fetch calls, with the shapes slskd 0.26
returns) runs in a thread; "downloading" a file writes it where slskd would.
The CLI is driven the way an agent drives it: search, show, get, wait."""

import io
import json
import os
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

import media_fetch as mf

KEY = "test-key"


class FakeSlskd:
    def __init__(self, downloads):
        self.downloads = Path(downloads)
        self.responses = []      # search responses
        self.transfers = {}      # user -> [transfer]
        self.offline = set()
        self.fail = set()        # remote filenames that fail when downloaded
        self.hold = False        # leave transfers queued
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
            if len(parts) == 3:
                return 200, self.responses
            return 200, {"id": parts[1], "isComplete": True}
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
            if t["filename"] in self.fail:
                self.fail.discard(t["filename"])  # a retry succeeds
                t["state"] = "Completed, Errored"
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


class MediaFetchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.staging = root / "staging"
        self.downloads = self.staging / "soulseek"
        self.fake = FakeSlskd(self.downloads)
        self.env = {"MEDIA_STAGING": str(self.staging), "MEDIA_FETCH_STATE": str(root / "state"),
                    "SLSKD_URL": self.fake.url, "SLSKD_API_KEY": KEY,
                    "SLSKD_DOWNLOADS": str(self.downloads)}
        self.saved = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)

    def tearDown(self):
        self.fake.server.shutdown()
        self.fake.server.server_close()
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def cli(self, *args):
        out = io.StringIO()
        code = 0
        with redirect_stdout(out):
            try:
                mf.main(list(args))
            except SystemExit as e:
                code = e.code if isinstance(e.code, int) else 1
                if isinstance(e.code, str):
                    out.write(e.code)
        return code, out.getvalue()

    def search(self, *extra):
        code, out = self.cli("search", "artist album", "--json", *extra)
        self.assertEqual(code, 0, out)
        return json.loads(out)

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
        code, out = self.cli("wait", "slsk-test", "--timeout", "0", "--json")
        self.assertEqual(code, 0, out)
        [s] = json.loads(out)
        self.assertEqual(s["state"], "delivered")
        album = self.staging / "slsk-test" / "Album (2001)"
        self.assertEqual(sorted(p.name for p in album.iterdir()), ["01 One.flac", "03 Three.flac"])
        self.assertFalse((self.downloads / cid).exists())
        self.assertEqual(self.fake.transfers["peer"], [])  # forgotten by the backend too

    def test_failed_file_is_retried_by_get(self):
        self.fake.responses = [response("peer", "M\\Album", ["01", "02"])]
        cid = self.search()["candidates"][0]["id"]
        self.fake.fail.add("M\\Album\\02.flac")
        self.cli("get", cid, "--batch", "b")
        code, out = self.cli("wait", cid, "--timeout", "0")
        self.assertEqual(code, 1)
        self.assertIn("failed: 02.flac", out)
        self.assertFalse((self.staging / "b").exists())
        code, out = self.cli("get", cid)
        self.assertIn("retrying 1", out)
        code, out = self.cli("wait", cid, "--timeout", "0")
        self.assertEqual(code, 0, out)
        self.assertTrue((self.staging / "b" / "Album" / "02.flac").is_file())

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
        self.assertIn("download directory", self.cli("get", cid, "--batch", "soulseek")[1])
        self.assertIn("one plain directory", self.cli("get", cid, "--batch", "a/b")[1])
        self.staging.mkdir(parents=True, exist_ok=True)
        (self.staging / "old.manifest.jsonl").touch()
        self.assertIn("already scanned", self.cli("get", cid, "--batch", "old")[1])
        self.assertIn("outside 1-1", self.cli("get", cid, "--batch", "b", "--files", "2")[1])
        self.assertIn("no candidate", self.cli("show", "ffffff.1")[1])
        self.fake.offline.add("peer")
        self.assertIn("source is offline", self.cli("get", cid, "--batch", "b")[1])

    def test_locate_falls_back_to_name_and_size(self):
        # An slskd that ignored the destination option: the remote folder's name.
        be = mf.Slskd()
        job = {"id": "abc.1", "files": [], "source": {}}
        p = self.downloads / "Album" / "01_639012345.flac"
        p.parent.mkdir(parents=True)
        p.write_bytes(b"x" * 10)
        self.assertEqual(be.locate(job, {"name": "01.flac", "size": 10}), p)
        self.assertIsNone(be.locate(job, {"name": "01.flac", "size": 11}))


if __name__ == "__main__":
    unittest.main()
