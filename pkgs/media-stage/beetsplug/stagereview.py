"""stagereview: beets without the prompts, for media-stage batches.

  beet stage-review STAGING/audio            # import, recording what needs a person
  beet stage-review --answers DIR STAGING/audio   # apply the recorded answers

STAGING/audio holds one directory per album (`media-stage group` makes them).
The first form imports every album whose MusicBrainz match is strong, as
`beet import -q` would, and records every other album, with its candidates,
in STAGING/audio.review.json, leaving it in staging. An album that would
duplicate one already in the library is recorded too, not imported. The
review page (docs/desktop-migration.md, "Filing a batch") shows the file and
stores the answers; the second form reads them back — exported JSON documents
anywhere under DIR — and imports each answered album: a chosen release by
its id, hand-entered tags as-is (written to the files), or not at all.

The review file's shape is shared with `media-stage review export`, so one
page reviews both.
"""

import datetime
import hashlib
import json
import os
import re
from pathlib import Path

from beets import config, importer, ui
from beets.autotag.match import Recommendation
from beets.importer.actions import Action, DuplicateAction
from beets.plugins import BeetsPlugin
from beets.ui.commands.import_.session import TerminalImportSession
from beets.util import displayable_path

# "Artist - Album - 04 Title.mp3", "Artist - Album (2000) - 04 - Title.mp3"
NAME = re.compile(r"^(?P<artist>.+?) - (?P<album>.+) - (?P<track>\d{1,3})(?: - |\.? )(?P<title>.+)\.[^.]+$")


def item_id(key):
    return hashlib.sha1(key.encode()).hexdigest()[:12]


def from_name(path):
    m = NAME.match(os.path.basename(displayable_path(path)))
    return m.groupdict() if m else {}


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


