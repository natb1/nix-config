"""Tests for media-playlist. Run by the package's checkPhase
(`nix build .#media-playlist`, `nix flake check`).

A fake Navidrome runs in a thread: the Subsonic and native endpoints
media-playlist calls, with the shapes and the quirks Navidrome 0.64 has
(createPlaylist with a playlistId and no songs changes nothing; a smart
playlist is `readonly` and refuses new tracks; /auth/login is rate-limited).
The CLI is driven the way an agent drives it."""

import hashlib
import io
import json
import os
import tempfile
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import media_playlist as mp

USER, PASSWORD = "n8", "hunter2"

ALBUMS = {
    "alb1": {"name": "Blue Train", "artist": "John Coltrane", "year": 1958,
             "songs": ["Blue Train", "Moment's Notice", "Locomotion"]},
    "alb2": {"name": "Kind of Blue", "artist": "Miles Davis", "year": 1959,
             "songs": ["So What", "Freddie Freeloader"]},
}


class FakeNavidrome:
    def __init__(self):
        self.songs = {}
        for aid, a in ALBUMS.items():
            for n, title in enumerate(a["songs"], 1):
                sid = f"{aid}s{n}"
                self.songs[sid] = {"id": sid, "title": title, "artist": a["artist"],
                                   "album": a["name"], "albumId": aid, "year": a["year"],
                                   "track": n, "discNumber": 1, "duration": 100 + n}
        self.playlists = {}   # id -> {name, comment, public, owner, ids, rules}
        self.next = 1
        self.logins = 0
        self.tokens = set()
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body, ctype="application/json"):
                body = body if isinstance(body, bytes) else json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _body(self):
                return self.rfile.read(int(self.headers.get("Content-Length") or 0))

            def do_GET(self):
                self.route("GET")

            def do_PUT(self):
                self.route("PUT")

            def do_POST(self):
                self.route("POST")

            def route(self, method):
                path = urlparse(self.path).path
                if path.startswith("/rest/"):
                    q = parse_qs(self._body().decode())
                    try:
                        out = fake.rest(path[len("/rest/"):], q)
                    except LookupError as e:
                        out = {"status": "failed", "error": {"code": 70, "message": str(e)}}
                    else:
                        out = {"status": "ok", **out}
                    return self._send(200, {"subsonic-response": out})
                if path == "/auth/login":
                    body = json.loads(self._body())
                    fake.logins += 1
                    if fake.logins > 5:
                        return self._send(429, b"Too Many Requests", "text/plain")
                    if (body["username"], body["password"]) != (USER, PASSWORD):
                        return self._send(401, {"error": "Invalid username or password"})
                    token = f"jwt{fake.logins}"
                    fake.tokens.add(token)
                    return self._send(200, {"token": token})
                if self.headers.get("X-ND-Authorization", "")[len("Bearer "):] not in fake.tokens:
                    return self._send(401, {"error": "Not authenticated"})
                body = json.loads(self._body() or b"null")
                parts = path[len("/api/"):].split("/")
                if parts == ["playlist"] and method == "POST":
                    return self._send(200, {"id": fake.new(body["name"], [], body)})
                p = fake.playlists.get(parts[1])
                if p is None:
                    return self._send(404, b"not found", "text/plain")
                if parts[2:] == ["tracks"]:
                    lines = ["#EXTM3U", f"#PLAYLIST:{p['name']}"]
                    for s in fake.entries(p):
                        lines += [f"#EXTINF:{s['duration']},{s['artist']} - {s['title']}",
                                  f"/srv/media/music/{s['artist']}/{s['title']}.flac"]
                    return self._send(200, "\n".join(lines).encode() + b"\n", "audio/x-mpegurl")
                if method == "PUT":
                    p.update({k: body[k] for k in ("name", "comment", "public", "rules")
                              if k in body})
                return self._send(200, {"id": parts[1], "name": p["name"], "rules": p["rules"]})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def new(self, name, ids, body=None, owner=USER):
        pid = f"pl{self.next}"
        self.next += 1
        body = body or {}
        self.playlists[pid] = {"name": name, "ids": list(ids), "owner": owner,
                               "comment": body.get("comment", ""),
                               "public": body.get("public", False),
                               "rules": body.get("rules")}
        return pid

    def entries(self, p):
        if p["rules"]:  # the one rule the fake knows: {"all": [{"contains": {"title": X}}]}
            cond = p["rules"].get("all") or p["rules"].get("any")
            want = cond[0]["contains"].get("title")
            return [s for s in self.songs.values()
                    if want is not None and want.lower() in s["title"].lower()]
        return [self.songs[i] for i in p["ids"]]

    def view(self, pid, full=False):
        p = self.playlists[pid]
        entries = self.entries(p)
        out = {"id": pid, "name": p["name"], "comment": p["comment"], "public": p["public"],
               "owner": p["owner"], "songCount": len(entries),
               "duration": sum(s["duration"] for s in entries), "readonly": bool(p["rules"])}
        if full and entries:
            out["entry"] = entries
        return out

    def rest(self, endpoint, q):
        salt, token = q["s"][0], q["t"][0]
        if q["u"][0] != USER or token != hashlib.md5((PASSWORD + salt).encode()).hexdigest():
            raise LookupError("Wrong username or password")
        one = lambda k: q.get(k, [None])[0]  # noqa: E731
        if endpoint == "getPlaylists":
            return {"playlists": {"playlist": [self.view(i) for i in self.playlists]}}
        if endpoint == "getPlaylist":
            return {"playlist": self.view(one("id"), full=True)}
        if endpoint == "getSong":
            if one("id") not in self.songs:
                raise LookupError("Song not found")
            return {"song": self.songs[one("id")]}
        if endpoint == "getAlbum":
            if one("id") not in ALBUMS:
                raise LookupError("Album not found")
            a = ALBUMS[one("id")]
            return {"album": {"id": one("id"), "name": a["name"], "artist": a["artist"],
                              "year": a["year"],
                              "song": [s for s in self.songs.values()
                                       if s["albumId"] == one("id")]}}
        if endpoint == "search3":
            words = one("query").lower().split()
            hit = lambda *text: all(w in " ".join(text).lower() for w in words)  # noqa: E731
            return {"searchResult3": {
                "album": [{"id": i, "name": a["name"], "artist": a["artist"], "year": a["year"],
                           "songCount": len(a["songs"]), "duration": 300}
                          for i, a in ALBUMS.items() if hit(a["name"], a["artist"])
                          ][:int(one("albumCount"))],
                "song": [s for s in self.songs.values()
                         if hit(s["title"], s["artist"], s["album"])][:int(one("songCount"))]}}
        if endpoint == "createPlaylist":
            ids = q.get("songId", [])
            if one("playlistId"):
                if ids:  # none: Navidrome leaves the playlist as it was
                    self.playlists[one("playlistId")]["ids"] = ids
                return {"playlist": self.view(one("playlistId"), full=True)}
            return {"playlist": self.view(self.new(one("name"), ids), full=True)}
        if endpoint == "updatePlaylist":
            p = self.playlists[one("playlistId")]
            if p["rules"] and (q.get("songIdToAdd") or q.get("songIndexToRemove")):
                raise LookupError("User is not authorized for the given operation")
            gone = {int(i) for i in q.get("songIndexToRemove", [])}
            p["ids"] = [x for i, x in enumerate(p["ids"]) if i not in gone]
            p["ids"] += q.get("songIdToAdd", [])
            for k in ("name", "comment"):
                if one(k) is not None:
                    p[k] = one(k)
            if one("public") is not None:
                p["public"] = one("public") == "true"
            return {}
        if endpoint == "deletePlaylist":
            del self.playlists[one("id")]
            return {}
        raise LookupError(f"the fake has no {endpoint}")


