# nix-config

Nix flake configuration for my machines. One repo, one lockfile, one commit per
change — every host here shares `modules/`, so a change to a shared module and
all the hosts that consume it lands atomically.

Migration in progress: this config was extracted from `commons.systems` and the
machines have not all been switched onto it yet. See [TODO.md](TODO.md) for the
remaining steps and the QA checklist.

Also planned, not yet started: replacing WezTerm on the WSL box with Zellij,
reachable from the MacBook's Terminal and from a browser. See
[MIGRATION-zellij.md](MIGRATION-zellij.md).

## Hosts

| Attribute | Machine | Rebuild |
| --- | --- | --- |
| `nixosConfigurations.wsl` | NixOS-WSL on the Windows desktop | `sudo nixos-rebuild switch --flake ~/natb1/nix-config#wsl` |
| `darwinConfigurations.mba` | Apple Silicon MacBook Air | `darwin-rebuild switch --flake ~/natb1/nix-config#mba` |

Home-manager is integrated as a NixOS / nix-darwin module, so one rebuild does
both system and user config. There is no standalone `home-manager switch`
entry point.

## Layout

```
flake.nix          inputs, the shared home-manager wiring, and the host list
hosts/<host>/      per-machine config; nothing here is shared
modules/nixos/     shared by every Linux host
modules/darwin/    shared by every macOS host
modules/home/      shared by every host, every platform
tests/             module regression tests, exposed as flake checks
scripts/           maintenance scripts (wezterm pin refresh)
```

**Host vs. platform.** A module lives in `modules/` only if it evaluates
correctly on every host. Config that is specific to *one machine* lives under
`hosts/<host>/` — including its home-manager modules (`hosts/wsl/home/`).
A `pkgs.stdenv.isLinux` guard is for behavior that genuinely differs by
*platform*; it is not a substitute for host scoping, because a future native
NixOS box is also Linux and would wrongly pick up WSL-only modules.

## Applying updates

Same loop on every machine: **check, preview, apply.** Only the rebuild command
differs. Run it from a clone of this repo on the machine being updated — a host
can only build and activate itself.

```sh
cd ~/natb1/nix-config
git pull
nix flake check          # module tests; do this before any switch
```

### WSL (`wsl`)

```sh
# preview: build without activating, then see exactly what would change
nixos-rebuild build --flake .#wsl
nix store diff-closures /run/current-system ./result

# apply
sudo nixos-rebuild switch --flake .#wsl

# undo the last switch
sudo nixos-rebuild switch --rollback

# what generations exist
nixos-rebuild list-generations
```

`nixos-rebuild` defaults to `nixosConfigurations.$(hostname)`, and this host *is*
named `wsl`, so once switched the `#wsl` suffix is optional — `sudo
nixos-rebuild switch --flake .` resolves to the same thing.

### macOS (`mba`)

```sh
# preview
darwin-rebuild build --flake .#mba
nix store diff-closures /run/current-system ./result

# apply — activation must run as root on this nix-darwin version
sudo darwin-rebuild switch --flake .#mba

# undo the last switch
sudo darwin-rebuild --rollback

# what generations exist
darwin-rebuild --list-generations
```

The `#mba` suffix is **not** optional here: `darwin-rebuild` also defaults to the
hostname, and the MacBook's hostname is not `mba`.

### A future native NixOS host

Add `hosts/<name>/` (with the `nixos-generate-config`-produced
`hardware-configuration.nix`) plus a `nixosConfigurations.<name>` block in
`flake.nix` importing `./modules/nixos`, then use the WSL commands with the new
attribute.

### Updating inputs

```sh
nix flake update                    # all inputs
nix flake update nixpkgs            # just one
```

`flake.lock` is shared by every host, so a bump moves all of them at once.
Review the closure diff on one machine before switching the rest, and commit the
lockfile in its own commit so a regression is attributable.

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
