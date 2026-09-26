---
name: media-share
description: Use when copying, uploading, moving, filing or organising media — videos, movies, TV episodes, YouTube downloads, books, PDFs, RPG books, music — onto desk's media share (/Volumes/media, /Volumes/media-staging, smb://desk/media, /srv/media), or when renaming, tidying or checking files already in that library.
---

# Filing into desk's media share

The share is a library with a fixed layout, and files enter it only through
`media-stage`: staged as they came, scanned, classified in a table, checked,
then moved and tagged. Full reference: `media-stage --help`, and "Filing a
batch" in `docs/desktop-migration.md` of github.com/natb1/nix-config.

## Where things are

| | On desk | On the Mac |
| --- | --- | --- |
| Library | `/srv/media` | `/Volumes/media` — **read-only** |
| Staging | `/srv/media/staging` | `/Volumes/media-staging` (writable) |
| Run `media-stage` | locally | `ssh desk media-stage …`, with **desk's** paths |

Same files, two names: `/Volumes/media-staging/<batch>` on the Mac is
`/srv/media/staging/<batch>` on desk. The library is read-only over SMB on
purpose. A permission error writing to `/Volumes/media` means use this
procedure. Do not look for a way around it.

## Layout (enforced by `check`)

```
movies/<Title> (<Year>) {tmdb-<id>}/<Title> (<Year>) {tmdb-<id>}[ - <edition>].<ext>
tv/<Show> (<Year>) {tmdb-<id>}/Season NN/<Show> (<Year>) - SxxEyy[ - <episode title>].<ext>
youtube/<channel>/<YYYY-MM-DD> - <title> [<video id>].<ext>
books/<author>/<series or title>/<title>[ (<variant>)].<ext>   epub pdf mobi azw3 cbz cbr djvu
books/<author>/<series>/<series> Vol. <N>[ - <title>].<ext>
rpg/<game>/<title>[ (<variant>)].<ext>
music/<album artist>/<album> (<year>)/[<disc>-]<track> <title>.<ext>   beets only
```

