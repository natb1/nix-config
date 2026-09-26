"""stagereview: beets without the prompts, for media-stage batches.

  beet stage-review STAGING/audio                   # import, recording what needs a person
  beet stage-review --answers DIR STAGING/audio     # apply the recorded answers
  beet stage-audit STAGING/audio                    # check what was filed against the originals
  beet stage-audit --answers DIR STAGING/audio      # apply the audit's answers

STAGING/audio holds one directory per album (`media-stage group` makes them,
by the files' own tags). Each directory is imported by itself: beets never
joins "… CD1" and "… CD2" folders on its own.

stage-review imports every album whose MusicBrainz match is strong, as
`beet import -q` would, and records every other album, with its candidates,
in STAGING/audio.review.json, leaving it in staging. An album goes to the
review page instead of the library when:

- beets' match is not strong (a candidate is "Suggested" only from 60%);
- its files are the same recordings as tracks already filed (Chromaprint
  fingerprints, not names), or it has the name of an album already filed;
- `media-stage group` made it from more than one folder;
- a file's name disagrees with its own tags (another track, another number).

The review page (docs/desktop-migration.md, "Filing a batch") shows each and
stores the answers; --answers reads them back — exported JSON documents
anywhere under DIR — and imports each answered album: a chosen release by
its id, hand-entered tags as-is (written to the files), or not at all.

stage-audit then compares every file filed from the batch with what it was
before beets renamed it, from STAGING/audio.manifest.jsonl (media-stage
scan): a real length that doesn't fit its slot on the release, or a new title
that names another number than the old one ("No. 3" filed as "No. 5"), goes
to STAGING/audio.audit.review.json for the same page, as batch
"<batch>-audit". It writes STAGING/audio.audit.json; `media-stage close`
removes the batch's records only once that says passed.

The review file's shape is shared with `media-stage review export`, so one
page reviews both.
"""

import datetime
import hashlib
import json
import os
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from beets import config, ui
from beets.autotag.match import Recommendation
from beets.importer.actions import Action, DuplicateAction
from beets.plugins import BeetsPlugin
from beets.ui.commands.import_.session import TerminalImportSession
from beets.util import MoveOperation, displayable_path

from beetsplug.stagecheck import (SAME_RECORDING, fingerprint, from_name, length_off, mmss,
                                  name_conflict, number_clash, pack, similarity, track_no, unpack)

AUDIO_EXT = (".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wav", ".aif", ".aiff", ".wma", ".alac")


def item_id(key):
    return hashlib.sha1(key.encode()).hexdigest()[:12]


def sidecar(staging, suffix):
    return Path(staging.rstrip("/") + suffix)


def load_json(path, default):
    return json.loads(path.read_text()) if path.exists() else default


def load_answers(where, batch):
    """Every answer document under `where` (a file or a directory of
    exported documents), keyed by item id. Tolerates a document wrapped in
    {"data": ...}, as an export may write it."""
    paths = [Path(where)] if Path(where).is_file() else sorted(Path(where).rglob("*.json"))
    out = {}
    for p in paths:
        doc = json.loads(p.read_text())
        docs = doc if isinstance(doc, list) else [doc]
        for d in docs:
            d = d.get("data", d) if isinstance(d.get("data"), dict) else d
            if d.get("batch") == batch and d.get("item") and d.get("choice"):
                out[d["item"]] = d
    return out


def write_review(path, batch, source, items):
    path.write_text(json.dumps({
        "batch": batch, "kind": "audio", "source": source,
        "created": datetime.datetime.now().isoformat(timespec="seconds"),
        "items": items,
    }, indent=1, ensure_ascii=False))


class Fingerprints:
    """Which library tracks are the same recording as a staged file. Library
    fingerprints are computed once, for tracks of a near length, and kept
    on the item (the flexible field `stage_fp`)."""

    def __init__(self, lib):
        self.lib = lib
        self.library = [(i, i.length or 0) for i in lib.items()]
        self.staged = {}

    def of_library(self, items):
        todo = [i for i in items if not i.get("stage_fp")]
        # Paths resolved here: beets resolves a library item's path against
        # the library directory in a context its worker threads don't share.
        with ThreadPoolExecutor(8) as ex:
            for i, fp in zip(todo, ex.map(fingerprint, [i.path for i in todo])):
                if fp:
                    i["stage_fp"] = pack(fp)
                    i.store()
        return {i.id: unpack(i["stage_fp"]) for i in items if i.get("stage_fp")}

    def same_recordings(self, items):
        """{staged item path: (library item, similarity)} for each staged
        file that is the same recording as a filed track."""
        with ThreadPoolExecutor(8) as ex:
            for i, fp in zip(items, ex.map(fingerprint, [i.path for i in items])):
                self.staged[i.path] = fp
        out = {}
        for i in items:
            fp = self.staged.get(i.path)
            if not fp:
                continue
            near = [li for li, ln in self.library if abs(ln - (i.length or 0)) <= 10]
            fps = self.of_library(near)
            best = max(((li, similarity(fp, fps[li.id])) for li in near if li.id in fps),
                       key=lambda x: x[1], default=(None, 0))
            if best[1] >= SAME_RECORDING:
                out[i.path] = best
        return out


