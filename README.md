# nix-config

Nix flake configuration for my machines. One repo, one lockfile, one commit per
change — every host here shares `modules/`, so a change to a shared module and
all the hosts that consume it lands atomically.

## Hosts

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
cd ~/nix-config && git pull
sudo nixos-rebuild switch --flake .#desk
```

The checkout is `~/nix-config`, not `~/natb1/nix-config`: it was seeded there by
[`scripts/seed-install.sh`](scripts/seed-install.sh). Replaces `wsl` as the
desktop's Linux; see [`docs/desktop-migration.md`](docs/desktop-migration.md).

### `mba` — Apple Silicon MacBook Air

```sh
cd ~/natb1/nix-config && git pull
sudo darwin-rebuild switch --flake .#mba
```

Home-manager is integrated as a NixOS / nix-darwin module, so one rebuild does
both system and user config. There is no standalone `home-manager switch`
entry point.

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
paragraph once it starts; it also retires several WSL-only modules, so read it
before extending anything under `hosts/wsl/`.

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

## Naming

The WSL host is `wsl`: that is `networking.hostName`, the Tailscale node name,
what avahi publishes as `wsl.local`, and the wezterm mux domain the Windows GUI
auto-connects to. Those move together.

The Windows-registered WSL **distro** name is still `NixOS` — that is registered
with Windows, not NixOS, so `wsl.exe -d NixOS` and the `//wsl$/NixOS/...` UNC
paths in `modules/home/wezterm.nix` are unrelated to the hostname.