Subtitles (`.en.srt`), `.info.json` and thumbnails sit beside their video with
the same stem; movie extras go in `movies/<Title> (<Year>)/extras/`. The
`{tmdb-<id>}` is optional but wanted: Plex and Jellyfin read it from the
folder, Infuse from the file name, so a movie's file repeats it; episodes
don't. A `:` in a title becomes ` - ` (`Alien - Covenant (2017)`). No
`: * ? " < > | \` in any name. There are no other top-level folders. Anything
that fits none of these is `skip`: ask the user where it belongs, and do not
invent a folder.

Books and RPGs are read in Kavita, where **a folder is a series**: an RPG
folder is one game or product line (not a grab-bag like "GM Tools"); a book
on its own is a series of its own, in a folder of its title
(`books/Albert Camus/The Stranger/The Stranger.epub`); a book in a series is
`<series> Vol. <N> - <title>`, one file per volume number. Kavita reads a
volume from any `v2`, `vol 2`, `volume 2`, `tome 2` or `S01` in a name, so a
version is written `version 1.1`, never `v1.1`. Parentheses are for variants
(pages, spreads, A4, a system, a translator). `check` refuses what Kavita
would misread; `apply` writes the series, volume and title into each file.

## Procedure

`<batch>` is a new, descriptive name, such as `mba-downloads-2026-09-25`. One
agent or person per batch.

1. **Stage**: copy the files as they are, without renaming.
   Mac: `rsync -a --progress <source>/ /Volumes/media-staging/<batch>/`.
   desk: `rclone copy …` / `rsync -a …` into `/srv/media/staging/<batch>/`.
   Copy, don't move: the source stays until the user deletes it.
2. **Scan**: `media-stage scan --hash <staging>/<batch>`. From the Mac, run it
   on desk: `ssh desk media-stage scan --hash /srv/media/staging/<batch>`.
   Hashing over SMB would read every byte across the network. Over a slow
   link (both hosts on Wi-Fi: ~5 MB/s), scan and draft a hard-linked copy on
   the Mac first, and send only what the draft keeps.
3. **Draft**: `media-stage draft --lookup <staging>/<batch>` writes
   `<staging>/<batch>.tsv` (columns `old`, `new`, `confidence`, `note`).
   `--lookup` takes each film's and show's title, year, TMDB id and original
   language from Wikidata. Draft also sets aside duplicates on its own:
   - content already in the library, even after `apply` rewrote its
     metadata (logged hashes, or a PDF that begins with the staged bytes):
     `discard`, `high`;
   - several copies of one film or episode: the best is kept
     (original-language audio, then not a cam, resolution class, subtitles,
     source, bit rate). The rest are `discard` when plainly worse, `trash`
     when it's a matter of taste. A dropped copy's subtitles go with the kept
     one when the two run the same length;
   - a copy of something already filed: `trash`, flagged.
4. **Classify**: edit the table, from the Mac through
   `/Volumes/media-staging/<batch>.tsv`. Fill every blank `new` and check every
   row that isn't `high`. The evidence is in the note and in
   `<batch>.manifest.jsonl`: guessit's parse of the name (`guess`), the
   container title, `.info.json`, PDF text and metadata, EPUB OPF. Rules:
   - Movies and TV need the **release year** (the show's first-air year for
     TV). Take it from the file or the manifest. If it isn't there, look it up.
     If still unsure, `skip`. Never guess a year.
   - Home videos, screen recordings, phone clips, installers, archives,
     anything unidentified: `skip`, and list them for the user.
   - Audio rows say `beets`; see below. Duplicates that `check` reports as
     byte-identical or already filed: `discard`.
   - `discard` deletes the staged copy at `apply`; `trash` moves it to
     `staging/trash/<batch>/` for the user to look through. Keep one copy and
     one edition of each film or episode. When it isn't plain which copy is
     better, `trash` the others rather than `discard`.
   - Do not rely on a file's old folder or name when its contents say
     otherwise.
   Music is not classified by hand. On desk:
   `media-stage group /srv/media/staging/<batch>` (one folder per album, by
   the files' own tags), then `beet stage-review /srv/media/staging/<batch>`.
   It imports an album only when its MusicBrainz match is strong and nothing
   argues against it: no file is the same recording as a track already filed
   (fingerprints), no album of that name is filed, `group` didn't merge it,
   and no file's name disagrees with its tags. The rest go, with their
   evidence and candidates, to `<batch>.review.json`. Never run `beet import`
   on a batch yourself: it skips these checks and doesn't record where each
   file came from.
5. **Check**: `media-stage check <staging>/<batch>`, and fix the table until it
   reports 0 errors. Rows that are still guesses stay flagged in their note
   (`check`, `guess`, `likely`) or below `high`, so that step 6 asks about them.
6. **Review page**: the user decides what you could not.
   - Tables: `media-stage review export <staging>/<batch>` writes
     `<batch>.review.json` with every row that is blank, `skip`, below `high`,
     or flagged in its note. Audio: `beet stage-review` already wrote it.
   - Find the page: the link your CLAUDE.md gives, if it gives one (an
     account that can't see the shared page has its own); otherwise
     `Artifact` `list`, title **Media Filing Review**.
   - Load the batch: `ArtifactData` `set`, collection `reviews`, doc id
     `<batch>`, `file_path` the review JSON. Replace an older version of the
     same batch; never mix batches in one document.
   - Give the user the link, how many items wait, and a summary of what will
     be filed without asking (rows per top-level folder). Stop until they say
     the batch is reviewed. Don't apply anything from the batch before that.
7. **Read the answers**: `ArtifactData` `query`, collection `answers`, where
   `batch == <batch>`, `out_dir` `/srv/media/staging/<batch>.answers` (or the
   answers directory your CLAUDE.md names, if staging isn't writable for you:
   use that path for `<batch>.answers` in every command below, and remove
   it after `close`). Then on desk:
   - Tables: `media-stage review import /srv/media/staging/<batch> --answers
     /srv/media/staging/<batch>.answers`, then `check` again.
   - Audio: `beet stage-review --answers /srv/media/staging/<batch>.answers
     /srv/media/staging/<batch>`. A chosen release is applied by its id,
     hand-entered tags as-is, "Leave it in staging" leaves the album where it
     is. A chosen release takes only the files that match its tracks, and an
     album already filed under the same name is not filed twice. Whatever is
     left (a suite's extra movements, a second copy) goes round again: `beet
     stage-review --batch <batch>-2 …` (answers to the same `<batch>.answers`
     folder), a new tab on the page, where each
     leftover offers "add these files to the album already filed", replace
     it, keep both, or leave in staging.
8. **Audit music**, on desk, once nothing more of the batch is to be
   imported: `beet stage-audit /srv/media/staging/<batch>`. It compares each
   filed track with its original in the manifest: a length that doesn't fit
   its slot on the release, or a title that now names another number
   ("No. 3" filed as "No. 5"). Flags go to `<batch>.audit.review.json`: load
   it as review doc `<batch>-audit`, and after the user's answers (same
   `answers` query, `batch == <batch>-audit`, same `out_dir`) run
   `beet stage-audit --answers /srv/media/staging/<batch>.answers
   /srv/media/staging/<batch>`, which re-slots or retitles and audits again.
   Don't fix a flagged track any other way. Skip this step for a batch with
   no music.
9. **Apply**, on desk: `media-stage apply /srv/media/staging/<batch>`
   (from the Mac: `ssh desk media-stage apply /srv/media/staging/<batch>`).
   It re-checks, moves, writes standard metadata, deletes `discard` rows,
   moves `trash` rows to `staging/trash/<batch>/`, and logs each file with its
   original sha256 to `<batch>.applied.jsonl` (kept after `close`: it is how
   a later batch knows the content is filed). It can be rerun.
10. **Lint and close**: `media-stage lint`. Then take the filed batch off
   the review page, so the page shows only reviews still waiting: every
   `reviews` document of the batch (`<batch>`, `<batch>-2` and later
   rounds, `<batch>-audit`) and its `answers` documents (`query`, `batch`
   in those ids). Every answer was already saved to
   `/srv/media/staging/<batch>.answers` in step 7; if a round's answers
   were never read, read them first. Delete them all in one `ArtifactData`
   `batch`. Report what is filed, what is left in staging and why, and ask
   what to do with the leftovers and with the source. When the user has
   settled the leftovers: `media-stage close /srv/media/staging/<batch>`,
   which removes the batch's records. It refuses while files remain or
   before a music batch's audit has passed. `staging/trash/<batch>/` is not
   the batch's: it stays until the user empties it. Never delete
   `<batch>.manifest.jsonl` or the review files in staging by hand: the
   manifest is the only record of what each file was before beets renamed
   it.

## Finding and downloading

To find and download media the user asks for, use the **media-fetch**
skill. It downloads into a staging batch and hands it back here at step 2
(Scan).

## Rules

- Never cp, mv, rsync or rename into or inside the library (`music/`,
  `books/`, `rpg/`, `movies/`, `tv/`, `youtube/`) by hand. On desk the files
  are writable, but these rules still apply.
- Fix metadata of files already filed with `media-stage tag <path>` or
  `media-stage lint --fix`, on desk.
- Rename or move something already filed: `media-stage restage
  /srv/media/staging/<batch> <library paths…>` takes it back into a new
  batch, which is then filed like any other (scan, draft, table, check,
  apply).
- `locked: … held by: <host> <pid> …` means another host or session is working
  on that batch or the library. Wait and retry. Delete the lock only if the
  user confirms that process is gone.
- `changed since scan` means rescan the batch; don't edit the manifest.
- YouTube: download straight into the layout on desk with yt-dlp
  (`docs/desktop-migration.md`, "Layout on the share"), or stage the files
  with their `.info.json` beside them so `draft` can name them.
