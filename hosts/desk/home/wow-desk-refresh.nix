# The WoW Forever desk refresh: a headless Claude Code session that runs
# whenever a local data source changes, so no interactive session has to stay
# open. What the session does is defined by the private wow-plan repo
# (/srv/git/wow-plan, README.md "The desk refresh"); this module only decides
# when it runs and how it is started. Nothing from the plan (its data, its
# results, its accounts) is in this repo.
#
# ── Sources ───────────────────────────────────────────────────────────────────
#
# - TSM's AppData.lua (TradeSkillMaster_AppHelper), rewritten by the TSM
#   desktop app on every sync: wow-desk-refresh-tsm.path.
# - The ForeverPlanLog addon's SavedVariables, one per WoW account, rewritten
#   on a /reload, a logout and the addon's Save scan button:
#   wow-desk-refresh-sv@<account>.path, one instance per account directory.
#
# ── Why a template for the accounts ───────────────────────────────────────────
#
# PathChanged= takes no glob, and the account directory names are game
# account ids, which stay out of this public repo. So the per-account path
# unit is a template, and wow-desk-refresh-accounts.service starts one
# instance for each WTF/Account/*/SavedVariables directory it finds: at login,
# and whenever WTF/Account itself changes (a new account), through
# wow-desk-refresh-accounts.path. Watching each SavedVariables directory
# instead would fire on every other addon's file too; watching the file itself
# fires only for this addon. The instances are started, not enabled, so they
# last until logout and are rediscovered at the next login.
#
# ── Debounce and no overlap ───────────────────────────────────────────────────
#
# One logout writes every character's files within seconds, and the TSM app
# writes in bursts. The service waits until no source has changed for 45
# seconds (at most 15 minutes) before it starts the session. A trigger while
# the service is running starts nothing, because systemd does not start a unit
# that is already activating; the run then checks before exiting whether a
# source changed during it and goes again (up to three passes). A flock covers
# a manual run from a shell (`wow-desk-refresh`) alongside the service.
#
# The hourly timer (:25, before the cloud run at :30) is the fallback for a
# missed event. It does nothing when no source has changed since the last
# finished run, so an idle desk costs no session; `wow-desk-refresh --force`
# runs regardless.
#
# ── Why a background session, not `claude -p` ─────────────────────────────────
#
# Probed 2026-11-21 with claude-code 2.1.326, in a fresh worktree of
# wow-plan: a `claude -p` session has the claude.ai Gmail connector but no
# Artifact or ArtifactData tools, and the refresh writes to an artifact's
# database. A background session (`claude --bg`, hosted by claude-daemon.service,
# modules/home/claude-daemon.nix) has all three. So the service starts one,
# waits for it to finish, copies its last message to the journal and removes it
# from the session list (`claude agents`).
#
# Because the session lives in the daemon's cgroup, TimeoutStartSec cannot kill
# it; the script stops it itself (`claude stop`) at its 30-minute deadline.
# The daemon has NoNewPrivileges and no setuid wrappers on PATH, so the session
# gets no root, like every background session.
#
# ── Permissions ───────────────────────────────────────────────────────────────
#
# --permission-mode dontAsk: nothing prompts (no one is there to answer), and
# anything not allowed by the settings is denied rather than run. What the
# refresh may do is the allow list in wow-plan's .claude/settings.json, which
# is reviewed with the procedure it serves. No --dangerously-skip-permissions.
#
# ── The worktree ──────────────────────────────────────────────────────────────
#
# Each run gets a detached worktree of origin/main under
# /srv/git/wow-plan/.claude/worktrees/desk-refresh-<time>, so it runs the
# merged procedure, not whatever the main checkout has. It is removed after
# the run; leftovers from a crashed run are removed by the next one. The
# procedure's own state between runs belongs in ~/.local/state/wow-desk-refresh
# (StateDirectory), which the session is told in its system prompt.
#
# Logs: `journalctl --user -u wow-desk-refresh`. The full transcript stays in
# ~/.claude/projects/ (`claude --resume` lists it).

