# Claude Code background session daemon.
#
# Runs `claude daemon run` as a systemd user service — the supervisor that hosts
# durable background Claude sessions, so they survive the terminal that launched
# them. Generic Claude Code functionality; it carries no dependency on any
# particular repo or workflow.
#
# Linux only: this is a `systemd --user` unit. macOS would need a launchd agent,
# which nothing here needs yet, so the module is a no-op there.
#
# ── Why ExecStart pins a concrete store path ──────────────────────────────────
#
# ExecStart names the CONCRETE ${pkgs.claude-code} store path, not the profile
# symlink, and that is load-bearing. Because the store path is part of the unit's
# rendered bytes, the unit changes on every claude-code version bump, so
# home-manager's sd-switch (startServices defaults to true) restarts the daemon
# onto the new binary at activation. A long-running process never re-resolves the
# profile symlink, so with `~/.nix-profile/bin/claude` here the daemon — and every
# background session it forks — would keep executing the old binary until someone
# ran `systemctl --user restart claude-daemon.service` by hand.
#
# The inverse constraint applies to Environment below: build PATH ONLY from
# stable directory anchors (profile dirs, /run/current-system), never from
# per-generation store paths. Otherwise an unrelated activation would change the
# unit's bytes and trigger a gratuitous restart. The per-generation-varying token
# stays confined to ExecStart.
#
# ── Restart kills the session tree (accepted) ─────────────────────────────────
#
# The unit sets no KillMode, so it defaults to control-group and every background
# session lives in the daemon's cgroup. An sd-switch restart therefore SIGKILLs
# that cgroup, ending in-flight background sessions at activation time. That is
# accepted for a deliberate upgrade — but it does mean a `nixos-rebuild switch`
# run from inside a background session kills its own shell. Switch from a plain
# interactive shell (`cat /proc/self/cgroup` should not name this unit).
#
# Invariants above are locked by tests/claude-daemon.test.nix.

{
  config,
  pkgs,
  lib,
  ...
}:

{
  systemd.user.services.claude-daemon = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    Unit = {
      Description = "Claude Code durable background session supervisor";
      After = [ "network-online.target" ];
      StartLimitIntervalSec = 60;
      StartLimitBurst = 10;
    };
    Service = {
      Type = "simple";
      # Concrete store path — see the header. Do not replace with the profile
      # symlink; that is the regression the tests guard against.
      ExecStart = "${pkgs.claude-code}/bin/claude daemon run";
      # The systemd USER manager's own PATH is minimal (systemd's bin only) — it
      # does NOT contain git/jq/gh/claude. The daemon forks sessions that run
      # those, and they inherit the SERVICE env, so PATH must be set here. Stable
      # anchors only — see the header.
      Environment = [
        "PATH=${config.home.profileDirectory}/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/run/wrappers/bin"
      ];
      Restart = "always";
      RestartSec = 1;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
