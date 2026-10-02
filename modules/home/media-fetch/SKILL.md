---
name: media-fetch
description: Use when the user asks to find, search for, get or download media — an album, an artist's albums, music, books, audiobooks, RPGs and tabletop games — or runs /media-fetch. Searches, shows the choices, downloads what the user picks into a staging batch on desk, keeps them posted with estimates, then files the batch onto desk's media share with the media-share skill.
---

# Finding and downloading media

`media-fetch`, on desk (from the Mac, `ssh desk media-fetch …`), searches
for media the user asks for and downloads what they pick into a staging
batch, which is then filed like any other. Add `--json` to any command.
`media-fetch --help` has the rest.

```sh
media-fetch search '<artist> <album>' --kind <kind> [--ext flac,mp3 | --ext epub,pdf] [--min-files N]
media-fetch show <id>                            # the candidate's files, numbered
media-fetch get <id> --batch <batch> [--files 1,3-5]
media-fetch wait <batch>                         # blocks; delivers into staging/<batch>/<title>/
media-fetch status | cancel <id|batch>
```

`<batch>` is a new, descriptive name, such as `jacob-collier-2026-09-25`.
Several candidates can go into one batch; `get` refuses a batch that is
already scanned.

`search` answers with one table per place it searched, and `--kind` picks
the places: **corpus fetch** and **media share** for every kind, and
**itch.io** as well for `rpg`. IDs are numbered across the tables, and
`show`, `get`, `wait` and `status` work the same whichever table a candidate
came from.

- **media share** is what desk's library already holds: items in the
  kind's library folder, `filed`, or in a staging batch, `staged`, whose
  path matches every word of the query, in any format (`--ext` doesn't
  narrow it). Its rows are there to be compared, not fetched: `get`
  refuses them.
- An **itch.io** row's price is `free`, `owned` (in the user's itch.io
  library) or what the game costs; `get` refuses a game that is not free
  or owned.

## Procedure

1. **Categorize** what the user seeks, before searching, as one `--kind`:
   `music`, `audiobook`, `book`, `rpg` (tabletop roleplaying games, their
   rulebooks, supplements, zines and character sheets), `comic`, `movie`,
   `tv`, `video` or `other`. Decide from the request and what you know of
   the title; if it could be either (a novel and the game based on it, say)
   and the user didn't say, ask.
2. **Search.** For an artist's albums, search the artist and then each
   album the first results don't cover. `--kind` already limits corpus
   fetch to the kind's usual file types (audio for music, pdf/epub/zip/cbz
   for rpg, …); narrow further with `--ext` (`--ext flac` for lossless
   only), or `--ext all` for every type. `--min-files` drops singles.
   `rpg` searches itch.io as well as the corpus.
3. **Check the library**: the media share table is the check. Its query
   is the search's, and a row's path holds every word of it (punctuation
   aside), so when the search named more than the title (an artist and
   album, say) and the table is empty, search again on the title's most
   distinctive words alone: a filed path can lack some of the words asked
   for (an album under another album artist, a book without its
   subtitle). For music, also ask beets, which matches
   the tags rather than the path, on desk (from the Mac, `ssh desk …`):
   `beet ls -a -f '$albumartist - $album ($year) · $path' '<artist>'`. For
   a TV show, `show` its media share row for the seasons and episodes
   already there. A potential duplicate is anything
   filed or staged with the same artist or author and title, or the same
   film or show (any edition, year, format or resolution; "The Joy of
   Motion" and "The Joy of Motion (Deluxe)" both count), and for TV any
   season or episode the download would bring again.
4. **Choose.** Each candidate is one folder from one source. Show the user
   one table per place searched, each headed with the name `search` gives
   it: **corpus fetch**, **media share**, and for `rpg` **itch.io**. In
   media share: what is already there, its path, format and whether it is
   filed or staged; an empty one says so in a line. In corpus
   fetch: complete (every track, one folder), lossless over lossy, `ready`
   over queued, fast. For several albums, one row per album with the best
   candidate and a higher-quality alternative if there is one. In itch.io:
   the games that match, each with its author, price, files and size;
   free and owned first. A paid game not owned can't be downloaded here:
   give its link (`show <id>`) so the user can buy it, then search again.
   **Every table `search` returned goes in the answer, always, in its
   order**, even when none of its rows is what the user asked for: then
   the table is one line saying so ("corpus fetch: 10 results, none of
   them Unravel the TTRPG"). A table that says `not searched` stays too,
   with the reason.
   Mark each corpus fetch or itch.io row that step 3 found a potential
   duplicate of with what is already there (path, edition, format), and
   don't suggest that row's candidate unless it is clearly better
   (lossless over a filed lossy copy, a missing edition).
   Download only what the user picked, user is entitled to all content via
   the media-fetch API.
5. **Download**: `get`, then `wait <batch>` as a **background job**, never
   in the foreground. It ends when every job is `delivered` or `failed`.
   The downloads themselves don't depend on it: a service on desk keeps
   them moving and delivers them. Keep the user posted:
   - Straight after `get`: each job, its size, and its estimate (`get`
     prints it; `status --json` has `eta` in seconds).
   - While it runs: the background `wait` prints a line whenever a job
     moves, with the time left. Check it, or `status`, every few minutes,
     and whenever the user asks. Tell the user what has arrived, what is
     left, and how long it should take.
   - When it ends: what was delivered, and what failed and why.
   An estimate covers the jobs ahead at the same source, at its measured
   speed, but not time spent in the source's own queue. Say so when a job
   sits `queued` longer than its estimate.
6. **Failures.** A job that ends `failed` stays undelivered. `status`
   gives each failed file's reason:
   - "the remote size of … does not match expected size": the source's
     files have changed since the search, so a retry can't succeed.
     `cancel` the job and pick another candidate (search again if none is
     left).
   - "not asked, the source is busy: …": the source refused one file as
     busy ("try again later", "overwhelmed", "too many files") and
     media-fetch asked it for nothing more. Don't retry it: `cancel` the
     job and pick a candidate from another source.
   - "not delivered: …": every file arrived, but the job couldn't be moved
     into the batch; the other jobs carry on. "… already exists": the
     batch has a folder of the job's title with a file of that name, most
     often another job's, from another source. If it is a second copy of
     what the batch holds, `cancel` the job; otherwise ask the user, and
     once what is in the way is gone, `get <id>` moves it in. Any other
     reason: `cancel` the job and pick another candidate.
   - Anything else: `get <id>` again retries the failed files, or `cancel`
     the job and pick another candidate.
   Replacing a failed candidate with an equivalent one (same album, same
   quality, another source) is part of downloading what the user picked;
   tell them what you switched.
7. **File.** Once every job is `delivered`, file the batch with the
   **media-share** skill, from its step 2 (Scan) on
   `/srv/media/staging/<batch>`: the files are already staged. It stops at
   the review page for the user's answers when anything needs them, and
   otherwise files the batch without asking.

## Rules

- Corpus fetch is paced: 20 searches in any 220 seconds, and 30 files asked
  for in any minute, across everyone using desk. `search` waits for its
  turn and says so. For many searches (a long list of albums), run them one
  after another, tell the user how long the pace makes it (a hundred
  searches is about 18 minutes), and don't work around it: its server bans
  an account that searches faster for half an hour, and nothing can be
  searched or fetched until the ban ends.
- Search and download only through `media-fetch`: don't call whatever is
  behind it (itch.io's API and site included), install another download
  client, or move files out of its download directory by hand.
- Never copy downloads into the library yourself; media-share's procedure
  is the only way in.
