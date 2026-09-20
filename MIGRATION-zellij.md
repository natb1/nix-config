# Migrating the WSL box off WezTerm onto Zellij

Written 2026-09-20. **Nothing here has been applied.** This is the plan; work
down it. It is a sibling to [TODO.md](TODO.md) and assumes that plan's §1 (the
WSL switch) has already landed.

The goal: reach the WSL box from the MacBook's native Terminal *or* from a
browser, with one persistent session behind both, and delete WezTerm from this
repo entirely.

---

## What actually changes

WezTerm is playing four roles here at once. Zellij replaces exactly one of them,
which is why this migration is mostly a *deletion*.

| Role today | After |
| --- | --- |
| Windows GUI terminal — pinned nightly, mirrored into `%LOCALAPPDATA%` | **gone**; Terminal.app and the browser are the GUI |
| `wezterm-mux-server` keeps panes alive across disconnects | zellij session + session serialization |
| Launching the GUI is what boots the WSL VM | **new**: a Windows logon task (Phase 4) |
| `ssh_domains` auto-discovery from `tailscale status` | plain `ssh` over Tailscale — already works |

Two front doors, one session. `zellij attach -c main` over SSH from Terminal.app,
and zellij's built-in web server behind `tailscale serve` for the browser. Both
attach to the *same* session and mirror each other live.

Versions this plan was written against: nixpkgs-unstable carries **zellij
0.45.1**, and `pkgs/by-name/ze/zellij-unwrapped` builds with `withWebServer ?
true`, so the web client (upstream 0.43+) is compiled in. No ttyd, wetty or
gotty is needed. If that default ever flips, the browser front door disappears
silently — the `web_server` option becomes a no-op rather than an error.

---

## The sequencing rule

**Do not delete WezTerm until both front doors are proven.** The Windows GUI is
currently the only thing that starts the WSL VM and the usual way into the box.
SSH over Tailscale is the safety net — confirm `ssh n8@wsl.tail98e96e.ts.net`
works *before* starting, and keep the WezTerm generation around until the QA
checklist at the bottom is clean.

---

## Phase 1 — Add zellij

New `modules/home/zellij.nix`, imported from `modules/home/default.nix`. It
belongs in the shared module, not under `hosts/wsl/`: it evaluates on every
platform, and the Mac wants zellij locally anyway for the remote-attach client
(see Phase 2).

```nix
programs.zellij = {
  enable = true;

  # Leave every enable*Integration false (which is already the home-manager
  # default). They eval `zellij setup --generate-auto-start <shell>`, which
  # starts zellij in EVERY new shell whose $TERM is not "dumb" — including the
  # ssh sessions claude-daemon opens and anything non-interactive that gets a
  # tty. Attach explicitly from the front doors instead.
  enableZshIntegration = false;

  settings = {
    default_shell = "zsh";

    # Session resurrection: what actually replaces the mux server. Without
    # this, a session survives a disconnect but not a `wsl --shutdown`.
    session_serialization = true;
    serialize_pane_viewport = true;
    scrollback_lines_to_serialize = 10000;
    serialization_interval = 60;

    pane_frames = true;
    show_startup_tips = false;

    # LOAD-BEARING. Defaults to "off", which means new sessions refuse to be
    # served by the web server even when it is running and authenticated —
    # the browser front door appears broken for no visible reason. See
    # zellij-utils/src/input/options.rs at v0.45.1.
    web_sharing = "on";
  };
};
```

Two notes on the home-manager module:

- `settings` is rendered to `$XDG_CONFIG_HOME/zellij/config.kdl` through
  `lib.hm.generators.toKDL`. Flat scalars map cleanly; nested KDL nodes
  (`keybinds`, `plugins`, `web_client`) are much easier to write as literal KDL
  in `programs.zellij.extraConfig`.
- Reference `config.programs.zellij.finalPackage` from any unit, never
  `.package`. `finalPackage` is the wrapper that carries `plugins`.

---

## Phase 2 — Front door A: the MacBook's Terminal

Nothing to install on the Mac beyond zellij itself. Add a **separate alias** in
`modules/home/ssh.nix`:

```nix
"wsl" = {                     # plain shell — keep this one clean
  HostName = "wsl.tail98e96e.ts.net";
  User = "n8";
  IdentityFile = "~/.ssh/id_ed25519";
  IdentitiesOnly = true;
};

"wsl-term" = {                # the zellij front door
  HostName = "wsl.tail98e96e.ts.net";
  User = "n8";
  IdentityFile = "~/.ssh/id_ed25519";
  IdentitiesOnly = true;
  RequestTTY = "yes";
  RemoteCommand = "zellij attach -c main";
};
```

The split is deliberate and not cosmetic: `RemoteCommand` on the primary alias
breaks `scp`, `rsync`, `git` over ssh, and anything that shells out to
`ssh wsl` — which includes background Claude sessions. Two aliases, one host.