class StageSession(TerminalImportSession):
    def __init__(self, lib, loghandler, paths, query, staging, answers=None):
        super().__init__(lib, loghandler, paths, query)
        self.staging = staging
        self.answers = answers
        self.review = []  # albums for a person
        self.dupmode = {}  # answers: folder -> dup:merge/remove/keep chosen
        self.merging = set()  # folders whose merged task is on its way back
        review = Path(staging.rstrip("/") + ".review.json")
        self.review_items = ({i["id"]: i for i in json.loads(review.read_text())["items"]}
                             if answers is not None and review.exists() else {})

    # -- helpers

    def key(self, task):
        return os.path.relpath(displayable_path(task.paths[0]), self.staging)

    def record(self, task, why, options, twin=None):
        key = self.key(task)
        items = sorted(task.items, key=lambda i: (i.disc or 0, i.track or 0, displayable_path(i.path)))
        guess = next((g for g in (from_name(i.path) for i in items) if g), {})
        first = items[0]
        artist = first.albumartist or first.artist or guess.get("artist", "")
        album = first.album or guess.get("album", "")
        tagged = sum(1 for i in items if i.title and i.artist and i.album)
        # beets merges sibling folders that differ only by a disc marker
        # ("… CD1", "… CD2") into one album; say so, since it can be wrong.
        folders = [os.path.relpath(displayable_path(p), self.staging) for p in task.paths]
        self.review.append({
            "id": item_id(key),
            "key": key,
            "kind": "album",
            "title": f"{artist or 'Unknown artist'} – {album or key}",
            "subtitle": f"{len(items)} tracks · {tagged} tagged" +
                        (f" · {len(folders)} folders taken as one multi-disc album" if len(folders) > 1 else ""),
            "why": why,
            "folders": folders,
            "evidence": [
                {"label": "Folders" if len(folders) > 1 else "Folder", "value": "\n".join(folders)},
                {"label": "Tags now", "value": f"album artist {first.albumartist or '—'}; artist {first.artist or '—'}; "
                                               f"album {first.album or '—'}; year {first.year or '—'}"},
                {"label": "Tracks", "value": "\n".join(
                    f"{i.track or '?':>2}  {i.title or os.path.basename(displayable_path(i.path))}"
                    f"  ({int(i.length // 60)}:{int(i.length % 60):02d})" for i in items)},
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
            bits.append(f"{extra} files unmatched")
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

    def dup_options(self, twin, here):
        there = len(list(twin.items()))
        name = f"{twin.albumartist} – {twin.album}" + (f" ({twin.year})" if twin.year else "")
        return [
            {"value": "dup:merge", "label": f"Add these files to {name}",
             "detail": f"{there} tracks there + {here} here, filed as one album with its tags"},
            {"value": "dup:remove", "label": "Replace the library copy with this one",
             "detail": f"the {there} tracks there are deleted; these {here} are filed with its tags"},
            {"value": "dup:keep", "label": "Keep both", "detail": "filed as a second album of the same name"},
            {"value": "dup:skip", "label": "Keep only the library copy", "detail": "this one stays in staging"},
        ]

    # -- decisions beets would have prompted for

    def choose_match(self, task):
        if self.answers is not None:
            return self.answered(task)
        if task.rec == Recommendation.strong and task.candidates:
            return task.candidates[0]
        twin = self.twin(task)
        cands = [self.candidate(m, n == 0 and not twin) for n, m in enumerate(task.candidates[:5])]
        if twin:
            there = len(list(twin.items()))
            self.record(task, f"like an album already filed ({there} tracks there, {len(task.items)} here)",
                        self.dup_options(twin, len(task.items)) + cands, twin=twin.id)
            return Action.SKIP
        why = {Recommendation.none: "no match beets would accept",
               Recommendation.low: "weak match",
               Recommendation.medium: "close match"}.get(task.rec, "needs a look")
        why += f" (best {round(100 * (1 - float(task.candidates[0].distance)))}%)" if task.candidates else ": nothing found"
        self.record(task, why, cands)
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
                guess = from_name(i.path)
                i.title = i.title or guess.get("title", "")
                i.track = i.track or int(guess.get("track") or 0)
            self.dupmode[key] = value
            task.__dict__.pop("source", None)  # cached from the old tags; the duplicate check reads it
            return Action.RETAG
        if value == "dup:skip":
            return Action.SKIP
        if a["choice"] == "custom":
            f = a.get("fields") or {}
            for i in task.items:
                guess = from_name(i.path)
                i.albumartist = f.get("albumartist") or i.albumartist
                i.artist = i.artist or i.albumartist
                i.album = f.get("album") or i.album
                if str(f.get("year", "")).isdigit():
                    i.year = int(f["year"])
                i.title = i.title or guess.get("title", "")
                i.track = i.track or int(guess.get("track") or 0)
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
            mode = self.dupmode.get(key)
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


class StageReview(BeetsPlugin):
    def commands(self):
        cmd = ui.Subcommand("stage-review", help="import a staged audio batch without prompts; record the rest for review")
        cmd.parser.add_option("--answers", help="apply the answers exported to this file or directory")
        cmd.parser.add_option("--batch", help="batch name in the review (default: the directory's name)")
        cmd.func = self.run
        return [cmd]

    def run(self, lib, opts, args):
        if len(args) != 1:
            raise ui.UserError("usage: beet stage-review [--answers DIR] STAGING/<batch>")
        staging = os.path.abspath(args[0])
        batch = opts.batch or os.path.basename(staging)
        answers = load_answers(opts.answers, batch) if opts.answers else None
        # The whole batch every time, answers or not, so that beets groups the
        # folders into albums exactly as it did for the review: an answer is
        # keyed by an album's first folder, and a multi-disc album's other
        # folders are only imported with it. Unanswered albums are skipped.
        paths = [staging]
        config["import"]["quiet"] = False
        config["import"]["timid"] = False
        config["import"]["resume"] = False
        config["import"]["group_albums"] = False
        session = StageSession(lib, None, [os.fsencode(p) for p in paths], None, staging, answers)
        session.run()
        left = [d for d in os.listdir(staging) if os.path.isdir(os.path.join(staging, d))]
        if answers is None:
            out = staging.rstrip("/") + ".review.json"
            Path(out).write_text(json.dumps({
                "batch": batch, "kind": "audio", "source": "beets",
                "created": datetime.datetime.now().isoformat(timespec="seconds"),
                "items": session.review,
            }, indent=1, ensure_ascii=False))
            ui.print_(f"for review: {len(session.review)} albums -> {out}")
        ui.print_(f"left in staging: {len(left)} album folders")
