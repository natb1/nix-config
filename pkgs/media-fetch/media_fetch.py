#!/usr/bin/env python3
"""media-fetch: find media and fetch it into staging.

  search QUERY --kind KIND   list candidates, one table per place searched
  show   ID                  a candidate's files, numbered
  get    ID --batch BATCH    download a candidate (or --files 1,3-5 of it)
  status [JOB|BATCH ...]     progress of each download
  wait   [JOB|BATCH ...]     block until downloads finish; deliver the finished ones
  cancel JOB|BATCH ...       stop downloads and forget them
  pump   [--every S]         ask for queued files, deliver finished jobs (the service)

KIND is what is sought: music, audiobook, book, rpg, comic, movie, tv,
video or other. It picks the places searched, each a table of its own:
  corpus fetch   every kind
  media share    every kind: what is already filed in the kind's library
                 folder, or staged, whose path matches every word of the
                 query, in any format; nothing to fetch
  itch.io        rpg too: tabletop games from itch.io's search and the
                 account's own library. Free games and the account's own
                 can be fetched; the rest are listed with their price.

A candidate is what one place offers in one folder: an album, a book, a
season, an itch.io game. Its ID (`3fa2c1.4`: search, then rank, numbered
across the tables) names it until the next `search` is long forgotten;
results are kept in the state directory. `get` starts a job with the
candidate's ID. `wait` delivers each job whose files have all arrived into
STAGING/BATCH/<title>/, the same batch directory media-stage takes, and
then `media-stage scan` (or, for music, `media-stage group` and `beet
stage-review`) takes over. A job that failed is left undelivered; `get`
with the same ID again retries the files that failed.

The CLI, the IDs, the states (queued, downloading, done, failed) and the
JSON (--json on every command) are the same whichever place a candidate
came from.

A source is asked for at most MEDIA_FETCH_PER_SOURCE files at a time, across
all jobs; the rest of a job waits here, queued. `pump` asks for the next ones
as earlier ones finish and delivers finished jobs; on desk a service runs it
all the time, and `get` and `wait` do the same while they run, so nothing
needs to be kept running. `wait` prints a line whenever a job moves.
`status`, `wait` and `get` estimate the time left: what is left of the job
and of the jobs ahead of it at its source, at the source's measured speed
(before a file starts: the speed it offered in the search). Time spent in a
source's own queue is not counted.

Environment:
  MEDIA_STAGING        batch directories' parent (default /srv/media/staging)
  MEDIA_LIBRARY        the media share (default: MEDIA_STAGING's parent)
  MEDIA_FETCH_STATE    results and jobs (default $XDG_STATE_HOME/media-fetch)
  MEDIA_FETCH_PER_SOURCE  files in flight per source (default 1)
  CORPUS_URL           corpus fetch's service (default http://localhost:5030)
  CORPUS_API_KEY       its key, else the API_KEY line of CORPUS_KEY_FILE
  CORPUS_DOWNLOADS     where it downloads to
  ITCH_API_KEY         itch.io's key, else the API_KEY line of ITCH_KEY_FILE
                       (default /etc/itch/api.env)
  ITCH_DOWNLOADS       where itch.io downloads go (default STAGING/.itch)
  ITCH_API_URL, ITCH_WEB_URL   default https://api.itch.io, https://itch.io
"""

import argparse
import concurrent.futures
import datetime
import fcntl
import hashlib
import html
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections import Counter
from pathlib import Path

LOSSLESS_EXT = {"flac", "wav", "aif", "aiff", "alac", "ape", "wv"}
# Disc folders are named for their album, not themselves.
DISC_DIR = re.compile(r"^(cd|disc|disk)\s*\d+$", re.I)
STATES = ("queued", "downloading", "done", "failed")


class FetchError(Exception):
    pass


def key_from(path, what):
    """The value of the NAME=value line whose NAME ends in API_KEY."""
    if not path:
        raise FetchError(f"no API key for {what}")
    try:
        text = Path(path).read_text()
    except OSError as e:
        raise FetchError(f"no API key for {what}: {e.strerror}")
    for line in text.splitlines():
        k, eq, v = line.partition("=")
        if eq and k.strip().endswith("API_KEY") and v.strip():
            return v.strip()
    raise FetchError(f"no API key for {what}")


# --------------------------------------------------------------------------
# Backend interface
#
# Candidates and jobs are plain dicts, stored as JSON. `source` in each is
# the backend's own, opaque to everything else: whatever it needs to fetch
# the files again. A file is {"name", "size", ...optional "duration" (s),
# "bitrate" (kbps), "bitdepth", "samplerate" (Hz)}.


class Backend:
    # The directory the backend downloads into. Delivery moves out of it.
    download_root: Path

    def search(self, query, timeout):
        """Candidates: [{"title", "files", "availability": {"ready",
        "queue", "speed"}, "source"}]. speed is bytes/s."""
        raise NotImplementedError

    def source_key(self, job):
        """Who serves the job's files. Jobs with the same key share one
        source's MEDIA_FETCH_PER_SOURCE."""
        raise NotImplementedError

    def download(self, job, files):
        """Start downloading `files` (a subset of job["files"])."""
        raise NotImplementedError

    def progress(self, job):
        """{file name: {"state": one of STATES, "bytes": transferred}}, plus
        "reason" (why, in a few words) on a failed file and "speed" (bytes/s)
        on a downloading one. "busy": True on a file the source refused
        because it takes no more requests for now: the job asks it for
        nothing more."""
        raise NotImplementedError

    def locate(self, job, file):
        """Path of a finished file, or None."""
        raise NotImplementedError

    def cancel(self, job):
        raise NotImplementedError

    def forget(self, job):
        """Drop the backend's records of a delivered job. Best effort."""


# --------------------------------------------------------------------------
# slskd (hosts/desk/soulseek.nix). API: /api/v0, X-API-Key header.


# A peer's refusals that mean "not now", not "not this file": its upload
# queue is full, or its client limits how much one user may queue.
BUSY = re.compile(r"try again later|overwhelmed|too many (files|megabytes)", re.I)


