#!/usr/bin/env python3
"""media-playlist: manage the playlists of desk's music server.

  list                          every playlist: tracks, length, owner, id
  show    PLAYLIST              its tracks, numbered (and a smart one's rules)
  search  QUERY                 albums and tracks in the library, with their ids
  album   ALBUM                 an album's tracks, with their ids
  create  NAME [ITEM ...]       a new playlist
  add     PLAYLIST ITEM ...     append (or --at N: insert before position N)
  remove  PLAYLIST POSITIONS    drop the tracks at 1,3-5, numbered as `show` lists them
  move    PLAYLIST POSITIONS --to N   move those tracks to position N
  set     PLAYLIST [--name N] [--comment C] [--public | --private]
  delete  PLAYLIST
  export  PLAYLIST [-o FILE]    as M3U, the files' paths on desk
  export  --all DIR             every playlist of yours, DIR/<name>.m3u
  smart   NAME --rules FILE     create a smart playlist, or replace its rules

PLAYLIST is a playlist's id or its name (any case). ITEM is a track's id, or
`album:ID` for every track of an album, in order; `search` prints both ready
to paste. A track already in the playlist is skipped by `add`, unless
--allow-duplicates.

The server is Navidrome, and the playlists are its own: what is made here is
what every client of the same account shows (Feishin, the phone's app, the
web UI), and the other way round. Tracks are kept by id, so a playlist
survives its files being renamed or refiled.

A smart playlist is a rule the server evaluates, not a list: `show` gives its
tracks as of now, and add, remove and move refuse it. FILE (- for stdin) is
the rules as JSON, Navidrome's .nsp format without name and comment:
  {"all": [{"is": {"loved": true}}, {"notInTheLast": {"lastplayed": 180}}],
   "sort": "lastplayed", "order": "asc", "limit": 100}
The server accepts a field it doesn't know and matches nothing with it, so
`smart` prints how many tracks the rules match: check it.

--json on every command.

Environment:
  NAVIDROME_URL         the server (default http://localhost:4533)
  NAVIDROME_USER, NAVIDROME_PASSWORD
                        the account, else the lines of that name in
                        NAVIDROME_LOGIN_FILE (default
                        $XDG_CONFIG_HOME/media-playlist/login.env)
"""

import argparse
import hashlib
import json
import os
import re
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CLIENT = "media-playlist"


class Problem(Exception):
    """Something to tell the user, not a bug."""

    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code  # the HTTP status, when the server gave one


def login_file():
    if os.environ.get("NAVIDROME_LOGIN_FILE"):
        return Path(os.environ["NAVIDROME_LOGIN_FILE"])
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return Path(config) / "media-playlist" / "login.env"


def token_file():
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return Path(cache) / "media-playlist" / "session.json"


def login():
    """(user, password), from the environment or the login file."""
    found = {k: os.environ.get(k) for k in ("NAVIDROME_USER", "NAVIDROME_PASSWORD")}
    path = login_file()
    if not all(found.values()) and path.exists():
        for line in path.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and key.strip() in found and not found[key.strip()]:
                found[key.strip()] = value.strip()
    if not all(found.values()):
        raise Problem(
            f"no login: {path} should hold the music server's account, as\n"
            "  NAVIDROME_USER=…\n  NAVIDROME_PASSWORD=…")
    return found["NAVIDROME_USER"], found["NAVIDROME_PASSWORD"]


