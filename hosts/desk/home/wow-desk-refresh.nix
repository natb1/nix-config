# The WoW Forever desk refresh: a headless Claude Code session that runs
# whenever a local data source changes, so no interactive session has to stay
# open. What the session does is defined by the private wow-plan repo
# (/srv/git/wow-plan, README.md "The desk refresh"); this module only decides
# when it runs, how it is started and what it may do. Nothing from the plan
# (its data, its results, its accounts, its email recipient) is in this repo.
#
# ── Once by hand ──────────────────────────────────────────────────────────────
#
# Create ~/.local/state/wow-desk-refresh/recipient, holding the address the
# refresh emails (one line). It is kept out of this public repo; the
# procedure reads it from there. Without it the service still runs, and says
# in the journal that the file is missing.
#
# ── Sources ───────────────────────────────────────────────────────────────────
#
# - TSM's AppData.lua (TradeSkillMaster_AppHelper): wow-desk-refresh-tsm.path.
# - The ForeverPlanLog addon's SavedVariables, one per WoW account, rewritten
#   on a /reload, a logout and the addon's Save scan button:
#   wow-desk-refresh-sv@<account>.path, one instance per account directory.
#
# ── Content, not mtime ────────────────────────────────────────────────────────
#
# The TSM desktop app rewrites AppData.lua about twice an hour all day, mostly
# its realm blocks, which the refresh does not use. So a trigger only wakes
# the script: it hashes what the refresh reads (each ForeverPlanLog.lua, and
# AppData.lua's Forever-US region sale and region stat lines, or the whole
# file if those lines are not found) and starts a session only when a hash
# differs from the last finished run's, kept in the state directory
# (source-hashes). An unchanged write costs a few hashes and no session.
# `wow-desk-refresh --force` runs regardless.
#
# ── Why a template for the accounts ───────────────────────────────────────────
#
# PathChanged= takes no glob, and the account directory names are game
# account ids, which stay out of this public repo. So the per-account path
# unit is a template, and wow-desk-refresh-accounts.service starts one
# instance for each WTF/Account/<account> directory, whether or not its
# SavedVariables exist yet (a path unit on a missing file watches the nearest
# existing parent and fires when the file appears). It runs at login, when
# WTF/Account itself changes (wow-desk-refresh-accounts.path), and with every
# refresh run (Wants=), so the hourly timer also catches a new account.
# Watching the file rather than its directory means other addons' files never
# fire it. The instances are started, not enabled, so they last until logout.
#
# ── Debounce and no overlap ───────────────────────────────────────────────────
#
# One logout writes every character's files within seconds. Once a hash has
# changed, the service waits until no source has been written for 10 seconds
# (at most 15 minutes), hashes again and starts the session. A trigger while
# the service is running starts nothing, because systemd does not start a unit
# that is already activating; the run checks before exiting whether a hash
# changed during it and goes again (up to three passes). A flock covers a
# manual run from a shell (`wow-desk-refresh`) alongside the service.
#
# The hourly timer (:50, away from the cloud run at :30) is the fallback for a
# missed event; with Persistent= it also runs once after a boot that missed it.
#
# ── Why a background session, not `claude -p` ─────────────────────────────────
#
# Probed 2026-11-21 with claude-code 2.1.326, in a fresh worktree of
# wow-plan: a `claude -p` session has the claude.ai Gmail connector but no
# Artifact or ArtifactData tools, and the refresh writes to an artifact's
# database. A background session (`claude --bg`, hosted by claude-daemon.service,
# modules/home/claude-daemon.nix) has all three. So the service starts one,
# waits for it to finish, copies its last message to the journal, then stops
# it and removes it from the session list (`claude agents`).
#
# Finished means the session's `status` (from `claude agents --json --all`)
# went from busy to idle, or the session exited (no status). Its `state` is
# the post-turn verdict and can stay "working" on an idle session, so it is
# not used.
#
# Because the session lives in the daemon's cgroup, TimeoutStartSec cannot kill
# it; the script stops it itself (`claude stop`) at its 30-minute deadline, and
# on any exit, error or signal before it was removed. The daemon has
# NoNewPrivileges and no setuid wrappers on PATH, so the session gets no root.
#
# ── Permissions ───────────────────────────────────────────────────────────────
#
# The session gets exactly the grants on its own command line, nothing from
# the user's or the repo's settings files:
# - `--setting-sources local` drops ~/.claude/settings.json (whose allow
#   rules include git commit and push and gh) and wow-plan's checked-in
#   .claude/settings.json. The worktree is cleaned each run, so it has no
#   .claude/settings.local.json, and the session may not write one.
# - `--settings` loads the settings below from the store: the allow list, the
#   deny list and a PreToolUse hook. The hook refuses every Artifact delete,
#   and every Bash command except the three desk_refresh.py steps (prepare, run, done), written
#   plainly (no ; & | $ ` ( ) < > \ or newline). Claude Code would otherwise
#   run read-only commands such as ls or cat without a rule.
# - `--permission-mode dontAsk`: nothing prompts (no one is there to answer),
#   and anything not allowed is denied rather than run.
#
# ── The worktree ──────────────────────────────────────────────────────────────
#
# Every run uses the one worktree /srv/git/wow-plan/.claude/worktrees/desk-refresh,
# detached at origin/main and cleaned (checkout --force, clean -ffdx), so it
# runs the merged procedure, not whatever the main checkout has, and
# ~/.claude/projects keeps one directory for it. It is reset only when no
# live session has its cwd there: a busy one makes the run wait for the next
# trigger, and an idle leftover from a killed run is stopped and removed first.
# The worktree is kept between runs. The procedure's own state between runs
# belongs in ~/.local/state/wow-desk-refresh, which the session is told.
#
# Logs: `journalctl --user -u wow-desk-refresh`. The full transcript stays in
# ~/.claude/projects/ (`claude --resume` lists it).