class Slskd(Backend):
    # "corpus fetch" in everything the CLI prints. Its settings are CORPUS_*;
    # the package's wrapper points them at slskd's key file and downloads.
    def __init__(self):
        self.url = os.environ.get("CORPUS_URL", "http://localhost:5030").rstrip("/") + "/api/v0"
        self.download_root = Path(os.environ.get("CORPUS_DOWNLOADS") or staging_dir() / ".corpus")
        self._key = None

    @property
    def key(self):
        if self._key is None:
            self._key = os.environ.get("CORPUS_API_KEY") or \
                key_from(os.environ.get("CORPUS_KEY_FILE"), "corpus fetch")
        return self._key

    def _call(self, method, path, body=None, ok404=False):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.url + path, data=data, method=method)
        req.add_header("X-API-Key", self.key)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                text = r.read()
        except urllib.error.HTTPError as e:
            with e:
                detail = e.read().decode(errors="replace").strip()[:300]
            if e.code == 404 and ok404:
                return None
            raise FetchError(f"{method} {path}: HTTP {e.code} {detail}")
        except urllib.error.URLError as e:
            raise FetchError(f"cannot reach {self.url}: {e.reason}")
        return json.loads(text) if text.strip() else None

    def source_key(self, job):
        return job["source"]["user"]

    def search(self, query, timeout):
        sid = str(uuid.uuid4())
        self._call("POST", "/searches", {"id": sid, "searchText": query})
        deadline = time.monotonic() + timeout
        while True:
            s = self._call("GET", f"/searches/{sid}")
            if s.get("isComplete") or time.monotonic() >= deadline:
                break
            time.sleep(1)
        if not s.get("isComplete"):
            self._call("PUT", f"/searches/{sid}")  # stop it; keep what came in
        # slskd saves the responses when the search completes, which a stop
        # does a moment later: until then /responses is empty. (Its count can
        # be one more than it saves, so empty-or-not is the test.)
        settle = time.monotonic() + 15
        while True:
            s = self._call("GET", f"/searches/{sid}")
            responses = self._call("GET", f"/searches/{sid}/responses") or []
            if (s.get("isComplete") and (responses or not s.get("responseCount"))) \
                    or time.monotonic() >= settle:
                break
            time.sleep(0.5)
        out = []
        for r in responses:
            folders = {}
            for f in r.get("files") or []:  # lockedFiles are not offered
                d, _, _ = f["filename"].rpartition("\\")
                folders.setdefault(d, []).append(f)
            for d, fs in folders.items():
                parts = [p for p in d.split("\\") if p]
                title = parts[-1] if parts else r["username"]
                if DISC_DIR.match(title) and len(parts) > 1:
                    title = f"{parts[-2]} - {title}"
                fs.sort(key=lambda f: f["filename"])
                files = [_file(f) for f in fs]
                out.append({
                    "title": title,
                    "files": files,
                    "availability": {
                        "ready": bool(r.get("hasFreeUploadSlot")),
                        "queue": r.get("queueLength") or 0,
                        "speed": r.get("uploadSpeed") or 0,
                    },
                    "source": {
                        "user": r["username"],
                        "paths": {x["name"]: f["filename"] for x, f in zip(files, fs)},
                    },
                })
        return out

    def download(self, job, files):
        src = job["source"]
        body = {
            "id": str(uuid.uuid4()),
            "username": src["user"],
            "files": [{"filename": src["paths"][f["name"]], "size": f["size"]} for f in files],
            # One folder per job under the download directory, so two jobs
            # never share a folder and locate() knows where to look.
            "options": {"destination": job["id"]},
        }
        try:
            r = self._call("POST", "/transfers/downloads/batches", body)
        except FetchError as e:
            if "HTTP 404" in str(e):
                raise FetchError("the source is offline; try another candidate")
            raise
        failures = (r or {}).get("failures") or []
        if failures and len(failures) == len(files):
            raise FetchError(f"nothing was queued: {failures}")

    def _transfers(self, job):
        user = urllib.parse.quote(job["source"]["user"], safe="")
        r = self._call("GET", f"/transfers/downloads/{user}", ok404=True) or {}
        by_remote = {}
        for d in r.get("directories") or []:
            for t in d.get("files") or []:
                prev = by_remote.get(t["filename"])
                # A retried file has an old failed record too; the newest wins.
                if prev is None or (t.get("requestedAt") or "") >= (prev.get("requestedAt") or ""):
                    by_remote[t["filename"]] = t
        names = {v: k for k, v in job["source"]["paths"].items()}
        return {names[k]: t for k, t in by_remote.items() if k in names}

    def progress(self, job):
        ts = self._transfers(job)
        out = {}
        for f in job["files"]:
            t = ts.get(f["name"])
            if t is None:
                out[f["name"]] = {"state": "failed", "bytes": 0,
                                  "reason": "never started: the source has no record of it"}
                continue
            st = t.get("state", "")
            p = {"bytes": t.get("bytesTransferred") or 0}
            if st == "Completed, Succeeded":
                p["state"] = "done"
            elif st.startswith("Completed"):
                p["state"] = "failed"
                p["reason"] = self._reason(st, t.get("exception"))
                if st == "Completed, Rejected" and BUSY.search(t.get("exception") or ""):
                    p["busy"] = True
            elif st == "InProgress":
                p["state"] = "downloading"
                p["speed"] = t.get("averageSpeed") or 0
            else:
                p["state"] = "queued"
            out[f["name"]] = p
        return out

    @staticmethod
    def _reason(state, exception):
        # slskd's message ("Transfer rejected: ..."), else the state:
        # "Completed, TimedOut" -> "timed out".
        if exception:
            return exception
        return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", state.partition(", ")[2]).lower() or state

    def locate(self, job, file):
        base = file["name"]
        p = self.download_root / job["id"] / base
        if p.is_file():
            return p
        # Not where the destination option should have put it: an slskd that
        # ignores it keeps the remote folder's name, and one that finds the
        # name taken appends a suffix. Same size is the tie-breaker.
        stem, dot, ext = base.rpartition(".")
        for q in self.download_root.rglob("*"):
            if q.is_file() and (q.name == base or (dot and q.name.startswith(stem) and q.name.endswith(dot + ext))) \
                    and q.stat().st_size == file["size"]:
                return q
        return None

    def cancel(self, job):
        user = urllib.parse.quote(job["source"]["user"], safe="")
        for t in self._transfers(job).values():
            self._call("DELETE", f"/transfers/downloads/{user}/{t['id']}?remove=true", ok404=True)

    def forget(self, job):
        try:
            self.cancel(job)
        except FetchError:
            pass