class Case(unittest.TestCase):
    def setUp(self):
        self.nd = FakeNavidrome()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.nd.server.shutdown)
        env = {"NAVIDROME_URL": self.nd.url, "NAVIDROME_USER": USER,
               "NAVIDROME_PASSWORD": PASSWORD, "XDG_CACHE_HOME": f"{self.tmp.name}/cache",
               "XDG_CONFIG_HOME": f"{self.tmp.name}/config"}
        old = {k: os.environ.get(k) for k in [*env, "NAVIDROME_LOGIN_FILE"]}
        os.environ.pop("NAVIDROME_LOGIN_FILE", None)
        os.environ.update(env)
        self.addCleanup(lambda: [os.environ.pop(k, None) if v is None
                                 else os.environ.__setitem__(k, v) for k, v in old.items()])

    def run_cli(self, *argv, stdin=None, code=0):
        out, err = io.StringIO(), io.StringIO()
        old = mp.sys.stdin
        mp.sys.stdin = io.StringIO(stdin or "")
        try:
            with redirect_stdout(out), redirect_stderr(err):
                got = mp.main(list(argv))
        finally:
            mp.sys.stdin = old
        self.assertEqual(got, code, err.getvalue() or out.getvalue())
        return out.getvalue() if code == 0 else err.getvalue()

    def js(self, *argv, **kw):
        return json.loads(self.run_cli(*argv, "--json", **kw))

    def ids(self, name):
        return next(p for p in self.nd.playlists.values() if p["name"] == name)["ids"]


