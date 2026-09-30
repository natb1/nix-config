# Claude Code Remote Control, always on.
#
# Runs `claude remote-control --spawn worktree` in a git repo — by default
# ~/natb1/nix-config; see services.claudeRemoteControl.directory — as a
# per-user service — a systemd user unit on Linux, a launchd agent on macOS — so
# the machine is always reachable from claude.ai/code and the Claude app, and
# each session started there gets its own git worktree under .claude/worktrees/.
# It replaces a `claude rc` left running in a terminal; stop any such terminal
# first; while it runs, the service fails with "This folder is already served"
# and retries.
#
# Imported per host from flake.nix (desk and mba), not from modules/home: WSL
# does not get it. desk's second user, drlindsey, imports it too — see
# hosts/desk/drlindsey.nix.
#
# The pre-created session is left on (no --no-create-session-in-dir): rc only
# records its environment in ~/.claude/projects/<dir>/bridge-pointer.json, and
# only asks to reuse it on the next start, when that session is on. With it
# off, every restart registers a new environment and the sessions from the last
# run never reconnect. With it on, a restart within the pointer's 4-hour window
# reuses the environment, re-adopts the same in-repo session rather than
# creating another, and existing claude.ai sessions reconnect. Only
# `--continue`/`--session-id` are named as resume flags, and both are
# single-session only (rejected alongside --spawn).
#
# --permission-mode auto: sessions spawned from claude.ai start in auto mode
# rather than asking for each tool call; switch per session from the mode picker.
#
# Prerequisite, once per machine: the directory must already be trusted — run
# `claude` there interactively and accept the workspace trust dialog. Until then
# rc exits with "Workspace not trusted" and the service keeps retrying.
#
# Logs: only what rc prints while starting up is kept. Those errors and
# warnings go to stderr ("Workspace not trusted", "already served", other
# registration failures, "Could not reuse the previous environment"), and
# stderr goes to `journalctl --user -u claude-remote-control` on Linux and to
# ~/Library/Logs/claude-remote-control.log on macOS. stdout is discarded: rc
# redraws its status screen there about once a second even without a terminal,
# some 2 MB an hour, which would crowd out the rest of the journal and grow the
# Mac's log file, which nothing rotates, without bound. What rc reports once it
# is running goes through that screen and is dropped with it, errors included:
# a session that failed to spawn or to get its worktree, a session declined at
# capacity, a failed token or credential renewal, and the reason it gives up
# and shuts down ("Server unreachable for N minutes, giving up."), after which
# the journal shows only the exit and the restart, and the Mac's log nothing.
# So are the per-session lines: a session completed or failed, a worktree
# removed.
#
# ── Why ExecStart names the profile symlink, unlike claude-daemon.nix ─────────
#
# claude-daemon.nix pins the concrete store path so every claude-code bump
# restarts the daemon onto the new binary. Here that is the wrong trade: the
# sessions rc spawns live in its cgroup, so a restart at activation would kill
# every open session, including one that ran `nixos-rebuild build` or a flake
# check.
# The profile path keeps the unit's bytes stable across bumps — activation leaves
# the running server alone, and it moves to the new binary on its next start
# (reboot, crash, or `systemctl --user restart claude-remote-control`). PATH
# likewise uses stable anchors only, for the same reason.
#
# ── No root from a session ────────────────────────────────────────────────────
#
# Sessions run in auto mode and are driven from claude.ai, so they get no root,
# even where sudo needs no password (desk's wheel). On Linux, NoNewPrivileges
# makes setuid and file capabilities no-ops for rc and everything it spawns:
# sudo, su and mount fail even by their full /run/wrappers/bin path. launchd has
# no such switch; on the Mac, sudo asks for a password a session cannot type. PATH also leaves the
# wrappers out, so the sudo a session finds is the plain one and fails at once.
# A session can build and check; the switch is yours — `rebuild` in a terminal,
# or Mod+Shift+R on desk (hosts/desk/rebuild-menu.nix) to switch to a session's
# worktree.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  inherit (config.services.claudeRemoteControl) directory;

  # Stable anchors only — see the header. The per-user profile is where
  # useUserPackages puts claude and the rest of home.packages. No
  # /run/wrappers/bin: see "No root from a session".
  userProfile = "/etc/profiles/per-user/${config.home.username}/bin";
  path = lib.concatStringsSep ":" (lib.unique (
    [
      "${config.home.profileDirectory}/bin"
      userProfile
      "/run/current-system/sw/bin"
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
      "/nix/var/nix/profiles/default/bin"
      "/usr/bin"
      "/bin"
      "/usr/sbin"
      "/sbin"
    ]
  ));

  args = [
    "${userProfile}/claude"
    "remote-control"
    "--spawn"
    "worktree"
    "--permission-mode"
    "auto"
  ];
in
{
  options.services.claudeRemoteControl.directory = lib.mkOption {
    type = lib.types.str;
    default = "${config.home.homeDirectory}/natb1/nix-config";
    description = "Git repo the rc server serves; worktree sessions branch from it.";
  };

  config.systemd.user.services.claude-remote-control = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    Unit = {
      Description = "Claude Code Remote Control server (worktree spawn mode)";
    };
    Service = {
      Type = "simple";
      WorkingDirectory = directory;
      ExecStart = lib.escapeShellArgs args;
      Environment = [ "PATH=${path}" ];
      NoNewPrivileges = true;
      # The status screen, and the runtime errors printed through it, are
      # dropped; startup errors are kept — see the header. stderr is named
      # because the user manager's default for it is to follow stdout.
      StandardOutput = "null";
      StandardError = "journal";
      Restart = "always";
      # rc exits after ~a minute on errors it reports (untrusted folder, folder
      # already served); don't hammer it beyond that. It also exits at boot when
      # it starts before DNS works ("getaddrinfo ENOTFOUND"): the user manager
      # has no network-online.target to wait for, so this retry is what brings
      # it up.
      RestartSec = 10;
    };
    Install.WantedBy = [ "default.target" ];
  };

  config.launchd.agents.claude-remote-control = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    enable = true;
    config = {
      ProgramArguments = args;
      WorkingDirectory = directory;
      EnvironmentVariables.PATH = path;
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      # No StandardOutPath, so launchd sends stdout to /dev/null — see the header.
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/claude-remote-control.log";
    };
  };
}
