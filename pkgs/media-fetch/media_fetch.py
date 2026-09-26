#!/usr/bin/env python3
"""media-fetch: find media on a download network and fetch it into staging.

  search QUERY               list candidates: one folder of files from one source
  show   ID                  a candidate's files, numbered
  get    ID --batch BATCH    download a candidate (or --files 1,3-5 of it)
  status [JOB|BATCH ...]     progress of each download
  wait   [JOB|BATCH ...]     block until downloads finish; deliver the finished ones
  cancel JOB|BATCH ...       stop downloads and forget them
  pump   [--every S]         ask for queued files, deliver finished jobs (the service)

A candidate is what a source offers in one folder: an album, a book, a
season. Its ID (`3fa2c1.4`: search, then rank) names it until the next
`search` is long forgotten; results are kept in the state directory. `get`
starts a job with the candidate's ID. `wait` delivers each job whose files
have all arrived into STAGING/BATCH/<title>/, the same batch directory
media-stage takes, and then `media-stage scan` (or, for music, `media-stage
group` and `beet stage-review`) takes over. A job that failed is left
undelivered; `get` with the same ID again retries the files that failed.

Nothing here names the network behind it. A Backend searches, downloads
into a directory of its own, reports progress and says where each finished
file is; the CLI, the IDs, the states (queued, downloading, done, failed)
and the JSON (--json on every command) are the same whatever it is. The one
backend today is slskd (Soulseek), chosen by MEDIA_FETCH_BACKEND.

A source is asked for at most MEDIA_FETCH_PER_SOURCE files at a time, across
all jobs; the rest of a job waits here, queued. `pump` asks for the next ones
as earlier ones finish and delivers finished jobs; on desk a service runs it
all the time (hosts/desk/soulseek.nix), and `get` and `wait` do the same
while they run, so nothing needs to be kept running. `wait` prints a line
whenever a job moves. `status`, `wait` and `get` estimate the time
left: what is left of the job and of the jobs ahead of it at its source,
at the source's measured speed (before a file starts: the speed it offered
in the search). Time spent in a source's own queue is not counted.

Environment:
  MEDIA_STAGING        batch directories' parent (default /srv/media/staging)
  MEDIA_FETCH_STATE    results and jobs (default $XDG_STATE_HOME/media-fetch)
  MEDIA_FETCH_BACKEND  slskd (default)
  MEDIA_FETCH_PER_SOURCE  files in flight per source (default 1)
  SLSKD_URL            default http://localhost:5030
  SLSKD_API_KEY        default: read from /etc/slskd/api.env
  SLSKD_DOWNLOADS      slskd's download directory (default
                       /srv/media/staging/soulseek, hosts/desk/soulseek.nix)
"""

import argparse
import datetime
import fcntl
import json
import os
import re
import shutil
import sys
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
        on a downloading one."""
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


class Slskd(Backend):
    def __init__(self):
        self.url = os.environ.get("SLSKD_URL", "http://localhost:5030").rstrip("/") + "/api/v0"
        self.key = os.environ.get("SLSKD_API_KEY") or self._key_from("/etc/slskd/api.env")
        self.download_root = Path(os.environ.get("SLSKD_DOWNLOADS", "/srv/media/staging/soulseek"))

    @staticmethod
    def _key_from(path):
        try:
            for line in Path(path).read_text().splitlines():
                k, _, v = line.partition("=")
                if k.strip() == "SLSKD_API_KEY":
                    return v.strip()
        except OSError as e:
            raise FetchError(f"no API key: SLSKD_API_KEY unset and {path}: {e.strerror}")
        raise FetchError(f"no SLSKD_API_KEY in {path}")

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


BACKENDS = {"slskd": Slskd}


def backend():
    name = os.environ.get("MEDIA_FETCH_BACKEND", "slskd")
    if name not in BACKENDS:
        raise FetchError(f"unknown MEDIA_FETCH_BACKEND {name!r}; one of {', '.join(BACKENDS)}")
    return BACKENDS[name]()


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
    return {k: v for k, v in obj.items() if k != "source"}


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
    cands = backend().search(a.query, a.timeout)
    exts = {e.strip(".").lower() for e in a.ext.split(",")} if a.ext else None
    kept = []
    for c in cands:
        if exts:
            c["files"] = [f for f in c["files"] if f["name"].rpartition(".")[2].lower() in exts]
        if len(c["files"]) >= a.min_files:
            kept.append(summarize(c))
    kept.sort(key=rank)
    sid = uuid.uuid4().hex[:6]
    for i, c in enumerate(kept, 1):
        c["id"] = f"{sid}.{i}"
    _write(state_dir() / "results" / f"{sid}.json",
           {"query": a.query, "at": _now(), "candidates": kept})
    shown = kept if a.all else kept[:a.limit]
    if a.json:
        print(json.dumps({"search": sid, "query": a.query, "total": len(kept),
                          "candidates": [public(c) for c in shown]}, indent=1))
        return
    if not kept:
        print(f"nothing found for {a.query!r}")
        return
    for c in shown:
        av = c["availability"]
        avail = "ready" if av["ready"] else f"queue {av['queue']}"
        print(f"{c['id']:<9} {avail:<9} {av['speed'] / 1e6:5.1f} MB/s  {len(c['files']):>3} files "
              f"{_size(c['size']):>9}  {c['formats']:<18} {c['title']}")
    if len(shown) < len(kept):
        print(f"({len(kept) - len(shown)} more: --all)")


def cmd_show(a):
    c = load_candidate(a.id)
    if a.json:
        print(json.dumps(public(c), indent=1))
        return
    print(f"{c['id']}  {c['title']}  ({c['formats']}, {_size(c['size'])})")
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
    root = be.download_root.resolve()
    if dest == root or root in dest.parents:
        raise FetchError(f"--batch {batch}: that is the download directory, not a batch")
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
    files = c["files"]
    if a.files:
        files = [files[i - 1] for i in parse_picks(a.files, len(files))]
    job = {"id": c["id"], "batch": a.batch, "title": _safe(c["title"]), "files": files,
           "source": c["source"], "at": _now(), "pending": [f["name"] for f in files],
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
            raise FetchError(f"{job['id']}: {f['name']} is done but not in {be.download_root}")
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
    p = argparse.ArgumentParser(prog="media-fetch", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("search", help="find candidates")
    s.add_argument("query")
    s.add_argument("--ext", help="only these file types, e.g. flac,mp3 or epub,pdf")
    s.add_argument("--min-files", type=int, default=1, help="drop smaller folders")
    s.add_argument("--timeout", type=float, default=20, help="seconds to collect results")
    s.add_argument("--limit", type=int, default=20)
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