`programs.ssh.settings` is a freeform `attrsOf anything` taking upstream
OpenSSH directive names in PascalCase, so `RequestTTY` and `RemoteCommand` go in
directly, consistent with the `HostName` / `IdentityFile` keys already in that
file. Do **not** reach for `extraOptions`; current home-manager rejects it with
an assertion.

None of this is required to work: `ssh -t wsl zellij attach -c main` does the
same thing with no config at all. The alias is ergonomics.

**Terminal.app specifics, stated honestly:**

- **Truecolor works on Tahoe.** macOS 26's Terminal added 24-bit color and
  Powerline glyphs — its first real update in two decades. On anything older
  it is 256-color, so pick a zellij theme that degrades gracefully.
- **Enable "Use Option as Meta Key"** in Terminal's profile settings, or every
  `Alt+` binding in zellij is dead.
- **Clipboard is the weak spot.** Zellij copies via OSC 52 by default and
  Terminal.app's OSC 52 support is unverified — test it on day one. If it does
  not work, the options are native Fn-drag selection (set `mouse_mode false` if
  zellij's mouse reporting fights the selection) or `copy_command "clip.exe"`,
  which puts text on the *Windows* clipboard, not the Mac's. There is no clean
  path to the Mac clipboard over ssh if OSC 52 is unsupported. Decide which
  tradeoff you want and write it down in the QA list.

**Bonus, once Phase 3 is up:** zellij 0.44+ can attach to a remote session
natively over HTTPS, no ssh involved:

```sh
zellij attach https://wsl.tail98e96e.ts.net/main --token <login-token> --remember
```

That is the other reason zellij goes in the shared home module.

---

## Phase 3 — Front door B: the browser

Keep zellij's web server on loopback speaking plain HTTP, and let Tailscale
terminate TLS in front of it. Zellij *requires* `--cert`/`--key` for any
non-loopback bind, so this sidesteps certificate management entirely instead of
minting and renewing one by hand.

A home-manager user service on the WSL host:

```nix
systemd.user.services.zellij-web = {
  Unit = {
    Description = "Zellij web server";
    After = [ "default.target" ];
  };
  Service = {
    # `zellij web --start` runs in the FOREGROUND; -d/--daemonize is opt-in,
    # so Type=simple is correct. Defaults are 127.0.0.1:8082; both are passed
    # explicitly so the bind address is visible at the call site rather than
    # inherited from config.kdl.
    ExecStart = "${config.programs.zellij.finalPackage}/bin/zellij web --start --ip 127.0.0.1 --port 8082";
    Restart = "on-failure";
    # See "The cgroup trap" below — without this, restarting the web server
    # kills any session that was created through it.
    KillMode = "process";
  };
  Install.WantedBy = [ "default.target" ];
};
```

And a system oneshot for the proxy. The NixOS tailscale module has **no**
declarative `serve` or `funnel` option — only `extraUpFlags` / `extraSetFlags` /
`extraDaemonFlags`, none of which cover serve — so a unit is the idiom:

```nix
systemd.services.zellij-web-serve = {
  description = "Expose the zellij web server on the tailnet";
  after = [ "tailscaled.service" ];
  wants = [ "tailscaled.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    Restart = "on-failure";
    RestartSec = 10;
  };
  script = "${pkgs.tailscale}/bin/tailscale serve --bg --https=443 http://127.0.0.1:8082";
};
```

Running as root means `services.tailscale.permitCertUid` is not needed; it would
be, if this ever moves to a user unit or to `tailscale cert` directly. Serve
state persists inside tailscaled's own state, so this is idempotent across
reboots and across the `tailscaled-wsl-rebind` restarts in
`modules/nixos/tailscale.nix`. Changing the mapping later may need a
`tailscale serve reset` first.

Then `https://wsl.tail98e96e.ts.net/main` from any browser on the tailnet.
Hitting a session name creates it, attaches to it, *or resurrects* a dead one —
so the URL is bookmarkable and survives reboots.

**One-time manual setup.** None of this belongs in the repo; there is no
agenix/sops here, and the tokens are unrecoverable by design.

- Tailnet admin console: enable **MagicDNS** and **HTTPS Certificates**.
  Without the latter, `tailscale serve --https` cannot get a cert and the unit
  fails loudly, which is the intended behavior.
- `zellij web --create-token --token-name mac` — displayed **once**, stored
  hashed, never retrievable. `--create-read-only-token` mints a watch-only
  token. Manage with `--list-tokens`, `--revoke-token <name>`,
  `--revoke-all-tokens`.
- Tailscale ACLs are the real perimeter; the token is the second factor.
  **Never `tailscale funnel` this.** It is a root-equivalent shell, and
  upstream notes the web server has no rate limiting.

---

## Phase 4 — Keep the WSL VM running

The dependency nobody notices until it bites: today, launching the WezTerm GUI
is what starts the WSL VM. Delete it and the box is unreachable after every
Windows reboot — from the Mac *and* from the browser.

Add a Windows Task Scheduler entry at logon running:

```
wsl.exe -d NixOS --exec /bin/true
```

and check `%UserProfile%\.wslconfig` for a `vmIdleTimeout` that would tear the
VM back down. This can be scripted declaratively from a `home.activation` entry
under `hosts/wsl/home/` using `schtasks.exe`, following exactly the pattern
`claude-in-chrome.nix` already uses for `reg.exe`. Doing it that way keeps the
replacement in-repo rather than as undocumented Windows state — which is the
whole point of the exercise.

Note the distro name stays `NixOS` (Windows-registered), while the NixOS
hostname is `wsl`. TODO.md §2 covers why those differ.

---

## The cgroup trap

This repo has already been bitten by this once — TODO.md §1 documents it for
`dispatch-claude-daemon`, where activation SIGKILLed the whole cgroup including
the shell that launched the switch.

A systemd unit defaults to `KillMode=control-group`: stopping or restarting it
kills **everything** in its cgroup, not just the main process. `zellij attach`
and `zellij web` both spawn the zellij *server* process, which is what actually
owns your session and panes. So any unit that creates a session owns that
session's lifetime, and `home-manager switch` restarting that unit silently
destroys it.

Consequences for this plan:

- `zellij-web` sets `KillMode = "process"` above. Without it, a session created
  by clicking a URL dies the next time the web server restarts — including on
  every `nixos-rebuild switch`, since sd-switch restarts changed units.
- **Do not add a `zellij-main.service` oneshot** that pre-creates the session
  with `zellij attach --create-background main`. It looks tidy and it is a trap:
  `Type=oneshot` + `RemainAfterExit=true` leaves the unit active while the
  session runs in its cgroup, and the next switch kills it.
- Prefer creating sessions **lazily** — the ssh `RemoteCommand` creates on first
  connect, the web client creates on first URL hit, and `session_serialization`
  brings panes back after a reboot regardless. That is fewer moving parts than
  the unit, and it is strictly more robust.
- If a pre-created session is wanted anyway, `KillMode = "process"` on that unit
  is mandatory, and verify `zellij attach -b main` is a no-op when the session
  already exists rather than an error — the flag is documented as "create a
  detached session in the background if one does not exist", which implies but
  does not prove idempotence on re-activation.

`users.users.n8.linger = true` in `modules/nixos/default.nix` is what keeps the
user manager (and therefore sessions and the web server) alive across logouts.
It is already set — it was added for `wezterm-mux-server`; update the comment
rather than dropping the setting.

---

## Phase 5 — Remove WezTerm

Delete outright:

```
modules/home/wezterm.nix
modules/home/wezterm-pin.nix
modules/home/wezterm-package.nix
hosts/wsl/home/wezterm-windows.nix
scripts/sync-wezterm.sh
tests/wezterm.test.nix
tests/wezterm_test.sh          (~500 lines)
```

Edit:

- `modules/home/default.nix` — drop the `./wezterm.nix` import
- `hosts/wsl/home/default.nix` — drop the `./wezterm-windows.nix` import
- `flake.nix` — drop `packages.*.wezterm`, the `weztermTests` bindings in
  `checks`, **and** the entire `mba` override block that does
  `programs.wezterm.enable = lib.mkForce false`; with the module gone there is
  nothing left to force, and leaving it is an eval error
- `modules/home/zsh.nix` — replace `__wezterm_set_git_branch`. It emits
  WezTerm's proprietary OSC 1337 `SetUserVar`, read by the `format-tab-title`
  handler that is being deleted. A plain OSC 2 title is the portable
  replacement: zellij renders it as the pane title, Terminal.app puts it in the
  window bar, and the web client's xterm.js honors it too.

  ```sh
  __term_set_title() {
    local branch; branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    local dir=${PWD/#$HOME/\~}
    if [[ -n $branch ]]; then
      printf '\e]2;%s > %s\a' "$branch" "$dir"
    else
      printf '\e]2;%s\a' "$dir"
    fi
  }
  precmd_functions+=(__term_set_title)
  chpwd_functions+=(__term_set_title)
  ```

- Comment-only corrections: `hosts/wsl/default.nix` (the hostname ↔ mux-domain
  coupling note), `modules/nixos/default.nix` (the `linger = true`
  justification), `README.md` (the `scripts/` line in the Layout block, and the
  pointer to this file), `tests/claude-daemon.test.nix` (one stray mention)

### Regression risk: Windows-username detection

The Windows user-profile detection is duplicated three times in this repo, and
`modules/home/wezterm.nix` holds the **best** implementation — the documented
three-tier chain of `$WEZTERM_WINDOWS_USER` → `cmd.exe /c echo %USERPROFILE%`
piped through `wslpath` → the `ls /mnt/c/Users` heuristic.

`hosts/wsl/home/claude-in-chrome.nix` has only the naive last tier
(`ls | grep -v | head -n1`) and its comment points at
`wezterm-windows.nix:101`, which is about to stop existing. Deleting these files
therefore silently downgrades the Claude-in-Chrome bridge on any machine with
more than one Windows profile directory, and leaves a dangling reference.

Pick one, deliberately, and say so in the commit: lift the three-tier chain into
a shared helper before deleting, or accept the naive tier and fix the comment.
Do not let it happen by accident.

Nothing is uninstalled from Windows by any of this. `windowsInstallEnabled` is
already `false`, so activation has not been touching `%LOCALAPPDATA%` for a
while; an existing GUI stays exactly where it is, which is precisely the manual
rollback you want during QA.

---

## Phase 6 — Tests

`nix flake check` is the gate before a switch, and Phase 5 removes 13 of the
checks it currently runs. Replace them with `tests/zellij.test.nix`, wired into
`flake.nix` the same way `weztermTests` was:

- module structure — `enable` is true, every `enable*Integration` is false
  (the auto-start footgun is a behavioral contract worth pinning)
- `web_sharing` is `"on"` — the failure mode is silent, so assert it
- the two units reference `finalPackage`, not `package`
- `KillMode = "process"` is present on anything that can own a session
- the generated `config.kdl` parses, by running
  `zellij setup --check` against it in a `runCommand` with `$HOME` pointed at a
  temp config dir

On that last one, know what you are buying: `--check` itself always calls
`exit(0)`. The useful signal is that config loading and merging happens *before*
the check runs, so a malformed `config.kdl` fails out of `Setup::from_cli_args`
with a non-zero exit. It is a **parse gate, not a semantic validator** — it will
not catch a plausible-looking but wrong option name. Keep the semantic
assertions as Nix-level checks on the attrset, the way the wezterm suite
asserted on `extraConfig` with `lib.hasInfix`.

---

## Suggested commit sequence

Each of these should build and switch cleanly on its own.

1. `zellij: add the session module` — additive; WezTerm untouched and both
   usable side by side
2. `zellij: serve sessions to the tailnet over tailscale serve`
3. `wsl: start the VM at Windows logon` — removes the hidden dependency
   **before** it can matter
4. `ssh: add the wsl-term front door` + the OSC 2 title swap in zsh
5. `wezterm: remove` — all seven files, the flake edits, the comment sweep,
   with `nix store diff-closures` output in the message
6. `tests: replace the wezterm suite with zellij coverage`

---

## QA checklist

Run after step 5, before `nix-collect-garbage`.

- [ ] `systemctl --user status zellij-web` is active; `systemctl --failed` empty
- [ ] `ssh wsl-term` from Terminal.app lands in the session
- [ ] Close the laptop, reconnect — panes intact
- [ ] `wsl --shutdown` from Windows, reconnect — serialization restored the
      panes and scrollback
- [ ] `https://wsl.tail98e96e.ts.net/main` loads in Safari and in Chrome; the
      login token is accepted
- [ ] A read-only token attaches as a watcher and cannot type
- [ ] Both front doors attached at once show the same session, mirrored live
- [ ] Copy/paste verdict recorded **per front door** (see Phase 2 — this is a
      decision, not a pass/fail)
- [ ] Windows reboot → the box is reachable with nothing launched by hand
- [ ] `ssh wsl` (no `-term`) is still a plain shell; `scp` and `rsync` work
- [ ] A background Claude session still survives closing its terminal
- [ ] `claude --chrome` still bridges — the detection regression above
- [ ] `nix flake check` passes with the new suite
- [ ] Nothing in the repo matches `grep -ri wezterm`

Rollback at any point: `sudo nixos-rebuild switch --rollback`. The Windows
WezTerm GUI is still installed and still launches, so the old path back in
exists until you delete it by hand. Do not `nix-collect-garbage -d` until this
list is clean — it drops the rollback target.

---

## What this closes in TODO.md

- **§5 — "Finish the WSL-only split"** in its entirety. It was blocked on
  rewriting `tests/wezterm.test.nix`, which asserts the *structure* of the
  `mkIf`/`isLinux` guards in a module this plan deletes. The split stops being
  a problem when there is nothing left to split.
- **§6, first bullet — `windowsInstallEnabled = false`.** The byte pin against
  a rolling nightly URL, and the three unattractive real fixes (pin a stable
  release / fetch at activation / mirror the asset), all go away with the
  module.

§6's second bullet (the `stdenv.isLinux` → `stdenv.hostPlatform.isLinux` sweep)
is unaffected and still wants doing; this migration removes several of its call
sites but not all of them.