class Editing(Case):
    def test_search_prints_items_ready_to_paste(self):
        out = self.run_cli("search", "blue")
        self.assertIn("album:alb1", out)
        self.assertIn("album:alb2", out)
        self.assertIn("alb1s1", out)
        r = self.js("search", "coltrane", "--songs", "2")
        self.assertEqual([a["item"] for a in r["albums"]], ["album:alb1"])
        self.assertEqual(len(r["songs"]), 2)
        self.assertIn("Moment's Notice", self.run_cli("album", "album:alb1"))

    def test_create_add_remove_move(self):
        self.run_cli("create", "Jazz", "album:alb1", "--comment", "late", "--public")
        self.assertEqual(self.ids("Jazz"), ["alb1s1", "alb1s2", "alb1s3"])
        p = self.js("list")[0]
        self.assertEqual((p["comment"], p["public"], p["tracks"]), ("late", True, 3))

        # by name, any case; what is already there is skipped
        r = self.js("add", "jazz", "alb2s1", "alb1s2", "alb2s1")
        self.assertEqual([s["id"] for s in r["added"]], ["alb2s1"])
        self.assertEqual([s["id"] for s in r["skipped"]], ["alb1s2", "alb2s1"])
        self.run_cli("add", "Jazz", "alb1s1", "--allow-duplicates", "--at", "2")
        self.assertEqual(self.ids("Jazz"), ["alb1s1", "alb1s1", "alb1s2", "alb1s3", "alb2s1"])

        self.assertIn("Blue Train", self.run_cli("remove", "Jazz", "2"))
        self.run_cli("move", "Jazz", "3-4", "--to", "1")
        self.assertEqual(self.ids("Jazz"), ["alb1s3", "alb2s1", "alb1s1", "alb1s2"])
        self.run_cli("move", "Jazz", "1", "--to", "4")
        self.assertEqual(self.ids("Jazz"), ["alb2s1", "alb1s1", "alb1s2", "alb1s3"])
        out = self.run_cli("show", "Jazz")
        self.assertIn("4 tracks", out)
        self.assertLess(out.index("So What"), out.index("Locomotion"))

    def test_refusals(self):
        self.run_cli("create", "Jazz", "alb1s1")
        self.assertIn("exists", self.run_cli("create", "JAZZ", code=1))
        self.assertIn("outside 1-1", self.run_cli("remove", "Jazz", "2", code=1))
        self.assertIn("like 1,3-5", self.run_cli("remove", "Jazz", "x", code=1))
        self.assertIn("--to 3", self.run_cli("move", "Jazz", "1", "--to", "3", code=1))
        self.assertIn("Song not found", self.run_cli("add", "Jazz", "nope", code=1))
        self.assertIn("no playlist", self.run_cli("show", "Rock", code=1))
        self.assertIn("nothing to set", self.run_cli("set", "Jazz", code=1))
        self.assertEqual(self.ids("Jazz"), ["alb1s1"])

    def test_two_playlists_of_one_name_need_an_id(self):
        self.nd.new("Mix", ["alb1s1"])
        other = self.nd.new("mix", ["alb2s1"], owner="lindsey")
        self.assertIn(other, self.run_cli("show", "Mix", code=1))
        self.assertIn("So What", self.run_cli("show", other))

    def test_set_and_delete(self):
        self.run_cli("create", "Jazz", "alb1s1", "--public")
        self.run_cli("set", "Jazz", "--name", "Late Jazz", "--private")
        p = self.js("list")[0]
        self.assertEqual((p["name"], p["public"]), ("Late Jazz", False))
        self.assertIn("1 tracks", self.run_cli("delete", "Late Jazz"))
        self.assertEqual(self.nd.playlists, {})


