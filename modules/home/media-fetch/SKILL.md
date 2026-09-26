---
name: media-fetch
description: Use when the user asks to find, search for, get or download media — an album, an artist's albums, music, books, audiobooks — or runs /media-fetch. Searches, shows the choices, downloads what the user picks into a staging batch on desk, keeps them posted with estimates, then files the batch onto desk's media share with the media-share skill.
---

# Finding and downloading media

`media-fetch`, on desk (from the Mac, `ssh desk media-fetch …`), searches
for media the user asks for and downloads what they pick into a staging
batch, which is then filed like any other. Add `--json` to any command.
`media-fetch --help` has the rest.

```sh
media-fetch search '<artist> <album>' [--ext flac,mp3 | --ext epub,pdf] [--min-files N]
media-fetch show <id>                            # the candidate's files, numbered
media-fetch get <id> --batch <batch> [--files 1,3-5]
media-fetch wait <batch>                         # blocks; delivers into staging/<batch>/<title>/
media-fetch status | cancel <id|batch>
```

`<batch>` is a new, descriptive name, such as `jacob-collier-2026-09-25`.
Several candidates can go into one batch; `get` refuses a batch that is
already scanned.

## Procedure

1. **Search.** For an artist's albums, search the artist and then each
   album the first results don't cover. Use `--ext flac,mp3` for music and
   `--ext epub,pdf` for books, and `--min-files` to drop singles.
2. **Check the library** for what the search found, on desk (from the
   Mac, `ssh desk …`): music `beet ls -a -f '$albumartist - $album ($year) · $path' '<artist>'`,
   books and RPGs `find /srv/media/books /srv/media/rpg -iname '*<title>*'`,
   and `ls /srv/media/staging` for a batch of it not yet filed. A potential
   duplicate is anything filed or staged under the same artist and title
   (any edition, year or format; "The Joy of Motion" and "The Joy of
   Motion (Deluxe)" both count).
3. **Choose.** Each candidate is one folder from one source. Show the user
   a short list: complete (every track, one folder), lossless over lossy,
   `ready` over queued, fast. For several albums, one row per album with
   the best candidate and a higher-quality alternative if there is one.
   If, and only if, step 2 found potential duplicates, show them with the
   list: on each row it concerns, what is already there (path, edition,
   format), and don't suggest that row's candidate unless it is clearly
   better (lossless over a filed lossy copy, a missing edition). With no
   potential duplicates, say nothing about the library.
   Download only what the user picked, user is entitled to all content via
   the media-fetch API.
4. **Download**: `get`, then `wait <batch>` as a **background job**, never
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
5. **Failures.** A job that ends `failed` stays undelivered. `status`
   gives each failed file's reason:
   - "the remote size of … does not match expected size": the source's
     files have changed since the search, so a retry can't succeed.
     `cancel` the job and pick another candidate (search again if none is
     left).
   - "not asked, the source is busy: …": the source refused one file as
     busy ("try again later", "overwhelmed", "too many files") and
     media-fetch asked it for nothing more. Don't retry it: `cancel` the
     job and pick a candidate from another source.
   - Anything else: `get <id>` again retries the failed files, or `cancel`
     the job and pick another candidate.
   Replacing a failed candidate with an equivalent one (same album, same
   quality, another source) is part of downloading what the user picked;
   tell them what you switched.
6. **File.** Once every job is `delivered`, file the batch with the
   **media-share** skill, from its step 2 (Scan) on
   `/srv/media/staging/<batch>`: the files are already staged. It stops at
   the review page for the user's answers when anything needs them, and
   otherwise files the batch without asking.

## Rules

- Search and download only through `media-fetch`: don't call whatever is
  behind it, install another download client, or move files out of its
  download directory by hand.
- Never copy downloads into the library yourself; media-share's procedure
  is the only way in.