class StageSession(TerminalImportSession):
    def __init__(self, lib, loghandler, paths, query, staging, answers=None):
        super().__init__(lib, loghandler, paths, query)
        self.staging = staging
        self.source_batch = os.path.basename(staging)
        self.answers = answers
        self.review = []  # albums for a person
        self.dupmode = {}  # answers: folder -> dup:merge/remove/keep chosen
        self.merging = set()  # folders whose merged task is on its way back
        self.grouped = load_json(sidecar(staging, ".group.json"), {})
        self.fingerprints = None if answers is not None else Fingerprints(lib)
        review = sidecar(staging, ".review.json")
        self.review_items = ({i["id"]: i for i in json.loads(review.read_text())["items"]}
                             if answers is not None and review.exists() else {})

    # -- helpers

    def key(self, task):
        return os.path.relpath(displayable_path(task.paths[0]), self.staging)

    def stamp(self, task):
        """Where each file came from, kept on the library item: the audit
        reads it back to find the file's record in the manifest."""
        for i in task.items:
            p = displayable_path(i.path)
            if p.startswith(self.staging + os.sep):
                i["stage_source"] = f"{self.source_batch}/{os.path.relpath(p, self.staging)}"

    def record(self, task, why, options, twin=None, evidence=()):
        key = self.key(task)
        items = sorted(task.items, key=lambda i: (i.disc or 0, i.track or 0, displayable_path(i.path)))
        guess = next((g for g in (from_name(os.path.basename(displayable_path(i.path))) for i in items) if g), {})
        first = items[0]
        artist = first.albumartist or first.artist or guess.get("artist", "")
        album = first.album or guess.get("album", "")
        tagged = sum(1 for i in items if i.title and i.artist and i.album)
        merged = (self.grouped.get(key) or {}).get("from") or []
        self.review.append({
            "id": item_id(key),
            "key": key,
            "kind": "album",
            "title": f"{artist or 'Unknown artist'} – {album or key}",
            "subtitle": f"{len(items)} tracks · {tagged} tagged" +
                        (f" · made from {len(merged)} folders" if len(merged) > 1 else ""),
            "why": why,
            "evidence": [
                {"label": "Folder", "value": key},
                *([{"label": "Grouped from", "value": "\n".join(merged)}] if len(merged) > 1 else []),
                {"label": "Tags now", "value": f"album artist {first.albumartist or '—'}; artist {first.artist or '—'}; "
                                               f"album {first.album or '—'}; year {first.year or '—'}"},
                {"label": "Tracks", "value": "\n".join(
                    f"{i.track or '?':>2}  {i.title or os.path.basename(displayable_path(i.path))}"
                    f"  ({mmss(i.length)})" for i in items)},
                *evidence,
            ],
            "options": options,
            "custom": {"kind": "fields", "label": "Tag it by hand (as-is)", "fields": [
                {"key": "albumartist", "label": "Album artist", "value": artist},
                {"key": "album", "label": "Album", "value": album},
                {"key": "year", "label": "Year", "value": str(first.year or "")},
            ]},
            "twin": twin,
        })

    @staticmethod
    def candidate(m, best=False):
        score = round(100 * (1 - float(m.distance)))
        i = m.info
        bits = [b for b in (i.label, i.country, i.media, str(i.year or "") or None,
                            f"{len(i.tracks)} tracks", i.albumdisambig) if b]
        missing, extra = len(m.extra_tracks), len(m.extra_items)
        if missing:
            bits.append(f"{missing} tracks not here")
        if extra:
            bits.append(f"{extra} files unmatched — they would stay in staging")
        return {
            "value": f"mb:{i.album_id}",
            "label": f"{i.artist} – {i.album}" + (f" ({i.year})" if i.year else ""),
            "detail": " · ".join(bits),
            "score": score,
            "url": i.data_url or f"https://musicbrainz.org/release/{i.album_id}",
            # Only a match worth accepting unread is "Suggested": the page's
            # "accept every suggestion" takes these.
            "recommended": best and score >= 60,
        }

    # -- an album already in the library
    #
    # Applying a release imports only the files that match its tracks: files
    # MusicBrainz does not list (a suite's movements it counts as one track)
    # stay in staging, and so does a second copy of an album already filed.
    # Both come back here as an album that has a twin in the library, and the
    # person decides: add these files to it, replace it, keep both, or not.

    TWIN_FIELDS = ("albumartist", "album", "year", "mb_albumid", "mb_albumartistid",
                   "mb_releasegroupid", "albumtype", "label", "comp", "disctotal")

    def twin(self, task):
        first = task.items[0]
        best = task.candidates[0].info.album_id if task.candidates else None
        for a in self.lib.albums():
            if best and a.mb_albumid == best:
                return a
            if first.album and (a.album or "").casefold() == first.album.casefold():
                return a
        return None

    def dup_options(self, twin, here, all_filed=False):
        there = len(list(twin.items()))
        name = f"{twin.albumartist} – {twin.album}" + (f" ({twin.year})" if twin.year else "")
        return [
            {"value": "dup:merge", "label": f"Add these files to {name}",
             "detail": f"{there} tracks there + {here} here, filed as one album with its tags"},
            {"value": "dup:remove", "label": "Replace the library copy with this one",
             "detail": f"the {there} tracks there are deleted; these {here} are filed with its tags"},
            {"value": "dup:keep", "label": "Keep both", "detail": "filed as a second album of the same name"},
            {"value": "dup:skip", "label": "Keep only the library copy",
             "detail": "this one stays in staging" + (" — every file here is already filed" if all_filed else ""),
             "recommended": all_filed},
        ]

    # -- decisions beets would have prompted for

    def choose_match(self, task):
        self.stamp(task)
        if self.answers is not None:
            return self.answered(task)
        n = len(task.items)
        cands = [self.candidate(m, i == 0) for i, m in enumerate(task.candidates[:5])]

        same = self.fingerprints.same_recordings(task.items)
        if same:
            twin = self.lib.get_album(Counter(li.album_id for li, _ in same.values()).most_common(1)[0][0])
            lines = [f"{os.path.basename(displayable_path(p))}  =  {li.track} {li.title} "
                     f"({li.album}, {round(100 * s)}%)" for p, (li, s) in sorted(same.items())]
            for c in cands:
                c["recommended"] = False
            self.record(task, f"same recordings as {len(same)} of these {n} files already filed",
                        self.dup_options(twin, n, all_filed=len(same) == n) + cands, twin=twin.id,
                        evidence=[{"label": "Already filed (fingerprint)", "value": "\n".join(lines)}])
            return Action.SKIP

        twin = self.twin(task)
        if twin:
            for c in cands:
                c["recommended"] = False
            there = len(list(twin.items()))
            self.record(task, f"like an album already filed ({there} tracks there, {n} here)",
                        self.dup_options(twin, n) + cands, twin=twin.id)
            return Action.SKIP

        reasons, evidence = [], []
        merged = (self.grouped.get(self.key(task)) or {}).get("from") or []
        if len(merged) > 1:
            reasons.append(f"made from {len(merged)} folders")
        conflicts = [(i, name_conflict(os.path.basename(displayable_path(i.path)),
                                       {"track": i.track, "title": i.title})) for i in task.items]
        conflicts = [(i, c) for i, c in conflicts if c]
        if conflicts:
            reasons.append(f"{len(conflicts)} file names disagree with their tags")
            evidence.append({"label": "Name vs tags", "value": "\n".join(
                f"{os.path.basename(displayable_path(i.path))}: {c}" for i, c in conflicts)})

        if task.rec == Recommendation.strong and task.candidates and not reasons:
            return task.candidates[0]
        if task.rec == Recommendation.strong and task.candidates:
            why = f"strong match ({cands[0]['score']}%), but " + "; ".join(reasons)
        else:
            why = {Recommendation.none: "no match beets would accept",
                   Recommendation.low: "weak match",
                   Recommendation.medium: "close match"}.get(task.rec, "needs a look")
            why += f" (best {cands[0]['score']}%)" if cands else ": nothing found"
            why = "; ".join([why] + reasons)
        self.record(task, why, cands, evidence=evidence)
        return Action.SKIP

    def answered(self, task):
        key = self.key(task)
        if key in self.merging:     # the merged task beets builds for dup:merge
            return Action.RETAG
        a = self.answers.get(item_id(key))
        if not a or a["choice"] == "skip":
            return Action.SKIP
        value = a.get("value", "")
        if value in ("dup:merge", "dup:remove", "dup:keep"):
            twin = self.lib.get_album((self.review_items.get(item_id(key)) or {}).get("twin") or 0)
            if not twin:
                ui.print_(f"stagereview: {key}: the library album to join is gone; left in staging")
                return Action.SKIP
            for i in task.items:
                for f in self.TWIN_FIELDS:
                    if twin.get(f) is not None:
                        setattr(i, f, twin.get(f))
                i.artist = i.artist or twin.albumartist
                guess = from_name(os.path.basename(displayable_path(i.path)))
                i.title = i.title or guess.get("title", "")
                i.track = i.track or track_no(guess.get("track")) or 0
            self.dupmode[key] = value
            task.__dict__.pop("source", None)  # cached from the old tags; the duplicate check reads it
            return Action.RETAG
        if value == "dup:skip":
            return Action.SKIP
        if a["choice"] == "custom":
            f = a.get("fields") or {}
            for i in task.items:
                guess = from_name(os.path.basename(displayable_path(i.path)))
                i.albumartist = f.get("albumartist") or i.albumartist
                i.artist = i.artist or i.albumartist
                i.album = f.get("album") or i.album
                if str(f.get("year", "")).isdigit():
                    i.year = int(f["year"])
                i.title = i.title or guess.get("title", "")
                i.track = i.track or track_no(guess.get("track")) or 0
            task.__dict__.pop("source", None)
            return Action.RETAG
        if value.startswith("mb:"):
            task.lookup_candidates([value[3:]])
            if task.candidates:
                return task.candidates[0]
        ui.print_(f"stagereview: {self.key(task)}: answer {a.get('value')!r} gave no match; left in staging")
        return Action.SKIP

    def get_duplicate_action(self, task, found_duplicates):
        key = self.key(task)
        if self.answers is not None:
            # A chosen release can meet an album already filed under its
            # name; the answer may say "on_duplicate": "remove" (replace the
            # library copy) or "keep" (both). Otherwise the new one waits.
            a = self.answers.get(item_id(key)) or {}
            mode = self.dupmode.get(key) or {"remove": "dup:remove", "keep": "dup:keep"}.get(a.get("on_duplicate"))
            if mode == "dup:merge":
                self.merging.add(key)
                return DuplicateAction.MERGE
            return {"dup:keep": DuplicateAction.KEEP, "dup:remove": DuplicateAction.REMOVE}.get(
                mode, DuplicateAction.SKIP)
        twin = found_duplicates[0]
        self.record(task, f"already in the library ({len(list(twin.items()))} tracks there, {len(task.items)} here)",
                    self.dup_options(twin, len(task.items)), twin=twin.id)
        return DuplicateAction.SKIP

    def should_resume(self, path):
        return False

    def choose_item(self, task):
        return Action.SKIP  # singletons are never staged