class Native(Case):
    def test_export_keeps_its_session(self):
        self.run_cli("create", "Jazz", "album:alb2")
        for _ in range(8):  # more than the server's logins a minute
            out = self.run_cli("export", "Jazz")
        self.assertIn("/srv/media/music/Miles Davis/So What.flac", out)
        self.assertEqual(self.nd.logins, 1)
        cache = Path(self.tmp.name, "cache/media-playlist/session.json")
        self.assertEqual(cache.stat().st_mode & 0o777, 0o600)

        self.nd.tokens.clear()  # the session expired: log in again, once
        self.run_cli("export", "Jazz", "-o", f"{self.tmp.name}/jazz.m3u")
        self.assertEqual(self.nd.logins, 2)
        self.assertIn("#PLAYLIST:Jazz", Path(self.tmp.name, "jazz.m3u").read_text())

    def test_export_all_is_this_accounts(self):
        self.run_cli("create", "Jazz", "alb1s1")
        self.run_cli("create", "AC/DC: best", "alb2s1")
        self.nd.new("Hers", ["alb1s2"], owner="lindsey")
        out = Path(self.tmp.name, "out")
        self.assertEqual(len(self.js("export", "--all", str(out))["written"]), 2)
        self.assertEqual(sorted(p.name for p in out.iterdir()), ["AC_DC_ best.m3u", "Jazz.m3u"])

    def test_smart(self):
        rules = {"all": [{"contains": {"title": "blue"}}], "limit": 5}
        out = self.run_cli("smart", "Blues", "--rules", "-", stdin=json.dumps(rules))
        self.assertIn("created 'Blues': its rules match 1 tracks", out)
        shown = self.js("show", "Blues")
        self.assertEqual((shown["smart"], shown["rules"]), (True, rules))

        # the same name again replaces the rules; a field that matches nothing shows as 0
        out = self.run_cli("smart", "blues", "--rules", "-",
                           stdin='{"all": [{"contains": {"nosuchfield": "x"}}]}')
        self.assertIn("updated 'Blues': its rules match 0 tracks", out)
        self.assertEqual(len(self.nd.playlists), 1)

        self.assertIn("smart playlist", self.run_cli("add", "Blues", "alb1s1", code=1))
        self.assertIn("smart playlist", self.run_cli("remove", "Blues", "1", code=1))
        self.run_cli("create", "Jazz", "alb1s1")
        self.assertIn("not a smart playlist",
                      self.run_cli("smart", "Jazz", "--rules", "-", stdin=json.dumps(rules),
                                   code=1))
        self.assertIn("not JSON", self.run_cli("smart", "X", "--rules", "-", stdin="no", code=1))
        self.assertIn('"all" or "any"',
                      self.run_cli("smart", "X", "--rules", "-", stdin="[]", code=1))


class Login(Case):
    def test_login_file(self):
        del os.environ["NAVIDROME_USER"], os.environ["NAVIDROME_PASSWORD"]
        self.assertIn("login.env", self.run_cli("list", code=1))
        path = Path(self.tmp.name, "config/media-playlist/login.env")
        path.parent.mkdir(parents=True)
        path.write_text(f"# desk\nNAVIDROME_USER={USER}\nNAVIDROME_PASSWORD={PASSWORD}\n")
        self.assertIn("no playlists", self.run_cli("list"))

    def test_wrong_password_and_no_server(self):
        os.environ["NAVIDROME_PASSWORD"] = "wrong"
        self.assertIn("Wrong username or password", self.run_cli("list", code=1))
        os.environ["NAVIDROME_URL"] = "http://127.0.0.1:1"
        self.assertIn("can't reach the music server", self.run_cli("list", code=1))


if __name__ == "__main__":
    unittest.main()