class Navidrome:
    """The two APIs Navidrome serves: Subsonic's (/rest) for everything it
    covers, and Navidrome's own (/api) for what it doesn't: M3U export and
    smart playlists."""

    def __init__(self, url, user, password):
        self.url, self.user, self.password = url.rstrip("/"), user, password
        self._token = None

    def _open(self, req):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace").strip()
            try:
                detail = json.loads(detail).get("error", detail)
            except (ValueError, AttributeError):
                pass
            raise Problem(f"the music server answered {e.code}: {detail or e.reason}",
                          e.code) from None
        except OSError as e:
            raise Problem(f"can't reach the music server at {self.url}: {e}") from None

    def rest(self, endpoint, **params):
        """A Subsonic call; a list value repeats its parameter."""
        salt = secrets.token_hex(8)
        params.update(u=self.user, s=salt, v="1.16.1", c=CLIENT, f="json",
                      t=hashlib.md5((self.password + salt).encode()).hexdigest())
        # POST: a long playlist's ids don't fit a URL.
        body = urllib.parse.urlencode(
            {k: v for k, v in params.items() if v is not None}, doseq=True).encode()
        r = json.loads(self._open(urllib.request.Request(
            f"{self.url}/rest/{endpoint}", data=body)))["subsonic-response"]
        if r.get("status") != "ok":
            raise Problem(f"the music server refused {endpoint}: "
                          f"{r.get('error', {}).get('message', r)}")
        return r

    def _login(self):
        token = json.loads(self._open(urllib.request.Request(
            f"{self.url}/auth/login", method="POST",
            headers={"Content-Type": "application/json"},
            data=json.dumps({"username": self.user,
                             "password": self.password}).encode())))["token"]
        try:
            cache = token_file()
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.touch(mode=0o600)
            cache.write_text(json.dumps({"url": self.url, "user": self.user, "token": token}))
        except OSError:
            pass  # only a cache
        return token

    def _cached_token(self):
        try:
            c = json.loads(token_file().read_text())
        except (OSError, ValueError):
            return None
        return c.get("token") if (c.get("url"), c.get("user")) == (self.url, self.user) else None

    def api(self, method, path, body=None, accept="application/json"):
        """A call to Navidrome's own API, as a logged-in session. The session
        is kept between runs: the server allows only a few logins a minute."""
        headers = {"Accept": accept}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        fresh = False
        while True:
            if self._token is None:
                self._token = self._cached_token()
            if self._token is None:
                self._token, fresh = self._login(), True
            headers["X-ND-Authorization"] = f"Bearer {self._token}"
            try:
                raw = self._open(urllib.request.Request(
                    f"{self.url}/api/{path}", method=method, headers=headers, data=data))
            except Problem as e:
                if e.code != 401 or fresh:
                    raise
                self._token, fresh = self._login(), True  # the kept session expired
                continue
            return json.loads(raw) if accept == "application/json" else raw.decode()

    def playlists(self):
        return self.rest("getPlaylists").get("playlists", {}).get("playlist", [])

    def playlist(self, ref):
        """The playlist with this id or name, tracks included."""
        every = self.playlists()
        found = [p for p in every if p["id"] == ref] or \
                [p for p in every if p["name"].casefold() == ref.casefold()]
        if not found:
            raise Problem(f"no playlist {ref!r}; `media-playlist list` names them")
        if len(found) > 1:
            raise Problem(f"{len(found)} playlists are named {ref!r}; use an id: "
                          + ", ".join(p["id"] for p in found))
        p = self.rest("getPlaylist", id=found[0]["id"])["playlist"]
        p.setdefault("entry", [])
        return p

    def replace(self, playlist, ids):
        """Set a playlist's tracks. Subsonic has no reorder; this is it."""
        if not ids:  # the server takes no ids as "leave it alone"
            raise Problem("that would empty the playlist; `delete` it instead")
        self.rest("createPlaylist", playlistId=playlist["id"], songId=ids)

    def tracks(self, items):
        """The tracks ITEMs name, in order: [song]."""
        out = []
        for item in items:
            if item.startswith("album:"):
                album = self.rest("getAlbum", id=item[len("album:"):])["album"]
                out += album.get("song", [])
            else:
                out.append(self.rest("getSong", id=item)["song"])
        return out


def positions(spec, count):
    """`1,3-5` as sorted 0-based indexes into a list of COUNT."""
    out = set()
    for part in spec.split(","):
        m = re.fullmatch(r"\s*(\d+)(?:\s*-\s*(\d+))?\s*", part)
        if not m:
            raise Problem(f"positions are numbers and ranges, like 1,3-5: not {part!r}")
        lo, hi = int(m[1]), int(m[2] or m[1])
        if not 1 <= lo <= hi <= count:
            raise Problem(f"position {part.strip()} is outside 1-{count}")
        out.update(range(lo - 1, hi))
    return sorted(out)


def clock(seconds):
    seconds = int(seconds or 0)
    h, m, s = seconds // 3600, seconds // 60 % 60, seconds % 60
    return f"{h}:{m:02}:{s:02}" if h else f"{m}:{s:02}"


def table(rows):
    """Print rows of strings in columns; the last column is left ragged."""
    rows = [[str(c) for c in r] for r in rows]
    if not rows:
        return
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]) - 1)]
    for r in rows:
        print("  ".join([c.ljust(w) for c, w in zip(r, widths)] + [r[-1]]).rstrip())


def song_row(s):
    return [s.get("artist", ""), s.get("title", ""),
            f"{s.get('album', '')} ({s['year']})" if s.get("year") else s.get("album", ""),
            clock(s.get("duration")), s["id"]]