def _file(f):
    out = {"name": f["filename"].rpartition("\\")[2], "size": f.get("size") or 0}
    for ours, theirs in (("duration", "length"), ("bitrate", "bitRate"),
                         ("bitdepth", "bitDepth"), ("samplerate", "sampleRate")):
        if f.get(theirs):
            out[ours] = f[theirs]
    return out


# --------------------------------------------------------------------------
# itch.io. The API's own search finds little, so games are found by the
# site's search (tabletop games only) and in the account's library
# (/profile/owned-keys). A candidate is one game and its hosted uploads: a
# free game's without a key, an owned one's with its download key. A paid
# game the account does not own shows no uploads; it is listed, with its
# price, to be bought.
#
# A download is a redirect to a signed link that expires in a minute, so
# each `download` starts a worker process (`media-fetch _itch-fetch`) that
# fetches the files one by one into download_root/<job>/. It leaves beside
# them what progress() reads: .<name>.req (its pid, when it was asked),
# <name>.part while it downloads, then <name>, or .<name>.failed (why).

GAME_CELL = re.compile(r'(?=<div[^>]*\bdata-game_id=")')
_children = []  # workers this process started, reaped as they finish


class NoRedirect(urllib.request.HTTPRedirectHandler):
    # The signed link must not get the API key: the redirect is followed by
    # hand, without it.
    def redirect_request(self, *a, **kw):
        return None


class Itch(Backend):
    games_searched = 15  # the site's first results, each an uploads call

    def __init__(self):
        self.api = os.environ.get("ITCH_API_URL", "https://api.itch.io").rstrip("/")
        self.web = os.environ.get("ITCH_WEB_URL", "https://itch.io").rstrip("/")
        self.download_root = Path(os.environ.get("ITCH_DOWNLOADS") or staging_dir() / ".itch")
        self._key = None

    @property
    def key(self):
        if self._key is None:
            self._key = os.environ.get("ITCH_API_KEY") or \
                key_from(os.environ.get("ITCH_KEY_FILE", "/etc/itch/api.env"), "itch.io")
        return self._key

    def _open(self, url, auth=True, opener=None):
        req = urllib.request.Request(url, headers={"User-Agent": "media-fetch"})
        if auth:
            req.add_header("Authorization", f"Bearer {self.key}")
        try:
            return (opener or urllib.request.build_opener()).open(req, timeout=30)
        except urllib.error.HTTPError as e:
            if 300 <= e.code < 400:
                raise
            with e:
                detail = e.read().decode(errors="replace").strip()[:300]
            raise FetchError(f"itch.io: HTTP {e.code} {detail}")
        except urllib.error.URLError as e:
            raise FetchError(f"cannot reach itch.io: {e.reason}")

    def _api(self, path):
        with self._open(self.api + path) as r:
            d = json.loads(r.read())
        if d.get("errors"):
            raise FetchError(f"itch.io: {'; '.join(d['errors'])}")
        return d

    def _owned(self):
        """{game id: (download key id, game)} for the account's library."""
        out = {}
        for page in range(1, 101):
            d = self._api(f"/profile/owned-keys?page={page}")
            keys = d.get("owned_keys") or []
            for k in keys:
                g = k["game"]
                out[g["id"]] = (k["id"], {"id": g["id"], "title": g["title"], "url": g.get("url", ""),
                                          "author": (g.get("user") or {}).get("display_name")
                                          or (g.get("user") or {}).get("username", ""),
                                          "price": None})
            if len(keys) < (d.get("per_page") or 50):
                break
        return out

    def _found(self, query):
        """The site's search, tabletop games: [{id, title, url, author, price}],
        price None when free."""
        q = urllib.parse.urlencode({"q": query, "classification": "physical_game"})
        with self._open(f"{self.web}/search?{q}", auth=False) as r:
            page = r.read().decode(errors="replace")
        out = []
        for cell in GAME_CELL.split(page)[1:]:
            gid = re.search(r'data-game_id="(\d+)"', cell)
            title = re.search(r'<a([^>]*class="title game_link"[^>]*)>([^<]*)</a>', cell)
            if not gid or not title:
                continue
            href = re.search(r'href="([^"]+)"', title.group(1))
            author = re.search(r'class="game_author"><a[^>]*>([^<]*)', cell)
            price = re.search(r'class="price_value"[^>]*>([^<]*)', cell)
            out.append({"id": int(gid.group(1)), "title": html.unescape(title.group(2)).strip(),
                        "url": href.group(1) if href else "",
                        "author": html.unescape(author.group(1)).strip() if author else "",
                        "price": html.unescape(price.group(1)).strip() if price else None})
        return out

    def _candidate(self, game, key):
        q = f"?download_key_id={key}" if key else ""
        uploads = self._api(f"/games/{game['id']}/uploads{q}").get("uploads") or []
        files, ids = [], {}
        for u in uploads:  # [] or, when there are none, {}
            if u.get("storage") != "hosted" or not u.get("filename"):
                continue  # an external link: nothing to fetch
            name = _safe(u["filename"])
            if name in ids:
                name = f"{u['id']} {name}"
            files.append({"name": name, "size": u.get("size") or 0,
                          **({"md5": u["md5_hash"]} if u.get("md5_hash") else {})})
            ids[name] = u["id"]
        c = {"title": game["title"], "files": files,
             "availability": {"ready": bool(files) and (key is not None or game["price"] is None),
                              "queue": 0, "speed": 0},
             "author": game["author"], "url": game["url"],
             "price": "owned" if key else game["price"] or "free",
             "source": {"game": game["id"], "key": key, "uploads": ids}}
        if not files and key is None and game["price"]:
            c["buy"] = True  # its files show once it is owned
        return c

    def search(self, query, timeout):
        owned = self._owned()
        found = self._found(query)[:self.games_searched]
        seen = {g["id"] for g in found}
        words = query.casefold().split()
        mine = [g for _, g in owned.values()
                if g["id"] not in seen and all(w in g["title"].casefold() for w in words)]

        def one(g):
            try:
                return self._candidate(g, owned.get(g["id"], (None,))[0])
            except FetchError:
                return None
        with concurrent.futures.ThreadPoolExecutor(8) as ex:
            return [c for c in ex.map(one, mine + found) if c]

    def source_key(self, job):
        return "itch.io"

    def _paths(self, job, name):
        d = self.download_root / job["id"]
        return d / name, d / f"{name}.part", d / f".{name}.req", d / f".{name}.failed"

    def download(self, job, files):
        src = job["source"]
        d = self.download_root / job["id"]
        d.mkdir(parents=True, exist_ok=True)
        for f in files:
            _, part, _, failed = self._paths(job, f["name"])
            part.unlink(missing_ok=True)
            failed.unlink(missing_ok=True)
        spec = {"dir": str(d), "key": src["key"],
                "files": [{"name": f["name"], "upload": src["uploads"][f["name"]],
                           "size": f["size"], "md5": f.get("md5")} for f in files]}
        p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "_itch-fetch", json.dumps(spec)],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        _children.append(p)
        for f in files:
            self._paths(job, f["name"])[2].write_text(json.dumps({"pid": p.pid, "at": time.time()}))

    def progress(self, job):
        _children[:] = [c for c in _children if c.poll() is None]
        out = {}
        for f in job["files"]:
            done, part, req, failed = self._paths(job, f["name"])
            if done.is_file():
                p = {"state": "done", "bytes": f["size"]}
            elif failed.is_file():
                p = {"state": "failed", "bytes": 0, "reason": failed.read_text().strip()}
            elif not req.is_file():
                p = {"state": "failed", "bytes": 0, "reason": "never started"}
            else:
                r = json.loads(req.read_text())
                if not _alive(r["pid"]):
                    p = {"state": "done", "bytes": f["size"]} if done.is_file() else \
                        {"state": "failed", "bytes": 0, "reason": "interrupted"}
                elif part.is_file():
                    got = part.stat().st_size
                    p = {"state": "downloading", "bytes": got,
                         "speed": round(got / max(time.time() - r["at"], 1))}
                else:
                    p = {"state": "queued", "bytes": 0}
            out[f["name"]] = p
        return out

    def locate(self, job, file):
        p = self._paths(job, file["name"])[0]
        return p if p.is_file() else None

    def cancel(self, job):
        for f in job["files"]:
            req = self._paths(job, f["name"])[2]
            try:
                os.killpg(json.loads(req.read_text())["pid"], signal.SIGTERM)
            except (OSError, ValueError, KeyError):
                pass
        shutil.rmtree(self.download_root / job["id"], ignore_errors=True)

    def forget(self, job):
        shutil.rmtree(self.download_root / job["id"], ignore_errors=True)

    def fetch(self, upload, key, to, size, md5):
        q = f"?download_key_id={key}" if key else ""
        try:
            r = self._open(f"{self.api}/uploads/{upload}/download{q}",
                           opener=urllib.request.build_opener(NoRedirect))
        except urllib.error.HTTPError as e:
            with e:
                where = e.headers.get("Location")
            if not where:
                raise FetchError(f"itch.io: HTTP {e.code} with nowhere to go")
            r = self._open(urllib.parse.urljoin(e.filename, where), auth=False)
        h, got = hashlib.md5(), 0
        with r, open(to, "wb") as out:
            while chunk := r.read(1 << 20):
                out.write(chunk)
                h.update(chunk)
                got += len(chunk)
        if size and got != size:
            raise FetchError(f"got {got} bytes of {size}")
        if md5 and h.hexdigest() != md5:
            raise FetchError("the file's checksum does not match itch.io's")


