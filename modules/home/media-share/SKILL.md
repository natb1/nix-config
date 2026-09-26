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
movies/<Title> (<Year>)/<Title> (<Year>)[ - <edition>].<ext>
tv/<Show> (<Year>)/Season NN/<Show> (<Year>) - SxxEyy[ - <episode title>].<ext>
youtube/<channel>/<YYYY-MM-DD> - <title> [<video id>].<ext>
books/<author>/<title>.<ext>                   epub pdf mobi azw3 cbz cbr djvu
rpg/<game>/<title>[ (<variant>)].<ext>
music/<album artist>/<album> (<year>)/[<disc>-]<track> <title>.<ext>   beets only
```

Subtitles (`.en.srt`), `.info.json` and thumbnails sit beside their video with
the same stem; movie extras go in `movies/<Title> (<Year>)/extras/`. No
`: * ? " < > | \` in any name. There are no other top-level folders. Anything
that fits none of these is `skip`: ask the user where it belongs, and do not
invent a folder.

## Procedure

`<batch>` is a new, descriptive name, such as `mba-downloads-2026-09-25`. One
agent or person per batch.

1. **Stage**: copy the files as they are, without renaming.
   Mac: `rsync -a --progress <source>/ /Volumes/media-staging/<batch>/`.
   desk: `rclone copy …` / `rsync -a …` into `/srv/media/staging/<batch>/`.
   Copy, don't move: the source stays until the user deletes it.
2. **Scan**: `media-stage scan --hash <staging>/<batch>`. From the Mac, run it
   on desk: `ssh desk media-stage scan --hash /srv/media/staging/<batch>`.
   Hashing over SMB would read every byte across the network.
3. **Draft**: `media-stage draft <staging>/<batch>` writes
   `<staging>/<batch>.tsv` (columns `old`, `new`, `confidence`, `note`).
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
     byte-identical: `skip`.
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
   - Find the page: `Artifact` `list`, title **Media Filing Review**.
   - Load the batch: `ArtifactData` `set`, collection `reviews`, doc id
     `<batch>`, `file_path` the review JSON. Replace an older version of the
     same batch; never mix batches in one document.
   - Give the user the link, how many items wait, and a summary of what will
     be filed without asking (rows per top-level folder). Stop until they say
     the batch is reviewed. Don't apply anything from the batch before that.
7. **Read the answers**: `ArtifactData` `query`, collection `answers`, where
   `batch == <batch>`, `out_dir` `/srv/media/staging/<batch>.answers`. Then on
   desk:
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
   It re-checks, moves, writes standard metadata and logs to
   `<batch>.applied.jsonl`. It can be rerun.
10. **Lint and close**: `media-stage lint`. Mark the review filed with
   `ArtifactData` `update` on `reviews/<batch>` (and `<batch>-audit`):
   `{"closed": "<date>"}`. Report what is filed, what is left in staging and
   why, and ask what to do with the leftovers and with the source. When the
   user has settled the leftovers: `media-stage close
   /srv/media/staging/<batch>`, which removes the batch's records. It refuses
   while files remain or before a music batch's audit has passed. Never
   delete `<batch>.manifest.jsonl` or the review files by hand: the manifest
   is the only record of what each file was before beets renamed it.

## Soulseek

slskd on desk (`hosts/desk/soulseek.nix`) searches and downloads; its web
UI is `http://desk:5030`. From an agent, use its API on desk (from the Mac,
wrap each call in `ssh desk '…'`). Don't install another Soulseek client: a
second login on the account disconnects slskd.

```sh
. /etc/slskd/api.env; api=http://localhost:5030/api/v0; h="X-API-Key: $SLSKD_API_KEY"
id=$(uuidgen)
curl -sH "$h" -H 'Content-Type: application/json' -d "{\"id\":\"$id\",\"searchText\":\"<artist> <album>\"}" $api/searches
curl -sH "$h" $api/searches/$id                 # wait until isComplete
curl -sH "$h" $api/searches/$id/responses       # [{username, hasFreeUploadSlot, queueLength, uploadSpeed, files:[{filename, size, bitRate, length}]}]
curl -sH "$h" -H 'Content-Type: application/json' -d '[{"filename":"<as listed>","size":<n>}]' $api/transfers/downloads/<username>
curl -sH "$h" $api/transfers/downloads          # progress; state "Completed, Succeeded"
```

1. **Choose.** Group each response's files by folder and show the user a
   short list: a complete album (every track, one folder), lossless over
   lossy, a free upload slot, a short queue, a fast peer. Download only
   what the user picked, and only what they are entitled to download.
2. **Download** the chosen folder's files in one `POST`. They arrive in
   `/srv/media/staging/soulseek/<folder>/`.
3. **Stage.** When every file is `Succeeded`, move the folder (same disk,
   instant) into a new batch, then follow the procedure from step 2:
   `mkdir /srv/media/staging/<batch> && mv /srv/media/staging/soulseek/<folder> /srv/media/staging/<batch>/`.
   This is the one place a move is right: the download is not the user's
   original. `soulseek/` itself is never a batch.

## Rules

- Never cp, mv, rsync or rename into or inside the library (`music/`,
  `books/`, `rpg/`, `movies/`, `tv/`, `youtube/`) by hand. On desk the files
  are writable, but these rules still apply.
- Fix metadata of files already filed with `media-stage tag <path>` or
  `media-stage lint --fix`, on desk.
- `locked: … held by: <host> <pid> …` means another host or session is working
  on that batch or the library. Wait and retry. Delete the lock only if the
  user confirms that process is gone.
- `changed since scan` means rescan the batch; don't edit the manifest.
- YouTube: download straight into the layout on desk with yt-dlp
  (`docs/desktop-migration.md`, "Layout on the share"), or stage the files
  with their `.info.json` beside them so `draft` can name them.