# --------------------------------------------------------------------------
# stage-audit: what was filed, against what each file was.

def audit_items(lib, staging):
    batch = os.path.basename(staging)
    return [i for i in lib.items() if (i.get("stage_source") or "").startswith(batch + "/")]


def audit(lib, staging):
    """Flag every track filed from the batch whose original doesn't fit
    where it was filed. Returns the review items, the originals still in
    staging, and those neither filed nor in staging."""
    recs = {}
    manifest = sidecar(staging, ".manifest.jsonl")
    if not manifest.exists():
        raise ui.UserError(f"{manifest}: gone — nothing to audit against (rescan the originals if you still have them)")
    for line in manifest.read_text().splitlines():
        if line.strip():
            r = json.loads(line)
            if r.get("kind") == "audio":
                recs[r["path"]] = r
    filed = audit_items(lib, staging)
    review, seen = [], set()
    for i in sorted(filed, key=lambda i: (i.albumartist, i.album, i.disc or 0, i.track or 0)):
        rel = i["stage_source"].split("/", 1)[1]
        seen.add(rel)
        rec = recs.get(rel)
        if not rec or i.get("stage_audit") == "ok":
            continue
        meta = rec.get("meta") or {}
        tags, real = meta.get("tags") or {}, meta.get("duration") or 0
        name = os.path.basename(rel)
        original = tags.get("title") or from_name(name).get("title", "")
        flags = []
        off = length_off(real, i.length)
        if off:
            flags.append(f"the file is {mmss(real)}, its slot {mmss(i.length)}")
        clash = number_clash(original, i.title)
        if clash:
            flags.append(f"was “{original}”: {clash}")
        if not flags:
            continue
        album = i.get_album()
        siblings = sorted(album.items() if album else [i], key=lambda x: (x.disc or 0, x.track or 0))
        slots = {f"{s.disc or 1}-{s.track}": {"disc": s.disc or 1, "track": s.track, "title": s.title,
                                              "mb_trackid": s.mb_trackid or "", "length": s.length}
                 for s in siblings}
        fits = [s for s in siblings if s.id != i.id and not length_off(real, s.length)
                and not number_clash(original, s.title)]
        options = [{"value": "audit:ok", "label": "It's right as filed",
                    "detail": f"{i.track} {i.title}"}]
        for s in fits[:3]:
            options.append({"value": f"audit:slot:{s.disc or 1}-{s.track}",
                            "label": f"It's track {s.track}: {s.title}",
                            "detail": f"that slot is {mmss(s.length)}; the file now there gets its own check",
                            "recommended": len(fits) == 1})
        if original and original != i.title:
            options.append({"value": "audit:original", "label": f"Title it as the original did: {original}",
                            "detail": f"stays track {i.track}"})
        conflict = name_conflict(name, tags)
        review.append({
            "id": item_id(i["stage_source"]),
            "key": i["stage_source"],
            "kind": "track",
            "title": f"{i.track} {i.title}",
            "subtitle": f"{i.albumartist} – {i.album}" + (f" ({i.year})" if i.year else ""),
            "why": "; ".join(flags),
            "evidence": [
                {"label": "Original file", "value": rel},
                {"label": "Its tags", "value": f"track {tags.get('track', '—')}; title {tags.get('title', '—')}; "
                                               f"album {tags.get('album', '—')}"},
                *([{"label": "Name vs tags", "value": conflict}] if conflict else []),
                {"label": "Its length", "value": mmss(real)},
                {"label": "The release", "value": "\n".join(
                    f"{'→' if s.id == i.id else ' '} {s.track:>2}  {s.title}  ({mmss(s.length)})"
                    + ("  ← fits" if s in fits else "") for s in siblings)},
                {"label": "Filed as", "value": os.path.relpath(displayable_path(i.path),
                                                               displayable_path(lib.directory))},
            ],
            "options": options,
            "custom": {"kind": "fields", "label": "Retitle or re-slot by hand", "fields": [
                {"key": "track", "label": "Track", "value": str(i.track)},
                {"key": "title", "label": "Title", "value": i.title},
            ]},
            "skip_label": "Decide later",
            "skip_detail": "The audit keeps flagging it, and the batch's records stay.",
            "original_title": original,
            "slots": slots,
        })
    on_disk = {os.path.relpath(os.path.join(d, f), staging)
               for d, _, fs in os.walk(staging) for f in fs if f.lower().endswith(AUDIO_EXT)}
    left = sorted(r for r in recs if r in on_disk)
    lost = sorted(r for r in recs if r not in on_disk and r not in seen)
    return review, left, lost


