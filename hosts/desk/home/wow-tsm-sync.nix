# wow-tsm-sync: keep one WoW account's TradeSkillMaster settings a copy of
# another's. Every minute it checks; once no WoW Forever client has run for a
# minute, and the source or destination TradeSkillMaster.lua changed since
# its last look, it copies the source's TSM settings into the destination
# (wow-tsm-sync.lua says exactly which keys). A client holds its SavedVariables
# in memory and writes them back on logout or /reload, so the copy is only
# made while no client runs: the next login on the destination account loads it.
#
# ── Once by hand ──────────────────────────────────────────────────────────────
#
# Create ~/.local/state/wow-tsm-sync/accounts, one line: the source account
# directory and the destination's, under WTF/Account, separated by a space.
# The account ids stay out of this public repo. Without the file the service
# does nothing.
#
# ── Safety ────────────────────────────────────────────────────────────────────
#
# - Only TradeSkillMaster.lua of the destination is written, through a
#   temporary file in the same directory and a rename, after the Lua reads
#   the result back equal to the merge. The destination as it was is kept in
#   the state directory (TradeSkillMaster.<account>.prev.lua, the last one).
# - Nothing is written when the two files are of different TSM builds, or
#   when the destination already holds every setting.
# - A client seen running, then or just before the rename, defers the copy.
#
# Logs: `journalctl --user -u wow-tsm-sync`. `wow-tsm-sync` runs it by hand.

{ config, pkgs, lib, ... }:

let
  accounts = "/srv/games/wow/_forever_/WTF/Account";
  stateDir = "${config.home.homeDirectory}/.local/state/wow-tsm-sync";
  merge = ./wow-tsm-sync.lua;

  sync = pkgs.writeShellApplication {
    name = "wow-tsm-sync";
    runtimeInputs = [ pkgs.coreutils pkgs.procps pkgs.util-linux pkgs.lua5_1 ];
    text = ''
      state=${lib.escapeShellArg stateDir}
      mkdir -p "$state"
      exec 9>"''${XDG_RUNTIME_DIR:-/tmp}/wow-tsm-sync.lock"
      flock -n 9 || exit 0

      if [ ! -s "$state/accounts" ]; then
        echo "no $state/accounts (one line: source and destination account directories); nothing to do"
        exit 0
      fi
      read -r src_acct dst_acct _ <"$state/accounts" || true
      if [ -z "''${src_acct:-}" ] || [ -z "''${dst_acct:-}" ] || [ "$src_acct" = "$dst_acct" ]; then
        echo "$state/accounts must name two different accounts"
        exit 1
      fi
      src="${accounts}/$src_acct/SavedVariables/TradeSkillMaster.lua"
      dst="${accounts}/$dst_acct/SavedVariables/TradeSkillMaster.lua"
      for f in "$src" "$dst"; do
        [ -f "$f" ] || { echo "no $f yet (log in once on that account with TSM)"; exit 0; }
      done

      # A WoW Forever client is the wine process of _forever_'s Wow.exe.
      client() { pgrep -f '_forever_.Wow\.exe' >/dev/null; }
      now=$(date +%s)
      if client; then
        echo "$now" >"$state/client-seen"
        exit 0
      fi
      seen=$(cat "$state/client-seen" 2>/dev/null || echo 0)
      [ $((now - seen)) -ge 60 ] || exit 0

      stamp=$(stat -c '%Y %s' "$src" "$dst" | tr '\n' ' ')
      [ "$stamp" != "$(cat "$state/last" 2>/dev/null || true)" ] || exit 0
      for f in "$src" "$dst"; do
        [ $((now - $(stat -c %Y "$f"))) -ge 30 ] || exit 0
      done

      tmp="$(dirname "$dst")/.TradeSkillMaster.lua.wow-tsm-sync"
      rm -f "$tmp"
      if ! res=$(lua ${merge} "$src" "$dst" "$tmp" 2>&1); then
        rm -f "$tmp"
        printf 'not synced: %s\n' "$res"
        printf '%s\n' "$stamp" >"$state/last"
        exit 1
      fi
      if [ "$res" = unchanged ]; then
        printf '%s\n' "$stamp" >"$state/last"
        exit 0
      fi
      if client; then
        rm -f "$tmp"
        date +%s >"$state/client-seen"
        echo "a client started during the copy; trying again after it closes"
        exit 0
      fi
      cp -p "$dst" "$state/TradeSkillMaster.$dst_acct.prev.lua"
      mv -f "$tmp" "$dst"
      echo "copied the TSM settings of $src_acct to $dst_acct"
      stat -c '%Y %s' "$src" "$dst" | tr '\n' ' ' >"$state/last"
      echo >>"$state/last"
    '';
  };
in
{
  home.packages = [ sync ];

  systemd.user.services.wow-tsm-sync = {
    Unit = {
      Description = "Copy one WoW account's TSM settings to another once no client runs";
      RequiresMountsFor = [ "/srv/games" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${sync}/bin/wow-tsm-sync";
      NoNewPrivileges = true;
    };
  };

  systemd.user.timers.wow-tsm-sync = {
    Unit.Description = "Check every minute whether the TSM settings need copying";
    Timer = {
      OnCalendar = "minutely";
      AccuracySec = "10s";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