{ config, pkgs, lib, ... }:

let
  forever = "/srv/games/wow/_forever_";
  appData = "${forever}/Interface/AddOns/TradeSkillMaster_AppHelper/AppData.lua";
  accounts = "${forever}/WTF/Account";
  repo = "/srv/git/wow-plan";
  prompt = "Run the desk refresh exactly as README.md 'The desk refresh' says.";

  # Stable anchors only, as in claude-daemon.nix; no /run/wrappers/bin.
  path = lib.concatStringsSep ":" (lib.unique [
    "${config.home.profileDirectory}/bin"
    "/etc/profiles/per-user/${config.home.username}/bin"
    "/run/current-system/sw/bin"
  ]);

  refresh = pkgs.writeShellApplication {
    name = "wow-desk-refresh";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.git pkgs.jq pkgs.util-linux ];
    text = ''
      force=0
      [ "''${1:-}" = --force ] && force=1
      state="''${STATE_DIRECTORY:-$HOME/.local/state/wow-desk-refresh}"
      mkdir -p "$state"
      stamp="$state/last-source-mtime"

      exec 9>"''${XDG_RUNTIME_DIR:-/tmp}/wow-desk-refresh.lock"
      if ! flock -n 9; then
        echo "another desk refresh is running; this trigger is covered by it"
        exit 0
      fi

      newest() {
        local files=("${appData}")
        shopt -s nullglob
        files+=("${accounts}"/*/SavedVariables/ForeverPlanLog.lua)
        shopt -u nullglob
        local n
        n=$({ stat -c %Y "''${files[@]}" 2>/dev/null || true; } | sort -n | tail -1)
        echo "''${n:-0}"
      }

      # Debounce: wait for 45 quiet seconds, at most 15 minutes.
      settle() {
        local t0 now
        t0=$(date +%s)
        while now=$(date +%s); [ $((now - $(newest))) -lt 45 ] && [ $((now - t0)) -lt 900 ]; do
          sleep 5
        done
      }

      # Leftover worktrees of a crashed run (none is in use: we hold the lock).
      for old in "${repo}"/.claude/worktrees/desk-refresh-*; do
        [ -d "$old" ] || continue
        echo "removing leftover worktree $old"
        git -C "${repo}" worktree remove --force "$old" || true
      done
      git -C "${repo}" worktree prune

      run_session() {
        local wt out sid id rec st status seen t0 deadline result transcript
        git -C "${repo}" fetch --quiet origin main
        wt="${repo}/.claude/worktrees/desk-refresh-$(date +%Y%m%dT%H%M%S)"
        git -C "${repo}" worktree add --quiet --detach "$wt" origin/main
        echo "worktree $wt at $(git -C "$wt" rev-parse --short HEAD)"
        # --bg picks the session id itself (it ignores --session-id) and
        # prints it: "backgrounded · <id> · <name>".
        out=$(cd "$wt" && claude --bg -n "desk-refresh-$(date +%H%M)" \
          --permission-mode dontAsk \
          --append-system-prompt "This is an unattended desk refresh started by wow-desk-refresh.service. No one is watching and nothing can be asked: finish, or stop and say why. Keep the procedure's state between runs in $state." \
          "${prompt}" </dev/null 2>&1) || { printf '%s\n' "$out"; return 1; }
        id=$(sed -n 's/^backgrounded · \([0-9a-f]*\).*/\1/p' <<<"$out" | head -1)
        if [ -z "$id" ]; then
          printf 'could not start the session:\n%s\n' "$out"
          git -C "${repo}" worktree remove --force "$wt" || true
          return 1
        fi
        echo "session $id started"
        t0=$(date +%s) deadline=$(( $(date +%s) + 1800 ))
        sid="" status=0 seen=0
        while :; do
          rec=$(claude agents --json 2>/dev/null | jq -c --arg i "$id" 'map(select(.id == $i)) | .[0] // empty')
          [ -n "$rec" ] || break
          sid=$(jq -r '.sessionId // empty' <<<"$rec")
          st=$(jq -r '"\(.status // "")/\(.state // "")"' <<<"$rec")
          # Finished once it is no longer working, but only after it was
          # seen working (or two minutes passed), so a session that is still
          # starting up never has its worktree removed under it.
          case "$st" in
            */working | busy/*) seen=1 ;;
            *) [ "$seen" = 1 ] || [ $(( $(date +%s) - t0 )) -ge 120 ] && break ;;
          esac
          if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "deadline reached; stopping session $id"
            claude stop "$id" || true
            status=1
            break
          fi
          sleep 15
        done
        transcript=""
        [ -n "$sid" ] && transcript=$(find "$HOME/.claude/projects" -name "$sid.jsonl" -print -quit)
        if [ -n "$transcript" ]; then
          result=$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | last // ""' "$transcript")
          echo "session $id ended; its last message:"
          printf '%s\n' "$result"
        else
          echo "session $id left no transcript"
          status=1
        fi
        claude rm "$id" >/dev/null 2>&1 || true
        git -C "${repo}" worktree remove --force "$wt" || true
        return "$status"
      }

      if [ "$force" = 0 ] && [ -f "$stamp" ] && [ "$(newest)" -le "$(cat "$stamp")" ]; then
        echo "no source changed since the last refresh"
        exit 0
      fi
      for pass in 1 2 3; do
        settle
        mark=$(newest)
        echo "pass $pass: newest source $(date -d "@$mark" '+%F %T')"
        run_session
        echo "$mark" >"$stamp"
        [ "$(newest)" -gt "$mark" ] || exit 0
        echo "a source changed during the run; going again"
      done
    '';
  };

  discover = pkgs.writeShellApplication {
    name = "wow-desk-refresh-accounts";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      for sv in "${accounts}"/*/SavedVariables; do
        [ -d "$sv" ] || continue
        acct=$(basename "$(dirname "$sv")")
        unit="wow-desk-refresh-sv@$(systemd-escape "$acct").path"
        systemctl --user start "$unit"
        echo "watching $unit"
      done
    '';
  };
in
{
  home.packages = [ refresh ];

  systemd.user.services.wow-desk-refresh = {
    Unit = {
      Description = "WoW Forever desk refresh (headless Claude Code session)";
      Wants = [ "claude-daemon.service" ];
      After = [ "claude-daemon.service" ];
      RequiresMountsFor = [ "/srv/games" "/srv/git" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${refresh}/bin/wow-desk-refresh";
      Environment = [ "PATH=${path}" ];
      StateDirectory = "wow-desk-refresh";
      NoNewPrivileges = true;
      # Three passes of a 15-minute settle and a 30-minute session, at worst.
      TimeoutStartSec = "150min";
    };
  };

  systemd.user.timers.wow-desk-refresh = {
    Unit.Description = "WoW Forever desk refresh, hourly fallback";
    Timer = {
      OnCalendar = "*-*-* *:25:00";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  systemd.user.paths.wow-desk-refresh-tsm = {
    Unit.Description = "Watch TSM's AppData.lua for the desk refresh";
    Path = {
      PathChanged = appData;
      Unit = "wow-desk-refresh.service";
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.paths."wow-desk-refresh-sv@" = {
    Unit.Description = "Watch WoW account %I's ForeverPlanLog.lua for the desk refresh";
    Path = {
      PathChanged = "${accounts}/%I/SavedVariables/ForeverPlanLog.lua";
      Unit = "wow-desk-refresh.service";
    };
  };

  systemd.user.services.wow-desk-refresh-accounts = {
    Unit = {
      Description = "Watch every WoW Forever account's ForeverPlanLog.lua";
      RequiresMountsFor = [ "/srv/games" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${discover}/bin/wow-desk-refresh-accounts";
      Environment = [ "PATH=${path}" ];
      NoNewPrivileges = true;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.paths.wow-desk-refresh-accounts = {
    Unit.Description = "Watch WoW Forever's account list for a new account";
    Path.PathChanged = accounts;
    Install.WantedBy = [ "default.target" ];
  };
}