def summary(p):
    return {"id": p["id"], "name": p["name"], "tracks": p.get("songCount", 0),
            "duration": p.get("duration", 0), "owner": p.get("owner", ""),
            "public": bool(p.get("public")), "smart": bool(p.get("readonly")),
            "comment": p.get("comment", "")}


def song(s):
    return {k: s.get(k) for k in ("id", "title", "artist", "album", "albumId", "year",
                                  "track", "discNumber", "duration")}


def editable(p):
    if p.get("readonly"):
        raise Problem(f"{p['name']!r} is a smart playlist (or another user's): its tracks "
                      "are its rules' result; change the rules with `smart`")


def cmd_list(nd, args):
    every = sorted(nd.playlists(), key=lambda p: p["name"].casefold())
    if args.json:
        return [summary(p) for p in every]
    if not every:
        print("no playlists")
    table([[p["name"], f"{p.get('songCount', 0)} tracks", clock(p.get("duration")),
            p.get("owner", ""),
            " ".join(w for w, on in (("smart", p.get("readonly")), ("public", p.get("public")))
                     if on),
            p["id"]] for p in every])


def cmd_show(nd, args):
    p = nd.playlist(args.playlist)
    rules = nd.api("GET", f"playlist/{p['id']}").get("rules") if p.get("readonly") else None
    if args.json:
        return {**summary(p), "rules": rules, "entries": [song(s) for s in p["entry"]]}
    flags = "".join(f", {w}" for w, on in (("smart", p.get("readonly")),
                                           ("public", p.get("public"))) if on)
    print(f"{p['name']}: {p.get('songCount', 0)} tracks, {clock(p.get('duration'))}{flags}"
          f"  [{p['id']}]")
    if p.get("comment"):
        print(p["comment"])
    if rules:
        print("rules: " + json.dumps(rules))
    table([[i, *song_row(s)] for i, s in enumerate(p["entry"], 1)])


def cmd_search(nd, args):
    r = nd.rest("search3", query=args.query, artistCount=0,
                albumCount=args.albums, songCount=args.songs).get("searchResult3", {})
    albums, songs = r.get("album", []), r.get("song", [])
    if args.json:
        return {"albums": [{"item": f"album:{a['id']}", "name": a.get("name"),
                            "artist": a.get("artist"), "year": a.get("year"),
                            "tracks": a.get("songCount"), "duration": a.get("duration")}
                           for a in albums],
                "songs": [song(s) for s in songs]}
    print(f"albums ({len(albums)})")
    table([[a.get("artist", ""),
            f"{a.get('name', '')} ({a['year']})" if a.get("year") else a.get("name", ""),
            f"{a.get('songCount', 0)} tracks", clock(a.get("duration")), f"album:{a['id']}"]
           for a in albums])
    print(f"\ntracks ({len(songs)})")
    table([song_row(s) for s in songs])


def cmd_album(nd, args):
    a = nd.rest("getAlbum", id=args.album.removeprefix("album:"))["album"]
    songs = a.get("song", [])
    if args.json:
        return {"item": f"album:{a['id']}", "name": a.get("name"), "artist": a.get("artist"),
                "year": a.get("year"), "songs": [song(s) for s in songs]}
    print(f"{a.get('artist', '')} — {a.get('name', '')}"
          + (f" ({a['year']})" if a.get("year") else "") + f"  [album:{a['id']}]")
    multi = len({s.get("discNumber", 1) for s in songs}) > 1
    table([[f"{s.get('discNumber', 1)}-{s.get('track', 0):02}" if multi
            else f"{s.get('track', 0):02}",
            s.get("title", ""), s.get("artist", ""), clock(s.get("duration")), s["id"]]
           for s in songs])


def cmd_create(nd, args):
    if any(p["name"].casefold() == args.name.casefold() and p.get("owner") == nd.user
           for p in nd.playlists()):
        raise Problem(f"a playlist named {args.name!r} exists; `add` to it, or pick another name")
    ids = [s["id"] for s in nd.tracks(args.items)]
    p = nd.rest("createPlaylist", name=args.name, songId=ids)["playlist"]
    if args.comment is not None or args.public:
        nd.rest("updatePlaylist", playlistId=p["id"], comment=args.comment,
                public="true" if args.public else None)
    if args.json:
        return summary(nd.playlist(p["id"]))
    print(f"created {args.name!r} with {len(ids)} tracks  [{p['id']}]")


