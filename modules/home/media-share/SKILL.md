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
   - Audio: `beets`. Duplicates that `check` reports as byte-identical: `skip`.
   - Do not rely on a file's old folder or name when its contents say
     otherwise.
5. **Check**: `media-stage check <staging>/<batch>`, and fix the table until it
   reports 0 errors.
6. **Show the user**: before applying, give a summary of the moves (counts per
   top-level folder, every row that was blank or not `high`, every `skip`).
   Apply only after they agree.
7. **Apply**, on desk: `media-stage apply /srv/media/staging/<batch>`
   (from the Mac: `ssh desk media-stage apply /srv/media/staging/<batch>`).
   It re-checks, moves, writes standard metadata and logs to
   `<batch>.applied.jsonl`. It can be rerun.
   Music: `ssh -t desk beet import --group-albums /srv/media/staging/<batch>`
   (interactive). Needs the user.
8. **Lint**: `media-stage lint` (read-only, fine from the Mac). Report what is
   left in staging (the `skip`s) and ask the user what to do with them and
   with the source.

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