def itch_fetch(spec):
    """The worker behind Itch.download."""
    be, d = Itch(), Path(spec["dir"])
    for f in spec["files"]:
        part = d / f"{f['name']}.part"
        try:
            be.fetch(f["upload"], spec["key"], part, f["size"], f.get("md5"))
            part.replace(d / f["name"])
        except Exception as e:  # anything: the file fails, with why
            (d / f".{f['name']}.failed").write_text(f"{e}\n")
            part.unlink(missing_ok=True)


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:  # another member of the group's worker
        return True
    return True


# --------------------------------------------------------------------------
# The media share: what is already filed (MEDIA_LIBRARY, docs/desktop-
# migration.md, "Layout on the share") or staged, so a search shows what a
# download would duplicate. Read-only: its candidates are not fetched. One
# candidate per item, the folder at ITEM_DEPTH under the kind's library
# folder (an album under its artist, a game or line, a show, a film, an
# author, a channel) or a staging batch, with its files whose path matches
# every word of the query.

LIBRARY = {"music": ["music"], "audiobook": ["books"], "book": ["books"], "comic": ["books"],
           "rpg": ["rpg"], "movie": ["movies"], "tv": ["tv"], "video": ["youtube", "movies", "tv"]}
ITEM_DEPTH = {"music": 2}  # else 1


def _words(text):
    return " ".join(re.findall(r"\w+", text.casefold()))


class Share(Backend):
    download_root = None

    def __init__(self, skip=()):
        self.root = Path(os.environ.get("MEDIA_LIBRARY") or staging_dir().parent)
        # The other backends' download directories, and staging's trash.
        self.skip = {Path(x).resolve() for x in skip} | {(staging_dir() / "trash").resolve()}

    def search(self, query, timeout, kind="other"):
        words = _words(query).split()
        folders = LIBRARY.get(kind) or sorted({f for fs in LIBRARY.values() for f in fs})
        out = [self._items(self.root / f, ITEM_DEPTH.get(f, 1), words, "filed") for f in folders]
        out.append(self._items(staging_dir(), 1, words, "staged"))
        return [c for cs in out for c in cs]

    def _items(self, top, depth, words, where):
        items = {}
        if not top.is_dir():
            return []
        for d, dirs, files in os.walk(top):
            dirs[:] = sorted(x for x in dirs if not x.startswith(".")
                             and (Path(d) / x).resolve() not in self.skip)
            for name in files:
                p = Path(d) / name
                parts = p.relative_to(top).parts
                if len(parts) <= depth or name.startswith("."):
                    continue  # a loose file above the items: README.md, manifests
                if all(w in _words(" ".join(parts)) for w in words):
                    items.setdefault(parts[:depth], []).append(p)
        out = []
        for key, paths in sorted(items.items()):
            item = top.joinpath(*key)
            out.append({"title": str(item.relative_to(self.root)) if self.root in item.parents else str(item),
                        "files": [{"name": str(p.relative_to(item)), "size": p.stat().st_size}
                                  for p in sorted(paths)],
                        "availability": {"ready": False, "queue": 0, "speed": 0},
                        "path": str(item), "where": where, "source": {}})
        return out