def apply_audit_answers(lib, staging, answers, review):
    by_id = {r["id"]: r for r in review}
    items = {item_id(i["stage_source"]): i for i in audit_items(lib, staging)}
    changes = []
    for iid, a in answers.items():
        i, r = items.get(iid), by_id.get(iid)
        if not i or not r or a["choice"] == "skip":
            continue
        value, f = a.get("value", ""), {}
        if value == "audit:original":
            f = {"title": r["original_title"]}
        elif value.startswith("audit:slot:"):
            s = r["slots"][value[len("audit:slot:"):]]
            f = {k: s[k] for k in ("disc", "track", "title", "mb_trackid", "length")}
        elif a["choice"] == "custom":
            fields = a.get("fields") or {}
            if track_no(fields.get("track")):
                f["track"] = track_no(fields["track"])
            if (fields.get("title") or "").strip():
                f["title"] = fields["title"].strip()
            if f.get("title", i.title) != i.title:
                f["mb_trackid"] = ""
        i["stage_audit"] = "ok"
        if not f:
            i.store()
            continue
        changes.append((i, f))
    # Two phases, so no file moves onto a name another still holds (a swap).
    for i, _ in changes:
        src = displayable_path(i.path)
        tmp = os.path.join(os.path.dirname(src), f".stage-audit-{i.id}{os.path.splitext(src)[1]}")
        os.rename(src, tmp)
        i.path = os.fsencode(tmp)
        i.store()
    for i, f in changes:
        for k, v in f.items():
            i[k] = v
        i.store()
        i.try_write()
        i.move(MoveOperation.MOVE)
        ui.print_(f"  {i.track:>2} {i.title}  ->  {displayable_path(i.path)}")
    return len(changes)


