# nix-config

Nix flake configuration for my machines. One repo, one lockfile, one commit per
change — every host here shares `modules/`, so a change to a shared module and
all the hosts that consume it lands atomically.

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

## Everyday commands

```sh
# check before switching — runs the module tests
nix flake check

# build without activating, then inspect what would change
nixos-rebuild build --flake .#wsl
nix store diff-closures /run/current-system ./result

# apply
sudo nixos-rebuild switch --flake .#wsl

# roll back
sudo nixos-rebuild switch --rollback

# bump all inputs (review the closure diff before switching)
nix flake update
```

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