# --------------------------------------------------------------------------
# Every backend at once. A candidate and its job carry "backend", the key
# here; each job's calls go to the backend it came from. A job from before
# there was a choice is the corpus's.

BACKENDS = {"corpus": Slskd, "share": Share, "itch": Itch}
# What the CLI calls each, and which kinds search it (None: every kind), in
# the order the tables are shown.
TABLES = {"corpus": ("corpus fetch", None), "share": ("media share", None), "itch": ("itch.io", {"rpg"})}
KINDS = ("music", "audiobook", "book", "rpg", "comic", "movie", "tv", "video", "other")
# The corpus's file types for each kind when --ext is not given: a search
# for "unravel" as an rpg should not list the song. Subtitles go with video.
_VIDEO = "mkv,mp4,m4v,avi,webm,mov,srt,ass,sub"
KIND_EXT = {"music": "flac,mp3,m4a,ogg,opus,wav,aif,aiff,alac,ape,wv", "audiobook": "m4b,mp3,m4a,aac,ogg,opus,flac",
            "book": "epub,pdf,mobi,azw3,djvu", "comic": "cbz,cbr,pdf,epub", "rpg": "pdf,epub,zip,cbz",
            "movie": _VIDEO, "tv": _VIDEO, "video": _VIDEO}


class Backends(Backend):
    def __init__(self):
        fetch = {name: cls() for name, cls in BACKENDS.items() if cls is not Share}
        share = Share(skip=[b.download_root for b in fetch.values()])
        self.all = {name: share if cls is Share else fetch[name] for name, cls in BACKENDS.items()}

    @property
    def download_roots(self):
        return [b.download_root for b in self.all.values() if b.download_root]

    def of(self, job):
        return self.all[job.get("backend", "corpus")]

    def source_key(self, job):
        return f"{job.get('backend', 'corpus')}:{self.of(job).source_key(job)}"

    def download(self, job, files):
        return self.of(job).download(job, files)

    def progress(self, job):
        return self.of(job).progress(job)

    def locate(self, job, file):
        return self.of(job).locate(job, file)

    def cancel(self, job):
        return self.of(job).cancel(job)

    def forget(self, job):
        return self.of(job).forget(job)


def backend():
    return Backends()


# --------------------------------------------------------------------------
# State: results/<search>.json, jobs/<job>.json


def state_dir():
    d = os.environ.get("MEDIA_FETCH_STATE")
    if not d:
        d = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "media-fetch"
    return Path(d)


def staging_dir():
    return Path(os.environ.get("MEDIA_STAGING", "/srv/media/staging"))


def _write(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(obj, indent=1) + "\n")
    tmp.replace(path)


def load_candidate(cid):
    sid, _, n = cid.partition(".")
    p = state_dir() / "results" / f"{sid}.json"
    if not n.isdigit() or not p.is_file():
        raise FetchError(f"no candidate {cid}; run `media-fetch search` first")
    cands = json.loads(p.read_text())["candidates"]
    if not 1 <= int(n) <= len(cands):
        raise FetchError(f"no candidate {cid}: search {sid} has {len(cands)}")
    return cands[int(n) - 1]


def load_jobs(selectors=()):
    d = state_dir() / "jobs"
    jobs = [json.loads(p.read_text()) for p in sorted(d.glob("*.json"))] if d.is_dir() else []
    if selectors:
        jobs = [j for j in jobs if j["id"] in selectors or j["batch"] in selectors]
        if not jobs:
            raise FetchError(f"no job or batch {' '.join(selectors)}")
    return jobs


def save_job(job):
    _write(state_dir() / "jobs" / f"{job['id']}.json", job)


def per_source():
    v = os.environ.get("MEDIA_FETCH_PER_SOURCE", "1")
    if not v.isdigit() or int(v) < 1:
        raise FetchError(f"MEDIA_FETCH_PER_SOURCE={v!r}: want a whole number, 1 or more")
    return int(v)


# --------------------------------------------------------------------------
# Scheduling. A job's "pending" files are not yet asked for; "refused" ones
# ({name: reason}) could not be asked for. Both count as the job's own state
# over whatever the backend says of them.


def _merged(job, prog):
    prog = dict(prog)
    for n in job.get("pending", []):
        prog[n] = {"state": "queued", "bytes": 0}
    for n, why in job.get("refused", {}).items():
        prog[n] = {"state": "failed", "bytes": 0, "reason": why}
    return prog


class locked:
    """Every change to jobs/ holds this: the service, get, wait and cancel
    all write job files. Not reentrant."""

    def __enter__(self):
        d = state_dir()
        d.mkdir(parents=True, exist_ok=True)
        self.f = open(d / "lock", "w")
        fcntl.flock(self.f, fcntl.LOCK_EX)

    def __exit__(self, *exc):
        self.f.close()


def progress(be):
    """{job id: progress} of undelivered jobs, as they stand. Changes nothing."""
    return {j["id"]: _merged(j, be.progress(j)) for j in load_jobs() if not j.get("delivered")}


def advance(be, raise_for=None):
    """One round of the scheduler: ask for pending files, then deliver the
    jobs whose files have all arrived. {job id: progress} of the jobs still
    undelivered."""
    with locked():
        progs = _submit(be, raise_for)
        for j in load_jobs():
            if j["id"] in progs and job_summary(j, progs[j["id"]])["state"] == "done":
                deliver(be, j)
                del progs[j["id"]]
        return progs


