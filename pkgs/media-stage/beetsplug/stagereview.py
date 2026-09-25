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
        self.imported = 0

    # -- helpers

    def key(self, task):
        return os.path.relpath(displayable_path(task.paths[0]), self.staging)

    def record(self, task, why, options, match=None):
        key = self.key(task)
        items = sorted(task.items, key=lambda i: (i.disc or 0, i.track or 0, displayable_path(i.path)))
        guess = next((g for g in (from_name(i.path) for i in items) if g), {})
        first = items[0]
        artist = first.albumartist or first.artist or guess.get("artist", "")
        album = first.album or guess.get("album", "")
        tagged = sum(1 for i in items if i.title and i.artist and i.album)
        self.review.append({
            "id": item_id(key),
            "key": key,
            "kind": "album",
            "title": f"{artist or 'Unknown artist'} – {album or key}",
            "subtitle": f"{len(items)} tracks · {tagged} tagged",
            "why": why,
            "evidence": [
                {"label": "Folder", "value": key},
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
            "match": match,
        })

    @staticmethod
    def candidate(m, best=False):
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
            "score": round(100 * (1 - float(m.distance))),
            "url": i.data_url or f"https://musicbrainz.org/release/{i.album_id}",
            "recommended": best,
        }

    # -- decisions beets would have prompted for

    def choose_match(self, task):
        if self.answers is not None:
            return self.answered(task)
        if task.rec == Recommendation.strong and task.candidates:
            return task.candidates[0]
        why = {Recommendation.none: "no MusicBrainz match",
               Recommendation.low: "weak MusicBrainz match",
               Recommendation.medium: "possible MusicBrainz match"}.get(task.rec, "needs a look")
        if task.candidates:
            why += f" (best {round(100 * (1 - float(task.candidates[0].distance)))}%)"
        self.record(task, why, [self.candidate(m, n == 0) for n, m in enumerate(task.candidates[:5])])
        return Action.SKIP

    def answered(self, task):
        a = self.answers.get(item_id(self.key(task)))
        if not a or a["choice"] == "skip":
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
            return Action.RETAG
        value = a.get("value", "")
        if value.startswith("dup:"):
            value = a.get("match") or ""
        if value.startswith("mb:"):
            task.lookup_candidates([value[3:]])
            if task.candidates:
                return task.candidates[0]
        ui.print_(f"stagereview: {self.key(task)}: answer {a.get('value')!r} gave no match; left in staging")
        return Action.SKIP

    def get_duplicate_action(self, task, found_duplicates):
        if self.answers is not None:
            a = self.answers.get(item_id(self.key(task))) or {}
            return {"dup:keep": DuplicateAction.KEEP, "dup:remove": DuplicateAction.REMOVE}.get(
                a.get("value"), DuplicateAction.SKIP)
        where = "; ".join(sorted({displayable_path(d.item_dir() if hasattr(d, "item_dir") else d.path)
                                  for d in found_duplicates}))
        match = task.match
        self.record(task, f"already in the library: {where}", [
            {"value": "dup:skip", "label": "Keep the library copy", "detail": "this one stays in staging", "recommended": True},
            {"value": "dup:remove", "label": "Replace the library copy with this one", "detail": ""},
            {"value": "dup:keep", "label": "Keep both", "detail": "filed as two albums"},
        ], match=f"mb:{match.info.album_id}" if match and getattr(match.info, "album_id", None) else None)
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
        if answers is not None:
            ids = set(answers)
            paths = [os.path.join(staging, d) for d in sorted(os.listdir(staging))
                     if os.path.isdir(os.path.join(staging, d)) and item_id(d) in ids]
            if not paths:
                ui.print_("stage-review: no answered album is still in staging")
                return
        else:
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
