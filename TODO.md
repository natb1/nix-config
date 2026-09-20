# TODO — finishing the migration off commons.systems

Written 2026-09-19, at the point where the repo exists and is verified to build
but **nothing has been switched**. The WSL box is still running generation 49,
built from `commons.systems` `main`.

> **Update 2026-09-19:** the Mac (`darwinConfigurations.mba`) has now been built
> and switched — see §4, which is done. The WSL box (§1) is still on generation
> 49 and remains the outstanding switch.

What is already done: the extraction, the `nixos` → `wsl` rename, the dispatch
removal, and a closure diff proving the built `wsl` host differs from the running
generation only by the intended changes. `nix flake check` passes (15 checks) and
`darwinConfigurations.mba` evaluates.

---

## 1. Apply the WSL switch

```sh
cd ~/natb1/nix-config
nix flake check
nixos-rebuild build --flake .#wsl
nix store diff-closures /run/current-system ./result
sudo nixos-rebuild switch --flake .#wsl
```

The expected closure diff, for comparison — anything beyond this is unexpected
and worth stopping for:

```
claude-daemon.service                       ∅ → ε
dispatch-claude-daemon.service              ε → ∅
hm_environment.ddispatchusagesamples.conf   ε → ∅
office-hours-producer                       ε → ∅
unit-office-hours-producer.service/.timer   ε → ∅
nixos-system-nixos → nixos-system-wsl
+ ~128 MB of nodejs/icu4c/simdjson/…        ε → ∅   (office-hours' closure)
```

The first two lines are one unit being renamed. The unit's bytes are identical
apart from its `Description=`; `ExecStart`, the PATH anchors, `Restart` and the
`StartLimit*` settings all carry over verbatim.

**Run this from a plain interactive shell, not from a background Claude
session.** The daemon unit sets no `KillMode`, so it defaults to control-group
and every background session lives in the daemon's cgroup. Activation stops the
old `dispatch-claude-daemon` unit, which SIGKILLs that whole cgroup — including
the shell, if you launched the switch from inside it. Check before switching:

```sh
cat /proc/self/cgroup      # must NOT name dispatch-claude-daemon.service
```

The activation itself runs in `home-manager-n8.service`, a separate cgroup, so
the switch completes either way; it is your shell that dies. Any in-flight
background session is lost regardless — that is inherent to the restart, and the
new `claude-daemon` unit comes up empty.

Rollback if anything below fails: `sudo nixos-rebuild switch --rollback`.

### QA after the switch

Nix proves the closure is right; it cannot prove any of this. Work down the list.

**Identity and the rename**

- [ ] `hostname` → `wsl`
- [ ] `tailscale status` → `Self` is `wsl`, and the tailnet name is
      `wsl.tail98e96e.ts.net`
- [ ] From the MacBook: `ssh n8@wsl.tail98e96e.ts.net` succeeds
- [ ] `avahi-resolve -n wsl.local` resolves (and `nixos.local` no longer does)
- [ ] `systemctl --failed` is empty

**WezTerm — the piece most exposed by the rename**

- [ ] `systemctl --user status wezterm-mux-server` is active
- [ ] The Windows WezTerm GUI launches and auto-connects. It reads
      `C:\Users\<you>\.wezterm.lua`, which this switch overwrites with the
      `connect wsl` version — confirm the copy happened and the file says `wsl`
- [ ] A remote pane actually opens (this is the mux handshake; a version
      mismatch shows as the window closing immediately)
- [ ] Tailscale-discovered `ssh_domains` still list both machines

**Windows-side bridges (now `hosts/wsl/home/`)**

- [ ] `/mnt/g` is mounted: `mountpoint /mnt/g && ls /mnt/g`
- [ ] `systemctl status mount-gdrive mount-gdrive-heal` — boot unit
      `active (exited)`, healer timer armed
- [ ] `claude --chrome` bridges to Windows Chrome; the native-messaging files
      are in `/mnt/c/Users/<you>/.claude/chrome/`