def _submit(be, raise_for):
    """Ask for pending files, oldest job first, while their source has fewer
    than per_source() in flight. A refusal fails the job's pending files, or
    raises for job `raise_for`."""
    jobs = sorted((j for j in load_jobs() if not j.get("delivered")), key=lambda j: j["at"])
    raw = {j["id"]: be.progress(j) for j in jobs}
    busy = Counter()
    for j in jobs:
        held = set(j.get("pending", [])) | set(j.get("refused", {}))
        busy[be.source_key(j)] += sum(p["state"] in ("queued", "downloading")
                                      for n, p in raw[j["id"]].items() if n not in held)
    # A source that refused as busy is asked for nothing more of that job:
    # its other files fail unasked, so the job ends and another source can
    # be picked, instead of each file being refused in turn.
    for j in jobs:
        held = set(j.get("pending", [])) | set(j.get("refused", {}))
        busy_why = next((p["reason"] for n, p in raw[j["id"]].items()
                         if p.get("busy") and n not in held), None)
        if busy_why and j.get("pending"):
            j.setdefault("refused", {}).update(
                {n: f"not asked, the source is busy: {busy_why}" for n in j["pending"]})
            j["pending"] = []
            save_job(j)
    limit = per_source()
    for j in jobs:
        key = be.source_key(j)
        room = limit - busy[key]
        if room <= 0 or not j.get("pending"):
            continue
        names = j["pending"][:room]
        try:
            be.download(j, [f for f in j["files"] if f["name"] in names])
        except FetchError as e:
            if j["id"] == raise_for:
                raise
            j.setdefault("refused", {}).update({n: str(e) for n in j["pending"]})
            j["pending"] = []
            save_job(j)
            continue
        j["pending"] = j["pending"][room:]
        busy[key] += len(names)
        save_job(j)
        for n in names:
            raw[j["id"]][n] = {"state": "queued", "bytes": 0}
    return {j["id"]: _merged(j, raw[j["id"]]) for j in jobs}


# --------------------------------------------------------------------------
# Presentation


def public(obj):
    return {k: v for k, v in obj.items() if k not in ("source", "backend")}


