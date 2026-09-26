# nix-config

Nix flake configuration for my machines. One repo, one lockfile, one commit per
change — every host here shares `modules/`, so a change to a shared module and
all the hosts that consume it lands atomically.

## Hosts

On every host, `rebuild` does the pull and the switch below in one command
([`modules/home/rebuild.nix`](modules/home/rebuild.nix)); the checkout is
`~/natb1/nix-config` everywhere.

Run the update from a clone of this repo **on the machine being updated** — a
host can only build and activate itself, and activation needs root on both
platforms. A host applies `main` **as locked**: it pulls and switches, and never
runs `nix flake update` itself (see [Updating inputs](#updating-inputs)).

### `wsl` — NixOS-WSL on the Windows desktop

```sh
cd ~/natb1/nix-config && git pull
sudo nixos-rebuild switch --flake .#wsl
```

If a switch restarts systemd (any nixpkgs bump that moves it), WSL loses its
`WSLInterop` binfmt entry and every `.exe` fails with `Exec format error` — which
fails the Windows-side home-manager steps. Run `wsl --shutdown` from Windows and
reopen the distro; boot re-registers interop and re-runs home-manager.

### `desk` — native NixOS on the desktop

```sh
cd ~/natb1/nix-config && git pull
sudo nixos-rebuild switch --flake .#desk
```

Or `Mod+Shift+R` in niri, which runs `rebuild` in a terminal. `desk` is the
desktop's Linux when NixOS is booted; `wsl` stays for Linux on bare-metal Windows. See
[`docs/desktop-migration.md`](docs/desktop-migration.md).

### `mba` — Apple Silicon MacBook Air

```sh
cd ~/natb1/nix-config && git pull
sudo darwin-rebuild switch --flake .#mba
```

Home-manager is integrated as a NixOS / nix-darwin module, so one rebuild does
both system and user config. There is no standalone `home-manager switch`
entry point.

## Setting up a device

What a switch cannot do: the sign-ins, passwords and pairings, once per
device. Everything desk serves — the media shares, the printer, the music
server — is **tailnet-only**, so Tailscale comes first on every device. What
each step creates is listed under [State this repo does not
manage](#state-this-repo-does-not-manage).

### Tailscale (every device)

| Device | Steps |
| --- | --- |
| desk, wsl | After the first switch, `sudo tailscale up` and follow the login URL ([`modules/nixos/tailscale.nix`](modules/nixos/tailscale.nix)). |
| mba | After the first switch, `sudo tailscale up` ([`modules/darwin/tailscale.nix`](modules/darwin/tailscale.nix) runs the open-source `tailscaled`, not the App Store app). |
| iPhone | Install **Tailscale** from the App Store, sign in to the same tailnet, and leave the VPN on. |

Check: `tailscale status` lists `desk`, and `tailscale ping desk` answers. The
short name `desk` works everywhere through MagicDNS.

### desk (once, after its first switch)

1. **Samba password** for the media shares: `sudo smbpasswd -a n8`. It is
   Samba's own, not the login password.
2. **Music server account:** open `http://desk:4533` and create the admin
   ([`hosts/desk/music.nix`](hosts/desk/music.nix)). Then start **Feishin**
   and add the server `http://localhost:4533` with that account.
3. **Video server (Jellyfin):** open `http://desk:8096`, create the admin, and
   add the libraries listed in
   [`hosts/desk/jellyfin.nix`](hosts/desk/jellyfin.nix): `movies`, `tv`,
   `youtube` (as Home Videos) and `music`. Then start **Jellyfin Desktop** and
   add the server `http://localhost:8096`. Check: Dashboard → Playback →
   Transcoding shows VAAPI on the `12:00.0` render node.
4. **Book server (Kavita):** open `http://desk:5000`, create the admin, and add
   two libraries of type **Book**: `/srv/media/books` and `/srv/media/rpg`
   ([`hosts/desk/kavita.nix`](hosts/desk/kavita.nix)).
5. **Soulseek (slskd):** write `/etc/slskd/credentials` (root, 0600) with
   the Soulseek account and a web UI login, then `sudo systemctl restart
   slskd` ([`hosts/desk/soulseek.nix`](hosts/desk/soulseek.nix)):
   `SLSKD_SLSK_USERNAME`, `SLSKD_SLSK_PASSWORD`, `SLSKD_USERNAME`,
   `SLSKD_PASSWORD`, one `NAME=value` per line. There is no port to forward:
   T-Mobile Home Internet is behind carrier-grade NAT. Check:
   `http://desk:5030` shows *Connected*, and Shares lists `music`, and
   `media-fetch search '<an album>'` lists candidates.
6. **iPhone over Bluetooth** (notifications and texts,
   [`hosts/desk/iphone.nix`](hosts/desk/iphone.nix)):
   `tether --bt-status` should report MAP + PBAP + ANCS. Pair from
   `tether-gtk` (Devices) or `tether --bt-pair <phone address>`, and on the
   phone allow **Show Notifications** and **Sync Contacts**.
   `tether --bt-setup` names anything missing.
7. The rest (Google Drive, iCloud Photos, the restic backup) have their own
   steps in [State this repo does not manage](#state-this-repo-does-not-manage).

The printer needs nothing: the queue is declared
([`hosts/desk/printing.nix`](hosts/desk/printing.nix)). Check: `lpstat -t`
shows `brother` enabled and default.

### mba (once, after its first switch)

1. **Media shares.** The launchd agent in
   [`hosts/mba/desk.nix`](hosts/mba/desk.nix) mounts both at login and
   every five minutes while desk is up. The first time, macOS asks for the
   Samba password: enter it and tick **Remember this password in my
   keychain**. Check: `/Volumes/media` (the library, **read-only**) and
   `/Volumes/media-staging` (writable) both exist, and
   `touch /Volumes/media/x` fails.
2. **Printer.** Nothing to do: every switch runs `lpadmin` for the
   `desk_brother` queue. A switch made while desk was down only warns, so
   switch again once it is up. Check: `lpstat -p desk_brother`. To add it by
   hand, use Terminal, not the Add Printer window:
   `lpadmin -p desk_brother -D "Brother (desk)" -E -v ipp://desk/printers/brother -m everywhere`.
3. **ssh to desk,** for filing media (`ssh desk media-stage …`): nothing to
   do. The Mac's public key is in `services.sshAuthorizedKeys.keys` in
   [`modules/home/default.nix`](modules/home/default.nix), which every host
   accepts. A new device adds its key there. Check: `ssh desk true`.
4. **Music:** open **Feishin** (in `~/Applications/Home Manager Apps`), add
   the server `http://desk:4533`, and log in with the Navidrome account from
   desk step 2. The web player at `http://desk:4533` works too.
5. **Video:** open **Jellyfin Desktop** (beside Feishin), add the server
   `http://desk:8096`, and log in with the Jellyfin account from desk step 3.
6. **Books:** `http://desk:5000` in a browser, the Kavita account from desk
   step 4.

### iPhone (once)

1. **Tailscale**, as above.
2. **Printer.** iOS has no screen for a printer by address, so it takes a
   profile: AirDrop
   [`hosts/desk/airprint-desk.mobileconfig`](hosts/desk/airprint-desk.mobileconfig)
   from the Mac, then **Settings → Profile Downloaded → Install**. Check: the
   share sheet's Print lists **Brother on desk** and a page prints. (A
   profile can add a printer; it cannot install or configure an app.)
3. **Media in Files:** Files → ⋯ → **Connect to Server** → `smb://desk/media`,
   as **Registered User** `n8` with the Samba password. It is read-only; add
   `smb://desk/media-staging` too for putting files on the share (they are
   filed from there, [Filing a batch](docs/desktop-migration.md#filing-a-batch)).
4. **Music: Amperfy** from the App Store. Server `http://desk:4533`, the
   Navidrome account from desk step 2. Downloads play offline; CarPlay works.
   **Video:** **Jellyfin** from the App Store (free), server
   `http://desk:8096`. **Books:** `http://desk:5000` in Safari (Add to Home
   Screen), or an OPDS reader such as Panels or Chunky with the OPDS URL from
   Kavita's user settings.
5. **Notifications and texts on desk:** pair from desk (desk step 6); allow
   **Show Notifications** and **Sync Contacts** when the phone asks. If
   notifications stop while texts still arrive, turn Bluetooth off and on
   **on the phone**; desk shows an alert when this happens.

### Kobo (once)

The Kobo cannot run Tailscale, so it reaches Kavita over the home Wi-Fi,
where desk opens port 5000 and nothing else
([`hosts/desk/kavita.nix`](hosts/desk/kavita.nix)). It works only at home.

1. **Fix desk's LAN address.** On the gateway, reserve desk's current address
   (`ip -4 addr show wlp14s0`) for its Wi-Fi MAC `f0:a6:54:14:9b:0d`. The
   Kobo cannot resolve `desk`, so it uses this address. Check: from the Mac
   on the Wi-Fi, `curl -sI http://<address>:5000` answers.
2. **KOReader** on the Kobo (installed alongside Kobo's own reader). Add an
   OPDS catalog with the OPDS URL from Kavita's user settings (**3rd Party
   Clients**), with `desk` swapped for the address above.
3. **Progress sync:** in KOReader's progress sync settings, point it at
   Kavita as
   [Kavita's KOReader guide](https://wiki.kavitareader.com/guides/3rdparty/koreader/)
   describes. Check: a page turned on the Kobo shows in Kavita's web reader.

## Updating inputs

`flake.lock` is shared by every host, and its routine writer is
[`.github/workflows/update-flake-lock.yml`](.github/workflows/update-flake-lock.yml).
Every Monday it runs `nix flake update --commit-lock-file`, evaluates both hosts
and runs the Linux module tests against the new lock, and pushes the lock commit
straight to `main` if they pass. There is no PR to merge; if they fail, nothing
is pushed and the run shows up red in Actions. Trigger it by hand from the
Actions tab when you want a bump sooner.

Picking a bump up is then just the host commands above, on each machine, when
you choose. The gate proves the lock *evaluates*; it does not build or activate
anything, so preview before switching (next section) — especially the first
host after a nixpkgs bump.

A local `git status` showing `flake.lock` modified means something updated it
outside that workflow. Discard it (`git checkout flake.lock`) rather than
committing it, or the two machines end up on locks nobody else has.

Bumping by hand is still fine when you need one input now. Do it on one
machine, switch and check it, and only then push — the other host should never
pull a hand-made lock that has not been through a switch:

```sh
nix flake update nixpkgs --commit-lock-file    # or no input name, for all
sudo nixos-rebuild switch --flake .#wsl         # after previewing, as below
git push
```

## Layout

```
flake.nix          inputs, the shared home-manager wiring, and the host list
hosts/<host>/      per-machine config; nothing here is shared
modules/nixos/     shared by every Linux host
modules/darwin/    shared by every macOS host
modules/home/      shared by every host, every platform
tests/             module regression tests, exposed as flake checks
.github/workflows/ the weekly flake.lock bump
scripts/           maintenance scripts (wezterm pin refresh)
docs/              migration plans and design notes
```

**Host vs. platform.** A module lives in `modules/` only if it evaluates
correctly on every host. Config that is specific to *one machine* lives under
`hosts/<host>/` — including its home-manager modules (`hosts/wsl/home/`).
A `pkgs.stdenv.hostPlatform.isLinux` guard is for behavior that genuinely differs by
*platform*; it is not a substitute for host scoping, because a future native
NixOS box is also Linux and would wrongly pick up WSL-only modules.

## Before and after a switch

```sh
nix flake check          # module tests; do this before any switch
```

Preview a change before applying it — build without activating, then diff the
closure against what is running:

```sh
nixos-rebuild build --flake .#wsl     # or: darwin-rebuild build --flake .#mba
nix store diff-closures /run/current-system ./result
```

Undo the last switch, or list what you can roll back to:

```sh
sudo nixos-rebuild switch --rollback   # wsl;  generations: nixos-rebuild list-generations
sudo darwin-rebuild --rollback         # mba;  generations: darwin-rebuild --list-generations
```

Both tools default to `<configurations>.$(hostname)`. The WSL host *is* named
`wsl`, so there the `#wsl` suffix is optional; the MacBook's hostname is not
`mba`, so there it is required.

After a lock bump, review the closure diff on one machine before switching the
rest.

### A future native NixOS host

Add `hosts/<name>/` (with the `nixos-generate-config`-produced
`hardware-configuration.nix`) plus a `nixosConfigurations.<name>` block in
`flake.nix` importing `./modules/nixos`, then use the `wsl` commands with the new
attribute.

The concrete case — the desktop gaining a native NixOS install on its second
SSD, with its existing Windows kept intact on the first and startable as a
GPU-passthrough guest — is planned in
[docs/desktop-migration.md](docs/desktop-migration.md). That plan supersedes this
paragraph once it starts. The WSL host stays alongside it, for Linux on
bare-metal Windows.

Note that it brings **Windows configuration into this repo** under
`hosts/desk/windows/`: a Nix-rendered WinGet DSC profile that Windows pulls and
applies to itself. There is one Windows install, booted either bare metal or
virtualized, so one profile covers both. The name `nix-config` is about the tool
that generates the configuration, not a restriction on what it configures.

## State this repo does not manage

These are provisioned by hand and a clean rebuild will not recreate them:

- `~/.config/nix/access-tokens.conf` — GitHub token for flake input resolution
  (mode 600, pulled in by `modules/home/nix.nix` via an optional `!include`).
  Without it `nix flake update` is rate-limited, but nothing breaks.
- SSH private keys. Only public keys live here
  (`modules/home/default.nix`).
- The Windows-side WezTerm GUI install, and the `G:` Google Drive volume that
  `hosts/wsl/mounts.nix` mounts — both depend on Windows-side software running.
- `desk`'s Google Drive credentials, which `hosts/desk/gdrive.nix` mounts at
  `/mnt/g`. Two pieces, and each is useless without the other:
  `~/.config/rclone/rclone.conf` (mode 600, **encrypted**: the `gdrive`
  remote, its OAuth client, and a refresh token with full access to Drive),
  and its random password, which lives in gnome-keyring under
  `service=rclone`. Neither is backed up, on purpose: both can be recreated
  in a minute, and a copy elsewhere would only be a second place to leak the
  token from. The OAuth client comes from Google Cloud project
  `nix-config-509614`. To recreate, follow the comment at the top of
  `hosts/desk/gdrive.nix`; if only the token has expired,
  `rclone config reconnect gdrive:`.
- `desk`'s Samba password for n8, which the `media` and `media-staging`
  shares in `hosts/desk/media.nix` check. Samba keeps its own database, separate from
  Unix accounts; set it with `sudo smbpasswd -a n8`. On `mba` the same
  password sits in the login keychain, saved the first time
  `hosts/mba/desk.nix` mounts the share ("Remember this password").
- `desk`'s Navidrome accounts (`hosts/desk/music.nix`): the admin is created
  on the first visit to `http://desk:4533`, and Feishin on desk and Amperfy on
  the phone log in with it. The database in `/var/lib/navidrome` is rebuilt
  by a rescan if lost, except playlists, favourites and play counts.
- `desk`'s Jellyfin and Kavita accounts and libraries
  (`hosts/desk/jellyfin.nix`, `hosts/desk/kavita.nix`): the admin of each is
  created on its first visit (`http://desk:8096`, `http://desk:5000`), and the
  libraries are added there. State is in `/var/lib/jellyfin` and
  `/var/lib/kavita` (watched state and reading progress are lost with it).
  Kavita's login-signing key, `/etc/kavita/token-key`, is generated on first
  start; deleting it only logs everyone out.
- `desk`'s restic credentials for the media backup in `hosts/desk/media.nix`,
  in `/etc/restic/` (root, dir 0700, files 0600). `media.password` is the
  repository's **encryption key**: there is no reset, and without it the
  backup on the Hetzner Storage Box is unreadable. `id_ed25519` is the SSH key
  the box's `authorized_keys` pins to append-only
  (`rclone serve restic --stdio --append-only restic/media`). A lost key is
  replaced by generating a new one and swapping the line on the box; a lost
  password cannot be replaced. See `docs/desktop-migration.md`, "Before any
  original is retired", for where the off-machine copies go.
- `desk`'s Soulseek login, `/etc/slskd/credentials` (root, 0600): the
  Soulseek account and the slskd web UI's login (`hosts/desk/soulseek.nix`).
  The API key beside it, `/etc/slskd/api.env`, is generated on first start.
  `/var/lib/slskd` holds search and transfer history, disposable.
- `desk`'s iCloud Photos backup state, for `hosts/desk/icloud.nix`: one env
  file per instance in `~/.config/icloudpd/` (Apple ID and library name), each
  Apple ID's password in gnome-keyring under `service=pyicloud://icloud-password`,
  and the session cookies in `~/.local/state/icloudpd/<apple-id>/`, which are
  **not** encrypted. `icloudpd-login <instance>` recreates the last two; the
  session lapses every couple of months anyway. `icloudpd-forget <instance>`
  removes them.
- `desk`'s Bluetooth bond with the iPhone (`/var/lib/bluetooth`) and Tether's
  settings (`~/.config/tether`), from pairing once — see
  `hosts/desk/iphone.nix`. Lost bond: unpair on the phone, pair again.

## Naming

The WSL host is `wsl`: that is `networking.hostName`, the Tailscale node name,
what avahi publishes as `wsl.local`, and the wezterm mux domain the Windows GUI
auto-connects to. Those move together.

The Windows-registered WSL **distro** name is still `NixOS` — that is registered
with Windows, not NixOS, so `wsl.exe -d NixOS` and the `//wsl$/NixOS/...` UNC
paths in `modules/home/wezterm.nix` are unrelated to the hostname.