def cmd_add(nd, args):
    p = nd.playlist(args.playlist)
    editable(p)
    have = [s["id"] for s in p["entry"]]
    new, skipped = [], []
    for s in nd.tracks(args.items):
        if not args.allow_duplicates and s["id"] in have + [n["id"] for n in new]:
            skipped.append(s)
        else:
            new.append(s)
    if new and args.at is not None:
        if not 1 <= args.at <= len(have) + 1:
            raise Problem(f"--at {args.at} is outside 1-{len(have) + 1}")
        nd.replace(p, have[:args.at - 1] + [s["id"] for s in new] + have[args.at - 1:])
    elif new:
        nd.rest("updatePlaylist", playlistId=p["id"], songIdToAdd=[s["id"] for s in new])
    if args.json:
        return {"playlist": p["id"], "added": [song(s) for s in new],
                "skipped": [song(s) for s in skipped]}
    print(f"added {len(new)} tracks to {p['name']!r}"
          + (f"; {len(skipped)} already there, skipped:" if skipped else ""))
    table([song_row(s) for s in skipped])


def cmd_remove(nd, args):
    p = nd.playlist(args.playlist)
    editable(p)
    gone = positions(args.positions, len(p["entry"]))
    nd.rest("updatePlaylist", playlistId=p["id"], songIndexToRemove=gone)
    removed = [p["entry"][i] for i in gone]
    if args.json:
        return {"playlist": p["id"], "removed": [song(s) for s in removed]}
    print(f"removed {len(removed)} tracks from {p['name']!r}:")
    table([song_row(s) for s in removed])


def cmd_move(nd, args):
    p = nd.playlist(args.playlist)
    editable(p)
    ids = [s["id"] for s in p["entry"]]
    picked = positions(args.positions, len(ids))
    rest = [x for i, x in enumerate(ids) if i not in picked]
    if not 1 <= args.to <= len(rest) + 1:
        raise Problem(f"--to {args.to} is outside 1-{len(rest) + 1}")
    order = rest[:args.to - 1] + [ids[i] for i in picked] + rest[args.to - 1:]
    if order != ids:
        nd.replace(p, order)
    if args.json:
        return {"playlist": p["id"], "order": order}
    print(f"moved {len(picked)} tracks of {p['name']!r} to position {args.to}")


def cmd_set(nd, args):
    p = nd.playlist(args.playlist)
    public = "true" if args.public else "false" if args.private else None
    if args.name is None and args.comment is None and public is None:
        raise Problem("nothing to set: --name, --comment, --public or --private")
    nd.rest("updatePlaylist", playlistId=p["id"], name=args.name, comment=args.comment,
            public=public)
    if args.json:
        return summary(nd.playlist(p["id"]))
    print(f"updated {args.name or p['name']!r}")


def cmd_delete(nd, args):
    p = nd.playlist(args.playlist)
    nd.rest("deletePlaylist", id=p["id"])
    if args.json:
        return summary(p)
    print(f"deleted {p['name']!r} ({p.get('songCount', 0)} tracks)")


def cmd_export(nd, args):
    def m3u(p):
        return nd.api("GET", f"playlist/{p['id']}/tracks", accept="audio/x-mpegurl")

    if args.all:
        if args.playlist or args.output:
            raise Problem("--all takes a directory and nothing else")
        out = Path(args.all)
        out.mkdir(parents=True, exist_ok=True)
        written = []
        for p in nd.playlists():
            if p.get("owner") != nd.user:
                continue
            name = re.sub(r'[/\\:*?"<>|\x00-\x1f]', "_", p["name"]).strip(". ") or p["id"]
            path = out / f"{name}.m3u"
            if str(path) in written:  # two playlists of one name
                path = out / f"{name} [{p['id']}].m3u"
            path.write_text(m3u(p))
            written.append(str(path))
        if args.json:
            return {"written": written}
        print(f"wrote {len(written)} playlists to {out}")
        return None
    if not args.playlist:
        raise Problem("which playlist? (or --all DIR)")
    text = m3u(nd.playlist(args.playlist))
    if args.output:
        Path(args.output).write_text(text)
    if args.json:
        return {"written": [args.output]} if args.output else {"m3u": text}
    if args.output:
        print(f"wrote {args.output}")
    else:
        sys.stdout.write(text)
    return None