def _size(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1000 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1000


def _dur(s):
    return f"{int(s) // 60}:{int(s) % 60:02d}"


def formats(files):
    by = {}
    for f in files:
        ext = f["name"].rpartition(".")[2].lower() if "." in f["name"] else "?"
        by.setdefault(ext, []).append(f)
    out = []
    for ext, fs in sorted(by.items(), key=lambda kv: -len(kv[1])):
        q = ""
        if fs[0].get("bitdepth") and fs[0].get("samplerate"):
            q = f" {fs[0]['bitdepth']}/{fs[0]['samplerate'] / 1000:g}"
        elif fs[0].get("bitrate"):
            q = f" {fs[0]['bitrate']}k"
        out.append(f"{len(fs)} {ext}{q}")
    return ", ".join(out)


def summarize(c):
    a = c["availability"]
    files = c["files"]
    c["size"] = sum(f["size"] for f in files)
    c["lossless"] = any(f["name"].rpartition(".")[2].lower() in LOSSLESS_EXT for f in files)
    c["formats"] = formats(files)
    c["ready"] = a["ready"]
    return c


def rank(c):
    a = c["availability"]
    return (not a["ready"], a["queue"], not c["lossless"], -a["speed"])


def job_summary(job, prog):
    counts = {s: 0 for s in STATES}
    for p in prog.values():
        counts[p["state"]] += 1
    n = len(job["files"])
    if job.get("delivered"):
        state = "delivered"
    elif counts["done"] == n:
        state = "done"
    elif counts["failed"] and not counts["queued"] and not counts["downloading"]:
        state = "failed"
    elif counts["downloading"] or counts["done"]:
        state = "downloading"
    else:
        state = "queued"
    total = sum(f["size"] for f in job["files"])
    got = sum(p["bytes"] for p in prog.values())
    return {"id": job["id"], "batch": job["batch"], "title": job["title"], "state": state,
            "files": n, **{k: v for k, v in counts.items() if v}, "bytes": got, "size": total,
            **({"delivered": job["delivered"]} if job.get("delivered") else {}),
            "failed_files": [k for k, p in prog.items() if p["state"] == "failed"],
            "failures": {k: p.get("reason", "") for k, p in prog.items() if p["state"] == "failed"}}


def with_eta(be, progs, selectors=()):
    """Summaries of the selected jobs, each still moving with "eta" (s). A
    source serves its jobs one after another, oldest first, so a job's
    estimate covers what is left of it and of the jobs before it there."""
    jobs = sorted(load_jobs(), key=lambda j: j["at"])
    sums = {j["id"]: job_summary(j, progs.get(j["id"], {})) for j in jobs}
    ahead = Counter()
    for j in jobs:
        s, prog = sums[j["id"]], progs.get(j["id"], {})
        if s["state"] not in ("queued", "downloading"):
            continue
        live = {n: p for n, p in prog.items() if p["state"] in ("queued", "downloading")}
        left = sum(f["size"] - live[f["name"]]["bytes"] for f in j["files"] if f["name"] in live)
        speed = sum(p.get("speed") or 0 for p in live.values()) or j.get("speed") or 0
        key = be.source_key(j)
        ahead[key] += left
        if speed:
            s["eta"] = round(ahead[key] / speed)
    return [sums[j["id"]] for j in load_jobs(selectors)] if selectors else list(sums.values())


def _eta(s):
    if s < 60:
        return "under a minute"
    m = round(s / 60)
    return f"~{m}m" if m < 60 else f"~{m // 60}h{m % 60:02d}m"


def print_job(s, brief=False):
    pct = f"{100 * s['bytes'] / s['size']:.0f}%" if s["size"] else ""
    line = f"{s['id']:<10} {s['state']:<11} {pct:>4}  {s['batch']}/{s['title']}"
    if "eta" in s:
        line += f"  ({_eta(s['eta'])} left)"
    print(line, flush=True)
    if brief:
        return
    if s["state"] == "failed":
        for name, why in s["failures"].items():
            print(f"{'':12}failed: {name}" + (f" ({why})" if why else ""))
    if s.get("delivered"):
        print(f"{'':12}in {s['delivered']}")


# --------------------------------------------------------------------------
# Commands


def cmd_search(a):
    be = backend()
    names = [n for n, (_, kinds) in TABLES.items() if kinds is None or a.kind in kinds]
    found, errors = {}, {}

    def run(name):
        try:
            b = be.all[name]
            found[name] = b.search(a.query, a.timeout, a.kind) if isinstance(b, Share) \
                else b.search(a.query, a.timeout)
        except FetchError as e:
            errors[name] = str(e)
    threads = [threading.Thread(target=run, args=(n,)) for n in names]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    ext_sets = lambda spec: {e.strip(".").lower() for e in spec.split(",")} if spec and spec != "all" else None
    exts = ext_sets(a.ext)
    sid = uuid.uuid4().hex[:6]
    tables, every = [], []
    for name in names:
        kept = []
        for c in found.get(name, []):
            if "where" in c:  # the media share: whatever it holds, in any format
                kept.append(summarize(c))
                continue
            keep = exts if a.ext else ext_sets(KIND_EXT.get(a.kind)) if name == "corpus" else None
            if keep:
                c["files"] = [f for f in c["files"] if f["name"].rpartition(".")[2].lower() in keep]
            if c.get("buy") or len(c["files"]) >= a.min_files:
                kept.append(summarize(c))
        if name != "share":  # the media share: in path order
            kept.sort(key=rank)
        for c in kept:
            every.append(c)
            c.update(id=f"{sid}.{len(every)}", backend=name, **{"from": TABLES[name][0]})
        tables.append({"name": TABLES[name][0], "total": len(kept), "candidates": kept,
                       **({"error": errors[name]} if name in errors else {})})
    if not every and len(errors) == len(names):
        raise FetchError("; ".join(f"{TABLES[n][0]}: {e}" for n, e in errors.items()))
    _write(state_dir() / "results" / f"{sid}.json",
           {"query": a.query, "kind": a.kind, "at": _now(), "candidates": every})
    for t in tables:
        t["shown"] = t["candidates"] if a.all else t["candidates"][:a.limit]
    if a.json:
        print(json.dumps({"search": sid, "query": a.query, "kind": a.kind, "tables": [
            {**{k: v for k, v in t.items() if k not in ("candidates", "shown")},
             "candidates": [public(c) for c in t["shown"]]} for t in tables]}, indent=1))
        return
    for i, t in enumerate(tables):
        print(("\n" if i else "") + t["name"])
        if "error" in t:
            print(f"  not searched: {t['error']}")
        elif not t["candidates"]:
            print(f"  nothing found for {a.query!r}")
        for c in t["shown"]:
            av = c["availability"]
            if "where" in c:  # the media share: where it is, not how to get it
                print(f"{c['id']:<10} {c['where']:<9} {len(c['files']):>3} files {_size(c['size']):>9}  "
                      f"{c['formats']:<18} {c['title']}")
            elif "price" in c:  # itch.io: what it costs, not how fast
                files = f"{len(c['files']):>3} files" if not c.get("buy") else "  ? files"
                print(f"{c['id']:<10} {c['price']:<9} {files} {_size(c['size']):>9}  "
                      f"{c['formats']:<18} {c['title']}" + (f" ({c['author']})" if c.get("author") else ""))
            else:
                avail = "ready" if av["ready"] else f"queue {av['queue']}"
                print(f"{c['id']:<10} {avail:<9} {av['speed'] / 1e6:5.1f} MB/s  {len(c['files']):>3} files "
                      f"{_size(c['size']):>9}  {c['formats']:<18} {c['title']}")
        if len(t["shown"]) < t["total"]:
            print(f"({t['total'] - len(t['shown'])} more: --all)")


def cmd_show(a):
    c = load_candidate(a.id)
    if a.json:
        print(json.dumps(public(c), indent=1))
        return
    print(f"{c['id']}  {c['title']}  ({c['formats']}, {_size(c['size'])})  [{c.get('from', 'corpus fetch')}]")
    if c.get("url"):
        print(f"      {c['price']}, {c['url']}")
    if c.get("path"):
        print(f"      {c['where']}, {c['path']}")
    for i, f in enumerate(c["files"], 1):
        dur = _dur(f["duration"]) if f.get("duration") else ""
        print(f"{i:>4}  {dur:>6} {_size(f['size']):>9}  {f['name']}")


def parse_picks(spec, n):
    picks = set()
    for part in spec.split(","):
        lo, _, hi = part.strip().partition("-")
        if not lo.isdigit() or (hi and not hi.isdigit()):
            raise FetchError(f"--files: {part!r} is not N or N-M")
        lo, hi = int(lo), int(hi or lo)
        if not 1 <= lo <= hi <= n:
            raise FetchError(f"--files: {part} is outside 1-{n}")
        picks.update(range(lo, hi + 1))
    return sorted(picks)


def check_batch(batch, be):
    if not batch or "/" in batch or batch.startswith(".") or batch != batch.strip():
        raise FetchError(f"--batch {batch!r}: one plain directory name")
    dest = (staging_dir() / batch).resolve()
    for root in be.download_roots:
        root = root.resolve()
        if dest == root or root in dest.parents:
            raise FetchError(f"--batch {batch}: that is a download directory, not a batch")
    if (staging_dir() / f"{batch}.manifest.jsonl").exists():
        raise FetchError(f"batch {batch} is already scanned; fetch into a new batch")


def cmd_get(a):
    be = backend()
    jobs = {j["id"]: j for j in load_jobs()}
    if a.id in jobs:
        job = jobs[a.id]
        if job.get("delivered"):
            raise FetchError(f"{a.id} is already delivered to {job['delivered']}")
        with locked():
            [job] = load_jobs([a.id])
            prog = _merged(job, be.progress(job))
            retry = [f["name"] for f in job["files"] if prog[f["name"]]["state"] == "failed"]
            if not retry:
                print(f"{a.id}: nothing to retry")
                return
            job["pending"] = job.get("pending", []) + retry
            job["refused"] = {n: r for n, r in job.get("refused", {}).items() if n not in retry}
            save_job(job)
        advance(be)
        print(f"{a.id}: retrying {len(retry)} file(s)")
        return
    if not a.batch:
        raise FetchError("--batch is required for a new download")
    check_batch(a.batch, be)
    c = load_candidate(a.id)
    if "where" in c:
        raise FetchError(f"{c['title']} is already on the media share ({c['where']}): {c['path']}")
    if c.get("buy"):
        raise FetchError(f"{c['title']} is {c['price']} on {c['from']} and not owned: "
                         f"buy it at {c['url']}, then search again")
    files = c["files"]
    if a.files:
        files = [files[i - 1] for i in parse_picks(a.files, len(files))]
    job = {"id": c["id"], "batch": a.batch, "title": _safe(c["title"]), "files": files,
           "backend": c.get("backend", "corpus"), "source": c["source"], "at": _now(), "pending": [f["name"] for f in files],
           "speed": c["availability"]["speed"]}
    save_job(job)
    try:
        progs = advance(be, raise_for=job["id"])
    except FetchError:
        (state_dir() / "jobs" / f"{job['id']}.json").unlink()
        raise
    [job] = load_jobs([job["id"]])
    [s] = with_eta(be, progs, [job["id"]])
    if "eta" in s:
        job["eta"] = s["eta"]
    if a.json:
        print(json.dumps(public(job), indent=1))
    else:
        eta = f", {_eta(s['eta'])}" if "eta" in s else ""
        print(f"{job['id']}: {len(files)} file(s), {_size(sum(f['size'] for f in files))}, "
              f"for {a.batch}/{job['title']}{eta}")


def cmd_status(a):
    be = backend()
    out = with_eta(be, progress(be), a.jobs)
    if a.json:
        print(json.dumps(out, indent=1))
        return
    if not out:
        print("no downloads")
    for s in out:
        print_job(s)


def deliver(be, job):
    dest = staging_dir() / job["batch"] / job["title"]
    moves = []
    for f in job["files"]:
        src = be.locate(job, f)
        if src is None:
            raise FetchError(f"{job['id']}: {f['name']} is done but cannot be found")
        to = dest / f["name"]
        if to.exists():
            raise FetchError(f"{job['id']}: {to} already exists")
        moves.append((src, to))
    dest.mkdir(parents=True, exist_ok=True)
    for src, to in moves:
        shutil.move(src, to)
    for src, _ in moves:  # the job's own folder, now empty
        try:
            src.parent.rmdir()
        except OSError:
            pass
    job["delivered"] = str(dest)
    save_job(job)
    be.forget(job)


def cmd_wait(a):
    be = backend()
    deadline = time.monotonic() + a.timeout if a.timeout is not None else None
    seen = {}
    while True:
        progs = advance(be)
        pending = False
        for j in load_jobs(a.jobs):
            if j.get("delivered"):
                continue
            if j["id"] not in progs:  # started since this round
                pending = True
            elif job_summary(j, progs[j["id"]])["state"] != "failed":
                pending = True
        if not a.json:  # a line whenever a job moves: what a background run shows
            for s in with_eta(be, progs, a.jobs):
                mark = (s["state"],) if s["state"] == "delivered" else \
                    (s["state"], s.get("done", 0), s.get("failed", 0))
                if seen.get(s["id"]) != mark:
                    seen[s["id"]] = mark
                    print_job(s, brief=True)
        if not pending or (deadline is not None and time.monotonic() >= deadline):
            break
        time.sleep(a.interval)
    out = with_eta(be, progress(be), a.jobs)
    if a.json:
        print(json.dumps(out, indent=1))
    else:
        print("--")
        for s in out:
            print_job(s)
    if any(s["state"] not in ("delivered",) for s in out):
        sys.exit(1)


def cmd_cancel(a):
    be = backend()
    with locked():
        for j in load_jobs(a.jobs):
            if not j.get("delivered"):
                be.cancel(j)
            (state_dir() / "jobs" / f"{j['id']}.json").unlink()
            print(f"{j['id']}: cancelled" if not j.get("delivered") else f"{j['id']}: forgotten")


def cmd_pump(a):
    be = backend()
    while True:
        before = {j["id"] for j in load_jobs() if not j.get("delivered")}
        try:
            advance(be)
        except FetchError as e:
            print(f"media-fetch: {e}", file=sys.stderr, flush=True)
        for j in load_jobs():
            if j["id"] in before and j.get("delivered"):
                print(f"{j['id']}: delivered to {j['delivered']}", flush=True)
        if a.every is None:
            return
        time.sleep(a.every)


def _safe(name):
    name = re.sub(r'[/\\:*?"<>|]', "_", name).strip(" .")
    return name or "untitled"


def _now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["_itch-fetch"]:  # Itch.download's worker
        return itch_fetch(json.loads(argv[1]))
    p = argparse.ArgumentParser(prog="media-fetch", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("search", help="find candidates")
    s.add_argument("query")
    s.add_argument("--kind", required=True, choices=KINDS,
                   help="what is sought; picks the places searched")
    s.add_argument("--ext", help="only these file types, e.g. flac,mp3 or epub,pdf; `all` for "
                   "every type. Default: corpus fetch keeps the kind's usual types, the rest all")
    s.add_argument("--min-files", type=int, default=1, help="drop smaller folders")
    s.add_argument("--timeout", type=float, default=20, help="seconds to collect results")
    s.add_argument("--limit", type=int, default=20, help="rows per table")
    s.add_argument("--all", action="store_true")
    s.set_defaults(fn=cmd_search)

    s = sub.add_parser("show", help="a candidate's files")
    s.add_argument("id")
    s.set_defaults(fn=cmd_show)

    s = sub.add_parser("get", help="download a candidate, or retry a job's failed files")
    s.add_argument("id")
    s.add_argument("--batch", help="STAGING/BATCH receives it")
    s.add_argument("--files", help="only these, numbered as `show` lists them: 1,3-5")
    s.set_defaults(fn=cmd_get)

    s = sub.add_parser("status", help="progress")
    s.add_argument("jobs", nargs="*", metavar="JOB|BATCH")
    s.set_defaults(fn=cmd_status)

    s = sub.add_parser("wait", help="wait for downloads, deliver them into their batch")
    s.add_argument("jobs", nargs="*", metavar="JOB|BATCH")
    s.add_argument("--timeout", type=float, help="give up after this many seconds (0: check once)")
    s.add_argument("--interval", type=float, default=5)
    s.set_defaults(fn=cmd_wait)

    s = sub.add_parser("cancel", help="stop downloads and forget them")
    s.add_argument("jobs", nargs="+", metavar="JOB|BATCH")
    s.set_defaults(fn=cmd_cancel)

    s = sub.add_parser("pump", help="ask for queued files, deliver finished jobs (the service)")
    s.add_argument("--every", type=float, help="keep going, a round every this many seconds")
    s.set_defaults(fn=cmd_pump)

    for s in sub.choices.values():
        s.add_argument("--json", action="store_true", help="machine-readable output")

    a = p.parse_args(argv)
    try:
        a.fn(a)
    except FetchError as e:
        sys.exit(f"media-fetch: {e}")


if __name__ == "__main__":
    main()
