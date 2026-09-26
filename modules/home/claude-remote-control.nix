# Claude Code Remote Control, always on.
#
# Runs `claude remote-control --spawn worktree` in ~/natb1/nix-config as a
# per-user service — a systemd user unit on Linux, a launchd agent on macOS — so
# the machine is always reachable from claude.ai/code and the Claude app, and
# each session started there gets its own git worktree under .claude/worktrees/.
# It replaces a `claude rc` left running in a terminal; stop any such terminal
# first; while it runs, the service fails with "This folder is already served"
# and retries.
#
# Imported per host from flake.nix (desk and mba), not from modules/home: WSL
# does not get it.
#
# --no-create-session-in-dir: by default rc pre-creates a session in the repo on
# every start. For a service that restarts with the machine, that is an empty
# session per boot; sessions are started on demand from claude.ai instead.
#
# Prerequisite, once per machine: the directory must already be trusted — run
# `claude` there interactively and accept the workspace trust dialog. Until then
# rc exits with "Workspace not trusted" and the service keeps retrying.
#
# ── Why ExecStart names the profile symlink, unlike claude-daemon.nix ─────────
#
# claude-daemon.nix pins the concrete store path so every claude-code bump
# restarts the daemon onto the new binary. Here that is the wrong trade: the
# sessions rc spawns live in its cgroup, and `rebuild` is routinely run from one
# of them, so a restart at activation would kill the session doing the switch.
# The profile path keeps the unit's bytes stable across bumps — activation leaves
# the running server alone, and it moves to the new binary on its next start
# (reboot, crash, or `systemctl --user restart claude-remote-control`). PATH
# likewise uses stable anchors only, for the same reason.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  directory = "${config.home.homeDirectory}/natb1/nix-config";

  # Stable anchors only — see the header. The per-user profile is where
  # useUserPackages puts claude and the rest of home.packages.
  userProfile = "/etc/profiles/per-user/${config.home.username}/bin";
  path = lib.concatStringsSep ":" (lib.unique (
    [
      "${config.home.profileDirectory}/bin"
      userProfile
      "/run/current-system/sw/bin"
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ "/run/wrappers/bin" ]
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
    "--no-create-session-in-dir"
  ];
in
{
  systemd.user.services.claude-remote-control = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    Unit = {
      Description = "Claude Code Remote Control server (worktree spawn mode)";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      WorkingDirectory = directory;
      ExecStart = lib.escapeShellArgs args;
      Environment = [ "PATH=${path}" ];
      Restart = "always";
      # rc exits after ~a minute on errors it reports (untrusted folder, folder
      # already served); don't hammer it beyond that.
      RestartSec = 10;
    };
    Install.WantedBy = [ "default.target" ];
  };

  launchd.agents.claude-remote-control = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    enable = true;
    config = {
      ProgramArguments = args;
      WorkingDirectory = directory;
      EnvironmentVariables.PATH = path;
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/claude-remote-control.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/claude-remote-control.log";
    };
  };
}