- [ ] WezTerm Windows GUI install is *not* reinstalled — `windowsInstallEnabled`
      is `false` in `modules/home/wezterm-pin.nix` (a deliberate holding action,
      see item 6), so an existing GUI in `%LOCALAPPDATA%` is left alone

**Shared home config**

- [ ] `git config user.email` → `nathan@natb1.com` (this moved into the shared
      module; it used to be set in the flake's host block)
- [ ] `cat ~/.ssh/authorized_keys` — both keys present, mode `600`
- [ ] `claude --version` runs, and the seccomp filter is where auto-detection
      looks: `ls ~/.npm-global/lib/node_modules/@anthropic-ai/sandbox-runtime/vendor/seccomp/x64/`
- [ ] `nix config show experimental-features` → `nix-command flakes`, and the
      `!include` of `~/.config/nix/access-tokens.conf` is still in
      `~/.config/nix/nix.conf`
- [ ] `docker run --rm hello-world`
- [ ] `gh auth status`, `nvim --version`, `direnv version`, `gpg --version`
- [ ] `echo $EDITOR` → `nvim`; `date` shows Eastern time
- [ ] zsh is still the login shell

**Confirm the intended removals actually happened**

- [ ] `systemctl --user status dispatch-claude-daemon` → no such unit
- [ ] `systemctl --user status claude-daemon` → **active**; it is the same unit
      under a neutral name, so background Claude sessions still work
- [ ] Start a background session and confirm it survives closing its terminal
- [ ] `systemctl list-timers | grep office-hours` → empty

---

## 2. Rename fallout outside this machine

The hostname is the Tailscale node name, so this reaches other devices.

- [ ] Tailscale admin panel: remove the stale `nixos` node if the box
      re-registered as a new machine rather than renaming in place
- [ ] MacBook: update anything pointing at `nixos.tail98e96e.ts.net` or
      `nixos.local` — ssh config, scripts, WezTerm domains
- [ ] MacBook: drop the stale `nixos` entry from `~/.ssh/known_hosts`
- [ ] The `n8@nixos` SSH key comment in `modules/home/default.nix` is now
      misleading. Cosmetic — it is a comment field, not part of the key — but
      worth correcting on the next edit of that file

Not affected, and deliberately left alone: the Windows-registered WSL **distro**
name is still `NixOS`. `wsl.exe -d NixOS` and the `//wsl$/NixOS/...` UNC paths in
`modules/home/wezterm.nix` are correct as written.

---

## 3. Clean up old state on the WSL box

Only after the QA above passes.

- [ ] Remove the dead `/etc/nixos` stub and its three backups. The stub imports
      `commons.systems/worktrees/main/nix/nixos/configuration.nix`, a path that
      no longer exists, so it is already broken — nothing reads it in flake mode.

      ```sh
      sudo rm /etc/nixos/configuration.nix /etc/nixos/configuration.nix.backup*
      ```

- [ ] Remove the unused channels. The system has been flake-built for a while;
      these two are registered but contribute nothing, and a stale channel is the
      usual cause of "why did my rebuild pick up the wrong nixpkgs".

      ```sh
      sudo nix-channel --list      # nixos (24.11), nixos-wsl — both vestigial
      sudo nix-channel --remove nixos
      sudo nix-channel --remove nixos-wsl
      ```

- [ ] Decide about `/etc/office-hours/producer.env`. It is the hand-provisioned
      secret for the office-hours producer, which this repo no longer schedules.
      Delete it (mode 0600, holds credentials) unless something else reads it.
- [ ] `nix-collect-garbage -d` once you are confident in the new generation — the
      dropped nodejs closure is ~128 MB, and old generations pin it until
      collected. This also deletes the rollback target, so not before QA.

---

## 4. Bring the Mac onto this repo

`hosts/mba/default.nix` is written and evaluates, but it has never been built:
darwin derivations cannot be built from Linux, so only its *evaluation* is
verified. Everything below has to happen on the MacBook.

- [x] `git clone …` — repo was already present at `~/natb1/nix-config`.
- [x] `nix flake check` — passed, including the `aarch64-darwin` checks.
- [x] `darwin-rebuild build --flake .#mba` + `nix store diff-closures`. The diff
      was much larger than "nothing structural" because the new flake tracks a
      newer nixpkgs (26.05 → 26.11): most of it is version bumps. On top of that,
      the predicted host→shared-module move (git identity, authorized_keys) and
      deliberate package changes (adds `go`, `google-cloud-sdk`, `gh`, `ripgrep`;
      drops `vim`, `nodejs`, `ruby`, `tmux`). Reviewed, nothing accidental.
- [x] `sudo darwin-rebuild switch --flake .#mba` — applied.
- [x] QA: `git config user.email` = nathan@natb1.com; `authorized_keys` present
      (`n8@nixos`, `n8@Nathans-MacBook-Air.local`); `claude --version` 2.1.258;
      `go version` go1.26.7 resolves to the Nix copy (no Homebrew shadow, so no
      `brew uninstall go` needed).
- [x] Tailscale reaches the WSL box (`nixos`, active direct connection).

**WezTerm decision (reverses the original plan above).** The original intent
here was `programs.wezterm.enable = lib.mkForce false` on macOS, on the premise
the GUI is "installed outside Nix." That premise was false on this machine — the
GUI came *from* Nix under commons.systems, and no external install existed, so
disabling the module left the Mac with **no wezterm GUI and no config** (the
`~/.config/wezterm/wezterm.lua` the GUI reads was gone). Since the Mac needs to
be a `wezterm connect` client to the WSL mux server, and the mux protocol
requires client and server to be the **same** wezterm version, the fix was to
let `modules/home/wezterm.nix` install its default **pinned** build
(`wezterm-package.nix`, currently `20260716-195552-76b606ec`) on macOS too. The
darwin override block in `flake.nix` is now gone; the module's Linux-only mux
service / Windows-copy activation stay inert on darwin via `stdenv.isLinux`.
Verified post-switch: `wezterm --version` = `0-unstable-20260716-195552-76b606ec`
and `~/Applications/Home Manager Apps/WezTerm.app` → the pinned store path.

- [ ] **Version-lockstep with WSL.** The Mac client is now on `20260716` but the
      WSL box still runs the old generation, so its mux server is an older
      wezterm — `wezterm connect nixos` may fail the handshake
      (`unexpected response … UnitResponse`) until §1 is applied. Switching WSL
      onto this flake puts both sides on `20260716` and resolves it.

Note the `lib.mkForce` on `home.username` / `home.homeDirectory` in `flake.nix`
is load-bearing on darwin specifically — it is commented there. Do not "simplify"
it away; darwin eval fails without it.

---

## 5. Finish the WSL-only split

Deliberately left incomplete, because doing it properly means rewriting tests in
the same change that was supposed to prove no regression.

`modules/home/wezterm.nix` still contains WSL-specific behavior behind platform
guards rather than in `hosts/wsl/home/`:

- `home.activation.copyWeztermToWindows` — copies the generated config to
  `/mnt/c/Users/<you>/.wezterm.lua`, guarded on `pkgs.stdenv.isLinux`
- the `extraConfig` block setting `default_prog = { 'wsl.exe', … }` and
  `default_gui_startup_args = { 'connect', 'wsl' }`

Both are WSL-only by this repo's own host-vs-platform rule, and the `isLinux`
guard is actively wrong for a future native NixOS box.

The blocker is `tests/wezterm.test.nix`, which asserts the guard *structure*:

- [ ] `test-homemanager-integration` — asserts macOS disables the activation
      script **via `mkIf`**, inspecting `_type == "if"` and the condition value.
      This test's whole purpose disappears if the module moves.
- [ ] `test-activation-script-runtime`, `test-activation-dag-execution`,
      `test-activation-script-tokens` — all reach into
      `moduleResult.home.activation.copyWeztermToWindows`
- [ ] `tests/wezterm_test.sh` — ~500 lines exercising the Windows-user-detection
      fallback chain and the copy's error codes. Real coverage; it must keep
      running against wherever the script ends up.
- [ ] `test-linux-config` / `test-macos-config` — only affected if the
      `extraConfig` lua moves too (they assert on `default_prog` / `wsl.exe` /
      `'connect', 'wsl'` presence and absence)

Do this as its own commit, with the tests rewritten to target the host module,
and confirm the closure is unchanged afterward — the activation script's *bytes*
should be identical, only its defining file moves.

---

## 6. Other known-parked items inherited from the old repo

- [ ] `windowsInstallEnabled = false` in `modules/home/wezterm-pin.nix`. The
      Windows GUI is pinned by hash against a URL upstream overwrites in place,
      so the pin goes stale on upstream's schedule and breaks the build. The flag
      is a holding action. A real fix is one of: pin the last immutable stable
      release instead of a nightly; fetch at activation time rather than as a
      fixed-output derivation; or mirror the asset somewhere we own. Until then,
      `scripts/sync-wezterm.sh` re-syncs the pin and re-enables the install until
      upstream's next nightly.
- [ ] `stdenv.isLinux` / `stdenv.isDarwin` are deprecated in nixpkgs 26.11 (they
      warn on every eval). Mechanical sweep to `stdenv.hostPlatform.isLinux` /
      `.isDarwin` across `modules/` and `hosts/`.

---

## 7. Retire the old config

Only once both machines are switched and QA'd.

- [ ] `commons.systems` `main` still carries the whole `nix/` tree, and it is
      still the source the running generation came from. Delete it there, with a
      commit message pointing at this repo, so there is exactly one source of
      truth. (The `greenfield` branch already has no `nix/`.)
- [ ] `~/natb1/office-hours-nate` — the two-commit QA harness flake that pinned
      `commons.url = "github:natb1/commons.systems/main"`. It existed to prove the
      framework's module outputs were consumable by a downstream instance. This
      repo has no framework/instance split, so it has nothing left to test.
      Archive or delete the repo.
- [ ] `~/natb1/commons.systems.bare-bak` — unrelated to this migration, but it is
      sitting next to the others; confirm whether it is still wanted.

---

## Deliberately dropped — confirm you do not need them

Not regressions; you asked for these to go. Listed so the loss is explicit and
recoverable from `commons.systems` `main` history if any of it turns out to
matter.

- **`dispatch` / `office-hours` packages** — `nix/packages/`. The `dispatch`
  wrapper exec'd `.claude/skills/dispatch-propagate/scripts/dispatch-tick` out of
  the repo checkout, so it only ever worked from inside `commons.systems`.
- **`office-hours-producer` service + timers** — the hourly encrypted `.benc`
  snapshot into the Drive folder, plus the daily GA4/Search Console/PageSpeed
  analytics collection. **This is the one with ongoing external effect:** the
  snapshot was a freshness floor and chain-liveness heartbeat for the hosted
  reader. Nothing produces it now.
- **`services.dispatchUsageSamples`** — the local capacity sampler feeding the
  office-hours Capacity view.
- **`devShells` (`default` and `cloud`) and the githooks installer** — the
  toolchain and `core.hooksPath` claim for developing `commons.systems` itself.
  They belong with that repo, not with a machine's configuration. If you want a
  dev shell for `commons.systems`, it needs one in its own flake.

**Kept after all, renamed:** the `dispatch-claude-daemon` unit was named and
justified by dispatch, but what it ran was `claude daemon run` — generic Claude
Code background supervision, not dispatch-specific. It lives on as
`modules/home/claude-daemon.nix` (unit `claude-daemon`), de-dispatched, and the
four tests from the old `nix/home/claude-code.test.nix` came with it as
`tests/claude-daemon.test.nix`.
- **`nix/home/wezterm.lua`** — a standalone lua file referenced by nothing
  anywhere on `main`; the real config is generated from `extraConfig`.