class StageReview(BeetsPlugin):
    def commands(self):
        cmd = ui.Subcommand("stage-review", help="import a staged audio batch without prompts; record the rest for review")
        cmd.parser.add_option("--answers", help="apply the answers exported to this file or directory")
        cmd.parser.add_option("--batch", help="batch name in the review (default: the directory's name)")
        cmd.func = self.run
        aud = ui.Subcommand("stage-audit", help="check the tracks filed from a staged batch against their originals")
        aud.parser.add_option("--answers", help="apply the audit answers exported to this file or directory")
        aud.func = self.run_audit
        return [cmd, aud]

    def run(self, lib, opts, args):
        if len(args) != 1:
            raise ui.UserError("usage: beet stage-review [--answers DIR] STAGING/<batch>")
        staging = os.path.abspath(args[0])
        batch = opts.batch or os.path.basename(staging)
        answers = load_answers(opts.answers, batch) if opts.answers else None
        loose = [f for f in os.listdir(staging) if f.lower().endswith(AUDIO_EXT)]
        if loose:
            raise ui.UserError(f"{len(loose)} audio files directly in {staging}: run `media-stage group` first")
        # One import path per album folder: beets joins sibling folders named
        # like discs only while walking a tree, so it never does here.
        # `media-stage group` made the albums, from the files' own tags.
        paths = sorted(os.path.join(staging, d) for d in os.listdir(staging)
                       if not d.startswith(".") and os.path.isdir(os.path.join(staging, d)))
        config["import"]["quiet"] = False
        config["import"]["timid"] = False
        config["import"]["resume"] = False
        config["import"]["group_albums"] = False
        session = StageSession(lib, None, [os.fsencode(p) for p in paths], None, staging, answers)
        session.run()
        left = [p for p in paths if any(f.lower().endswith(AUDIO_EXT) for _, _, fs in os.walk(p) for f in fs)]
        if answers is None:
            out = sidecar(staging, ".review.json")
            write_review(out, batch, "beets", session.review)
            ui.print_(f"for review: {len(session.review)} albums -> {out}")
        ui.print_(f"left in staging: {len(left)} album folders")
        ui.print_(f"next, once nothing else is to be imported: beet stage-audit {staging}")

    def run_audit(self, lib, opts, args):
        if len(args) != 1:
            raise ui.UserError("usage: beet stage-audit [--answers DIR] STAGING/<batch>")
        staging = os.path.abspath(args[0])
        batch = os.path.basename(staging) + "-audit"
        out = sidecar(staging, ".audit.review.json")
        if opts.answers:
            review = load_json(out, {}).get("items", [])
            n = apply_audit_answers(lib, staging, load_answers(opts.answers, batch), review)
            ui.print_(f"audit answers applied: {n} tracks changed")
        review, left, lost = audit(lib, staging)
        filed = len(audit_items(lib, staging))
        write_review(out, batch, "beets-audit", review)
        state = {"checked": datetime.datetime.now().isoformat(timespec="seconds"), "filed": filed,
                 "flagged": len(review), "left_in_staging": left, "not_found": lost,
                 "passed": None if review else datetime.date.today().isoformat()}
        sidecar(staging, ".audit.json").write_text(json.dumps(state, indent=1, ensure_ascii=False))
        ui.print_(f"audited {filed} tracks filed from {os.path.basename(staging)}: {len(review)} flagged"
                  + (f" -> {out} (review batch {batch})" if review else " — passed"))
        for r in review:
            ui.print_(f"  {r['subtitle']}: {r['title']} — {r['why']}")
        if left:
            ui.print_(f"still in staging: {len(left)} files — another round of stage-review, or leave them")
        if lost:
            ui.print_(f"neither filed nor in staging: {len(lost)} files")
            for r in lost[:20]:
                ui.print_(f"  {r}")
