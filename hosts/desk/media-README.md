# desk media

Installed by hosts/desk/media.nix in github.com/natb1/nix-config, and
overwritten on every switch. Edit it there.

## Two shares

- `smb://desk/media` (`/Volumes/media` on the Mac) is the library. It is
  **read-only** over SMB.
- `smb://desk/media-staging` (`/Volumes/media-staging`) is where new files
  arrive. It is writable. On desk it is `/srv/media/staging`.

## Layout

```
movies/<Title> (<Year>)/<Title> (<Year>)[ - <edition>].<ext>
tv/<Show> (<Year>)/Season NN/<Show> (<Year>) - SxxEyy[ - <episode title>].<ext>
youtube/<channel>/<YYYY-MM-DD> - <title> [<video id>].<ext>
books/<author>/<title>.<ext>
rpg/<game>/<title>[ (<variant>)].<ext>
music/<album artist>/<album> (<year>)/[<disc>-]<track> <title>.<ext>
```

## Adding files

Nothing is copied into the library directly. A batch is staged, classified in
a table and moved in by `media-stage`, which also writes each file's standard
metadata. Music is imported by `beet` instead.

1. Copy the files as they are into `media-staging/<batch>/`.
2. `ssh desk media-stage scan --hash /srv/media/staging/<batch>`
3. `ssh desk media-stage draft /srv/media/staging/<batch>`
4. Fill in and correct `media-staging/<batch>.tsv`. Its `new` column is the
   path in the library; use `skip` to leave a file in staging.
5. `ssh desk media-stage check /srv/media/staging/<batch>`
6. `ssh desk media-stage apply /srv/media/staging/<batch>`
   (music: `ssh -t desk beet import --group-albums /srv/media/staging/<batch>`)
7. `media-stage lint`

`media-stage --help` has the details. The full procedure is "Filing a batch"
in docs/desktop-migration.md. Renaming or deleting inside the library is done
on desk.