def cmd_smart(nd, args):
    raw = sys.stdin.read() if args.rules == "-" else Path(args.rules).read_text()
    try:
        rules = json.loads(raw)
    except ValueError as e:
        raise Problem(f"the rules are not JSON: {e}") from None
    if not isinstance(rules, dict) or not ({"all", "any"} & rules.keys()):
        raise Problem('the rules are an object with "all" or "any": a list of conditions')
    mine = [p for p in nd.playlists()
            if p["name"].casefold() == args.name.casefold() and p.get("owner") == nd.user]
    if len(mine) > 1:
        raise Problem(f"{len(mine)} playlists are named {args.name!r}")
    body = {"name": args.name, "rules": rules}
    if args.comment is not None:
        body["comment"] = args.comment
    if args.public:
        body["public"] = True
    if mine:
        if not nd.api("GET", f"playlist/{mine[0]['id']}").get("rules"):
            raise Problem(f"{args.name!r} exists and is not a smart playlist")
        nd.api("PUT", f"playlist/{mine[0]['id']}", {**body, "name": mine[0]["name"]})
        pid, did = mine[0]["id"], "updated"
    else:
        pid, did = nd.api("POST", "playlist", body)["id"], "created"
    p = nd.playlist(pid)  # reading it is what makes the server evaluate the rules
    if args.json:
        return {**summary(p), "rules": rules, "entries": [song(s) for s in p["entry"]]}
    print(f"{did} {p['name']!r}: its rules match {len(p['entry'])} tracks now  [{pid}]")
    table([song_row(s) for s in p["entry"][:10]])
    if len(p["entry"]) > 10:
        print(f"… and {len(p['entry']) - 10} more")
    return None


def main(argv=None):
    p = argparse.ArgumentParser(prog="media-playlist", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)

    def command(name, fn, help):
        s = sub.add_parser(name, help=help, parents=[common])
        s.set_defaults(fn=fn)
        return s

    command("list", cmd_list, "every playlist")

    s = command("show", cmd_show, "a playlist's tracks")
    s.add_argument("playlist")

    s = command("search", cmd_search, "albums and tracks in the library")
    s.add_argument("query")
    s.add_argument("--albums", type=int, default=10, help="how many albums (default 10)")
    s.add_argument("--songs", type=int, default=20, help="how many tracks (default 20)")

    s = command("album", cmd_album, "an album's tracks")
    s.add_argument("album", help="album:ID, as `search` prints it")

    s = command("create", cmd_create, "a new playlist")
    s.add_argument("name")
    s.add_argument("items", nargs="*", metavar="ITEM")
    s.add_argument("--comment")
    s.add_argument("--public", action="store_true", help="other accounts see it")

    s = command("add", cmd_add, "add tracks")
    s.add_argument("playlist")
    s.add_argument("items", nargs="+", metavar="ITEM")
    s.add_argument("--at", type=int, metavar="N", help="insert before position N, not at the end")
    s.add_argument("--allow-duplicates", action="store_true")

    s = command("remove", cmd_remove, "remove tracks")
    s.add_argument("playlist")
    s.add_argument("positions", help="1,3-5, numbered as `show` lists them")

    s = command("move", cmd_move, "reorder")
    s.add_argument("playlist")
    s.add_argument("positions", help="1,3-5, numbered as `show` lists them")
    s.add_argument("--to", type=int, required=True, metavar="N",
                   help="where the first of them lands, counted once they are taken out")

    s = command("set", cmd_set, "rename, comment, share")
    s.add_argument("playlist")
    s.add_argument("--name")
    s.add_argument("--comment")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--public", action="store_true")
    g.add_argument("--private", action="store_true")

    s = command("delete", cmd_delete, "delete a playlist")
    s.add_argument("playlist")

    s = command("export", cmd_export, "as M3U")
    s.add_argument("playlist", nargs="?")
    s.add_argument("-o", "--output", metavar="FILE")
    s.add_argument("--all", metavar="DIR", help="every playlist of yours, one file each")

    s = command("smart", cmd_smart, "create a smart playlist, or replace its rules")
    s.add_argument("name")
    s.add_argument("--rules", required=True, metavar="FILE", help="JSON; - for stdin")
    s.add_argument("--comment")
    s.add_argument("--public", action="store_true")

    args = p.parse_args(argv)
    try:
        nd = Navidrome(os.environ.get("NAVIDROME_URL", "http://localhost:4533"), *login())
        result = args.fn(nd, args)
    except Problem as e:
        print(f"media-playlist: {e}", file=sys.stderr)
        return 1
    if args.json:
        json.dump(result, sys.stdout, indent=2)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
