# wow-sales-rp: an hourly collector of auction-house sales for the private
# wow-plan repo (/srv/git/wow-plan, README.md "RP Horde's sales"). A few
# minutes after each hourly Battle.net auction snapshot, it runs that repo's
# collector (forever/t52p/sales_rp.py, "collect"), taken from origin/main, which
# compares the snapshot with the previous one and keeps daily counts. What it
# measures, and every number, stays in the state directory and the private
# repo's own store; this module only decides when it runs.
#
# ── Once by hand ──────────────────────────────────────────────────────────────
#
# Nothing: the collector reads the Blizzard API client from
# ~/.config/blizzard/credentials, the file the desk refresh already uses.
# Until the collector is on wow-plan's main, each run says so and stops.
#
# ── Safety ────────────────────────────────────────────────────────────────────
#
# - Read-only towards the game and the repo: the script is copied out of
#   origin/main (git show) into the state directory and run from there; the
#   checkout is never touched. The fetch is the only network use of git.
# - It writes only under ~/.local/state/wow-sales-rp. Two Battle.net requests
#   and a token a run; a snapshot already seen does nothing.
# - One run at a time (flock).
#
# Logs: `journalctl --user -u wow-sales-rp`; `wow-sales-rp` runs it by hand.

{ config, pkgs, lib, ... }:

let
  repo = "/srv/git/wow-plan";
  stateDir = "${config.home.homeDirectory}/.local/state/wow-sales-rp";
  python = pkgs.python3.withPackages (ps: [ ps.tzdata ]);

  collect = pkgs.writeShellApplication {
    name = "wow-sales-rp";
    runtimeInputs = [ pkgs.coreutils pkgs.util-linux pkgs.git pkgs.gh python ];
    text = ''
      state=${lib.escapeShellArg stateDir}
      mkdir -p "$state"
      exec 9>"''${XDG_RUNTIME_DIR:-/tmp}/wow-sales-rp.lock"
      flock -n 9 || exit 0

      git -C ${repo} fetch --quiet origin main || echo "fetch failed; using the last fetched main"
      src="$state/sales_rp.py"
      if git -C ${repo} show origin/main:forever/t52p/sales_rp.py >"$src.new" 2>/dev/null; then
        mv -f "$src.new" "$src"
      else
        rm -f "$src.new"
        echo "forever/t52p/sales_rp.py is not on wow-plan's main yet; nothing to do"
        exit 0
      fi
      exec python3 -I "$src" collect --state-dir "$state"
    '';
  };
in
{
  home.packages = [ collect ];

  systemd.user.services.wow-sales-rp = {
    Unit.Description = "Compare the newest auction snapshot with the last (wow-plan sales_rp.py)";
    Service = {
      Type = "oneshot";
      ExecStart = "${collect}/bin/wow-sales-rp";
      NoNewPrivileges = true;
      TimeoutStartSec = "10min";
    };
  };

  # The snapshot changes about 25 minutes past each hour; the later runs catch
  # a late one (a snapshot already seen does nothing).
  systemd.user.timers.wow-sales-rp = {
    Unit.Description = "Collect auction sales after each hourly snapshot";
    Timer = {
      OnCalendar = "*-*-* *:28,43,58:00";
      AccuracySec = "30s";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