{ config, pkgs, lib, ... }:

let
  forever = "/srv/games/wow/_forever_";
  appData = "${forever}/Interface/AddOns/TradeSkillMaster_AppHelper/AppData.lua";
  accounts = "${forever}/WTF/Account";
  repo = "/srv/git/wow-plan";
  worktree = "${repo}/.claude/worktrees/desk-refresh";
  stateDir = "${config.home.homeDirectory}/.local/state/wow-desk-refresh";
  prompt = "Run the desk refresh exactly as README.md 'The desk refresh' says.";
  step = "python3 -I forever/t52p/desk_refresh.py";

  # Stable anchors only, as in claude-daemon.nix; no /run/wrappers/bin.
  path = lib.concatStringsSep ":" (lib.unique [
    "${config.home.profileDirectory}/bin"
    "/etc/profiles/per-user/${config.home.username}/bin"
    "/run/current-system/sw/bin"
  ]);

  # The PreToolUse hook (see Permissions above). Exit 2 blocks the call and
  # shows the session the message.
  guard = pkgs.writeShellApplication {
    name = "wow-desk-refresh-guard";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      input=$(cat)
      block() { echo "wow-desk-refresh: $1" >&2; exit 2; }
      case "$(jq -r '.tool_name // ""' <<<"$input")" in
        Artifact)
          [ "$(jq -r '.tool_input.action // "publish"' <<<"$input")" != delete ] ||
            block "the desk refresh never deletes an artifact or an asset"
          ;;
        Bash)
          cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
          if [[ $cmd == *[\;\&\|\`\$\(\)\<\>\\]* || $cmd == *$'\n'* ]]; then
            block "only plain '${step} prepare', '${step} run ...' and '${step} done ...' commands, from the worktree root, with no other shell syntax"
          fi
          case "$cmd" in
            "${step} prepare" | "${step} prepare "* | "${step} run" | "${step} run "* | "${step} done" | "${step} done "*) ;;
            *) block "Bash may only run '${step} prepare', '${step} run ...' and '${step} done ...'" ;;
          esac
          ;;
      esac
      exit 0
    '';
  };

  # Absolute paths in permission rules start with // (a single / is relative
  # to the settings file).
  settings = pkgs.writeText "wow-desk-refresh-settings.json" (builtins.toJSON {
    disableBypassPermissionsMode = "disable";
    permissions = {
      defaultMode = "dontAsk";
      allow = [
        "ArtifactData"
        "Artifact"
        "mcp__claude_ai_Gmail__send_message"
        "ToolSearch"
        "Read"
        "Edit(/${stateDir}/**)"
        "Write(/${stateDir}/**)"
        "Edit(/${worktree}/**)"
        "Write(/${worktree}/**)"
        "Bash(${step} prepare:*)"
        "Bash(${step} run:*)"
        "Bash(${step} done:*)"
      ];
      deny = [
        "Bash(git:*)"
        "Bash(gh:*)"
        "Edit(/${worktree}/.claude/**)"
        "Write(/${worktree}/.claude/**)"
        "Edit(/${worktree}/.git)"
        "Write(/${worktree}/.git)"
        "Read(~/.config/blizzard/**)"
        "Read(~/.claude/.credentials.json)"
        "Read(~/.ssh/**)"
      ];
    };
    hooks.PreToolUse = [{
      matcher = "^(Artifact|Bash)$";
      hooks = [{ type = "command"; command = "${guard}/bin/wow-desk-refresh-guard"; }];
    }];
  });

  systemPrompt = lib.concatStringsSep " " [
    "This is an unattended desk refresh started by wow-desk-refresh.service."
    "No one is watching and nothing can be asked: finish, or stop and say why."
    "The state directory is ${stateDir}: keep the procedure's state between runs there."
    "The email recipient is the one line of ${stateDir}/recipient."
    "Bash may run only '${step} prepare', '${step} run ...' and '${step} done ...', from the worktree root, with no cd, pipes, redirects or other shell syntax."
    "Write only under the state directory or this worktree. Never delete an artifact or an asset."
  ];

  # The session's command line, as a list; the flake check reads it back from
  # the built script.
  claudeArgs = [
    "--bg"
    "--permission-mode" "dontAsk"
    "--setting-sources" "local"
    "--settings" "${settings}"
    "--append-system-prompt" systemPrompt
  ];

  refresh = pkgs.writeShellApplication {
    name = "wow-desk-refresh";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.git pkgs.jq pkgs.util-linux ];
    text = ''
      force=0
      [ "''${1:-}" = --force ] && force=1
      state=${lib.escapeShellArg stateDir}
      wt=${lib.escapeShellArg worktree}
      mkdir -p "$state"
      hashes="$state/source-hashes"
      claude_args=(${lib.escapeShellArgs claudeArgs})

      exec 9>"''${XDG_RUNTIME_DIR:-/tmp}/wow-desk-refresh.lock"
      if ! flock -n 9; then
        echo "another desk refresh is running; this trigger is covered by it"
        exit 0
      fi

      svs() {
        shopt -s nullglob
        local f=("${accounts}"/*/SavedVariables/ForeverPlanLog.lua)
        shopt -u nullglob
        [ "''${#f[@]}" = 0 ] || printf '%s\n' "''${f[@]}"
      }

      # What the refresh reads: each ForeverPlanLog.lua whole, and TSM's
      # Forever-US region blocks (one line each), or all of AppData.lua if
      # its format changed.
      current_hashes() {
        local f h
        while read -r f; do
          sha256sum "$f"
        done < <(svs)
        if [ -f "${appData}" ]; then
          h=$(grep -E '^select\(2, \.\.\.\)\.LoadData\("AUCTIONDB_REGION_(SALE|STAT)","Forever-US"' "${appData}" | sha256sum) ||
            h=$(sha256sum <"${appData}")
          echo "''${h%% *}  TSM region data"
        fi
      }

      newest() {
        local n
        n=$({ svs; echo "${appData}"; } | xargs -d '\n' stat -c %Y 2>/dev/null | sort -n | tail -1) || true
        echo "''${n:-0}"
      }

      # Debounce: wait for 10 quiet seconds, at most 15 minutes. A /reload writes its
      # file in one go, and a logout writes every account's files within seconds.
      settle() {
        local t0 now
        t0=$(date +%s)
        while now=$(date +%s); [ $((now - $(newest))) -lt 10 ] && [ $((now - t0)) -lt 900 ]; do
          sleep 2
        done
      }

      unchanged() {
        [ "$force" = 0 ] && [ -f "$hashes" ] && [ "$1" = "$(cat "$hashes")" ]
      }

      # The session started by this run, until it is removed. Stopped on any
      # exit, so it never outlives the script (it lives in the daemon's cgroup).
      id=""
      finish_session() {
        [ -n "$id" ] || return 0
        claude stop "$id" >/dev/null 2>&1 || true
        claude rm "$id" >/dev/null 2>&1 || true
        echo "session $id stopped and removed"
        id=""
      }
      trap finish_session EXIT
      trap 'exit 143' TERM INT HUP

      # Reset the worktree, but only when no live session has its cwd there.
      prepare_worktree() {
        local json busy idle i
        json=$(claude agents --json) || { echo "claude agents failed; not touching $wt"; return 1; }
        busy=$(jq -r --arg w "$wt" '[.[] | select((.cwd // "") as $c | $c == $w or ($c | startswith($w + "/")))
          | select(.kind != "background" or .status == "busy") | .id // .sessionId] | join(" ")' <<<"$json")
        if [ -n "$busy" ]; then
          echo "a session is still running in $wt ($busy); leaving it, the next trigger tries again"
          exit 0
        fi
        idle=$(jq -r --arg w "$wt" '.[] | select((.cwd // "") as $c | $c == $w or ($c | startswith($w + "/")))
          | select(.kind == "background") | .id' <<<"$json")
        for i in $idle; do
          echo "stopping leftover idle session $i in $wt"
          claude stop "$i" >/dev/null 2>&1 || true
          claude rm "$i" >/dev/null 2>&1 || true
        done
        git -C "${repo}" fetch --quiet origin main
        if git -C "${repo}" worktree list --porcelain | grep -qxF "worktree $wt"; then
          git -C "$wt" checkout --quiet --force --detach origin/main
          git -C "$wt" clean -ffdxq
        else
          git -C "${repo}" worktree prune
          if [ -e "$wt" ]; then
            echo "$wt exists but is not a worktree of ${repo}; remove it by hand"
            return 1
          fi
          git -C "${repo}" worktree add --quiet --detach "$wt" origin/main
        fi
        echo "worktree $wt at $(git -C "$wt" rev-parse --short HEAD)"
        if ! grep -qE '^#{2,4} The desk refresh' "$wt/README.md"; then
          echo "wow-plan main has no 'The desk refresh' section in README.md; not starting a session"
          return 1
        fi
      }

      run_session() {
        local out json rec st sid seen t0 now deadline transcript result
        [ -s "$state/recipient" ] || echo "warning: $state/recipient is missing; the refresh has no one to email"
        # --bg picks the session id itself (it ignores --session-id) and
        # prints it: "backgrounded · <id> · <name>".
        out=$(cd "$wt" && claude "''${claude_args[@]}" -n "desk-refresh-$(date +%H%M)" "${prompt}" </dev/null 2>&1) ||
          { printf '%s\n' "$out"; return 1; }
        id=$(sed -n 's/^backgrounded · \([0-9a-f]*\).*/\1/p' <<<"$out" | head -1)
        if [ -z "$id" ]; then
          printf 'could not start the session:\n%s\n' "$out"
          return 1
        fi
        echo "session $id started"
        t0=$(date +%s) deadline=$(($(date +%s) + 1800)) sid="" seen=0 json=""
        # Finished once `status` is idle after it was seen busy, or once the
        # session has exited (no status). Before it is first seen busy, only
        # after two minutes, so a session still starting up is not taken for
        # a finished one. A failed or garbled poll is retried.
        while :; do
          now=$(date +%s)
          if [ "$now" -ge "$deadline" ]; then
            echo "deadline reached; stopping session $id"
            finish_session
            return 1
          fi
          if json=$(claude agents --json --all 2>/dev/null) &&
             rec=$(jq -ce --arg i "$id" 'map(select(.id == $i)) | .[0]' <<<"$json" 2>/dev/null); then
            sid=$(jq -r '.sessionId // empty' <<<"$rec")
            st=$(jq -r '.status // ""' <<<"$rec")
            if [ "$st" = busy ]; then
              seen=1
            elif { [ "$st" = idle ] || [ -z "$st" ]; } && { [ "$seen" = 1 ] || [ $((now - t0)) -ge 120 ]; }; then
              break
            fi
          elif jq -e 'type == "array"' <<<"$json" >/dev/null 2>&1 && [ $((now - t0)) -ge 120 ]; then
            echo "session $id is no longer listed"
            break
          fi
          sleep 15
        done
        transcript=""
        [ -n "$sid" ] && transcript=$(find "$HOME/.claude/projects" -name "$sid.jsonl" -print -quit)
        if [ -n "$transcript" ] &&
           result=$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | last // ""' "$transcript"); then
          echo "session $id ended; its last message:"
          printf '%s\n' "$result"
          finish_session
        else
          echo "session $id ended but its transcript could not be read"
          finish_session
          return 1
        fi
      }

      if unchanged "$(current_hashes)"; then
        echo "no source changed since the last refresh"
        exit 0
      fi
      for pass in 1 2 3; do
        settle
        mark=$(current_hashes)
        if [ "$pass" = 1 ] && unchanged "$mark"; then
          echo "no source changed since the last refresh"
          exit 0
        fi
        echo "pass $pass: newest source $(date -d "@$(newest)" '+%F %T')"
        prepare_worktree
        run_session
        printf '%s\n' "$mark" >"$hashes.tmp"
        mv "$hashes.tmp" "$hashes"
        force=0
        if unchanged "$(current_hashes)"; then
          exit 0
        fi
        echo "a source changed during the run; going again"
      done
    '';
  };

  discover = pkgs.writeShellApplication {
    name = "wow-desk-refresh-accounts";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      for dir in "${accounts}"/*/; do
        acct=$(basename "$dir")
        # WTF/Account/SavedVariables is the account-wide one, not an account.
        [ "$acct" != SavedVariables ] || continue
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
      Wants = [ "claude-daemon.service" "wow-desk-refresh-accounts.service" ];
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
      OnCalendar = "*-*-* *:50:00";
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
