---
name: media-playlist
description: Use when the user asks to make, show, list, change, reorder, rename, share, export or delete a music playlist, to add or remove songs or albums from one, to build a playlist from a description ("a dinner playlist", "everything I favourited this year"), or runs /media-playlist. Manages the playlists of desk's music server (Navidrome), the ones Feishin and the phone show.
---

# Managing music playlists

`media-playlist`, on desk (from the Mac, `ssh desk media-playlist …`),
manages the playlists of desk's music server. They are the server's own:
what is made here appears in Feishin, on the phone and in the web UI
(`http://desk:4533`) at once, and what the user made there is here. Add
`--json` to any command. `media-playlist --help` has the rest.

```sh
media-playlist list
media-playlist show <playlist>                   # tracks, numbered
media-playlist search '<artist, album or title>' # albums and tracks, with ids
media-playlist album album:<id>                  # an album's tracks
media-playlist create '<name>' [<item> …] [--comment '…']
media-playlist add <playlist> <item> … [--at N]
media-playlist remove <playlist> 1,3-5
media-playlist move <playlist> 1,3-5 --to N
media-playlist set <playlist> [--name '…'] [--comment '…'] [--public | --private]
media-playlist export <playlist> [-o file.m3u] | export --all <dir>
media-playlist smart '<name>' --rules <file | ->
media-playlist delete <playlist>
```

`<playlist>` is a name (any case) or an id. `<item>` is a track id, or
`album:<id>` for a whole album in order; `search` prints both. Positions
are the numbers `show` prints, so `show` again after every change before
using them: they shift.

## Procedure

1. **Look first.** `list`, and `show` the playlist the user means, before
   changing it. If two playlists could be meant, ask.
2. **Find the tracks** with `search`, one search per album or song asked
   for; `album` when the user wants some tracks of one. Only what the
   library holds can be in a playlist. For something it lacks, say so, and
   offer to get it with the **media-fetch** skill; don't substitute another
   version without saying.
3. **Change it**: `create`, `add`, `remove`, `move`, `set`. `add` skips a
   track the playlist already has and says which; `--allow-duplicates`
   only if the user wants it twice.
4. **Report** what the playlist is now: its name, how many tracks, its
   length, and what was added, skipped or not found. For a playlist built
   from a description, list the tracks so the user can prune.

## Smart playlists

A smart playlist is a rule the server evaluates each time it is opened, so
it keeps itself current: use one when the user describes a condition
("favourites I haven't played lately", "added this month"), not a list.
The rules are JSON:

```json
{"all": [{"is": {"loved": true}}, {"notInTheLast": {"lastplayed": 180}}],
 "sort": "lastplayed", "order": "asc", "limit": 100}
```

- `all` / `any`: lists of conditions, and they nest.
- Operators: `is`, `isNot`, `gt`, `lt`, `contains`, `notContains`,
  `startsWith`, `endsWith`, `inTheRange` (`[from, to]`), `before`, `after`
  (dates), `inTheLast`, `notInTheLast` (days), `inPlaylist`,
  `notInPlaylist` (`{"id": "<playlist id>"}`).
- Fields: `title`, `album`, `artist`, `albumartist`, `genre`, `year`,
  `tracknumber`, `discnumber`, `duration`, `bitrate`, `filetype`,
  `compilation`, `loved`, `dateloved`, `rating`, `playcount`, `lastplayed`,
  `dateadded`, `datemodified`, `bpm`, `comment`, `filepath`.
- `sort` (a field, or `random`), `order` (`asc`, `desc`), `limit`.

`smart` with an existing smart playlist's name replaces its rules. **The
server accepts a field it doesn't know and silently matches nothing**, so
read what `smart` prints (how many tracks match, and the first ten) and fix
the rules if it is 0 or not what the user described. `add`, `remove` and
`move` refuse a smart playlist.

## Rules

- **Ask before `delete`,** and before a change that drops many tracks. A
  deleted playlist comes back only from the nightly database backup, by
  hand, and that restores every playlist, favourite and play count to the
  night before.
- Only through `media-playlist`: don't call the server's API yourself, and
  don't write playlist files (`.m3u`, `.nsp`) into the media share. The
  server would import a file from `music/` as a second, read-only copy,
  and nothing but `media-stage` and beets files there.
- `export` is for taking a playlist elsewhere (another player, a copy to
  keep). Write it outside the media share; its paths are the files' on
  desk, under `/srv/media/music`.
- One account, shared: every user's agent manages the same playlists, the
  ones in `list`. Say whose request a change was only if asked.
- "no login": the account's file isn't written yet. n8 writes it (README,
  "desk (once)"); don't ask for the password in chat, and don't print the
  file.
