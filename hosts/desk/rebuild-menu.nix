# The rebuild menu: Mod+Shift+R in niri (hosts/desk/home/niri.kdl) opens
# `rebuild-menu`, a list of every worktree of ~/natb1/nix-config, and runs
# `rebuild` (modules/home/rebuild.nix) against the one picked — pull, then
# switch — in a terminal for the sudo prompt, held open to read the result.
#
# git lists the main checkout first, so it is the entry already selected: Enter
# alone rebuilds main, as the binding did before there was a menu. Worktrees
# whose directory is gone (prunable) are left out.
#
# The list is the desk shell's picker (home/quickshell/Picker.qml), since
# its entries can be three lines, which fuzzel's can't: the open pull
# request's number and title (from gh, which is already logged in), the last
# commit's subject, and the worktree's directory. Without a pull request —
# main, or never seen online — the first line is the branch.
#
# It opens at once, with the pull requests as of the last run, and fills in
# while it is open: the tidy-up below and `gh pr list` run behind it, then
# the list is redrawn with what they found. If the shell isn't running, it is
# fuzzel instead, one line per entry.
#
# The tidy-up keeps the list to what is still live. After a fetch, a worktree
# is removed, with its branch, when its HEAD is in origin/main, it has no
# changes (untracked files included) and no session holds it. Claude sessions
# lock their worktree ("claude agent … (pid N …)"), so a lock is an open
# session unless the pid it names has exited. Branches with no worktree that
# are in origin/main are deleted too. The main checkout and `main` are never
# touched. Nothing unmerged is removed, so nothing is lost that isn't on
# GitHub.

{ pkgs, ... }:

let
  rebuildMenu = pkgs.writeShellApplication {
    name = "rebuild-menu";
    runtimeInputs = [
      pkgs.quickshell
      pkgs.fuzzel
      pkgs.git
      pkgs.gawk
      pkgs.coreutils
      pkgs.gnused
      pkgs.gnugrep
      pkgs.gh
      pkgs.util-linux
      pkgs.xdg-terminal-exec
    ];
    text = ''
      repo="$HOME/natb1/nix-config"
      g() { git -C "$repo" "$@"; }
      # Quickshell exits 0 on "Target not found" (an older shell), so any
      # output is a failure too.
      picker() {
        local out
        out=$(qs -c desk ipc call picker "$@" 2>&1) && [ -z "$out" ]
      }

      # Open PRs as "branch<TAB>number<TAB>title", kept between runs.
      prs="''${XDG_CACHE_HOME:-$HOME/.cache}/rebuild-menu/prs"
      mkdir -p "''${prs%/*}"
      touch "$prs"

      # This run's list and the FIFO the picker answers on.
      run=$(mktemp -d "''${XDG_RUNTIME_DIR:-/tmp}/rebuild-menu.XXXXXX")
      mkfifo "$run/choice"

      # One row per live worktree, main checkout first: the worktree's path
      # (what the picker answers with), then the three lines shown.
      rows() {
        local -A pr_number=() pr_title=()
        local branch number title path ref first
        while IFS=$'\t' read -r branch number title; do
          pr_number[$branch]=$number
          pr_title[$branch]=$title
        done <"$prs"

        while IFS=$'\t' read -r path ref; do
          if [ -n "''${pr_number[$ref]:-}" ]; then
            first="#''${pr_number[$ref]} ''${pr_title[$ref]}"
          else
            first=$ref
          fi
          printf '%s\t%s\t%s\t%s\n' "$path" "$first" "$(git -C "$path" log -1 --format=%s)" "''${path##*/}"
        done < <(g worktree list --porcelain | awk '
          /^worktree / { path = substr($0, 10); ref = ""; gone = 0 }
          /^HEAD /     { ref = "detached " substr($2, 1, 7) }
          /^branch /   { ref = substr($2, 12) }
          /^prunable/  { gone = 1 }
          /^$/         { if (!gone) print path "\t" ref }
        ')
      }

      # The fetch, `gh pr list` and the tidy-up; prints how many worktrees
      # and branches it removed. One at a time: a menu opened over another
      # closes it, but its tidy-up carries on.
      tidy() {
        exec 9>"''${prs%/*}/lock"
        flock 9

        # Offline or slow, the tidy-up runs against the origin/main last
        # fetched: anything in that is merged all the same. An offline gh
        # leaves the last run's PRs.
        (cd "$repo" && new=$(mktemp "$prs.XXXXXX") &&
          if timeout 15 gh pr list --state open --limit 100 \
            --json number,title,headRefName \
            --jq '.[] | "\(.headRefName)\t\(.number)\t\(.title)"' >"$new" 2>/dev/null; then
            mv "$new" "$prs"
          else
            rm -f "$new"
          fi) &
        timeout 15 git -C "$repo" fetch -q origin main || true

        merged() { g merge-base --is-ancestor "$1" origin/main 2>/dev/null; }
        local tidied=0 path branch locked reason pid checked_out

        # "path|branch|locked|lock reason" per worktree but the main checkout
        # (listed first). Not tabs: read would merge the empty branch field
        # of a detached HEAD into the next one.
        while IFS='|' read -r path branch locked reason; do
          [ -d "$path" ] || continue
          if [ "$locked" = 1 ]; then
            pid=$(sed -n 's/.*(pid \([0-9]*\).*/\1/p' <<<"$reason")
            [ -n "$pid" ] && [ ! -d "/proc/$pid" ] || continue
          fi
          [ -z "$(git -C "$path" status --porcelain)" ] || continue
          merged "$(git -C "$path" rev-parse HEAD)" || continue
          # --force twice is what removes a (stale) locked worktree; the
          # checks above are what make that safe.
          g worktree remove --force --force "$path" || continue
          [ -z "$branch" ] || g branch -D -q "$branch" || true
          tidied=$((tidied + 1))
        done < <(g worktree list --porcelain | awk '
          /^worktree / { n++; path = substr($0, 10); branch = ""; locked = 0; reason = "" }
          /^branch /   { branch = substr($2, 12) }
          /^locked/    { locked = 1; reason = substr($0, 8) }
          /^$/         { if (n > 1) print path "|" branch "|" locked "|" reason }
        ')
        g worktree prune

        # Branches no worktree has checked out.
        checked_out=$(g worktree list --porcelain | awk '/^branch / { print substr($2, 12) }')
        while read -r branch; do
          [ "$branch" != main ] || continue
          grep -qxF "$branch" <<<"$checked_out" && continue
          merged "refs/heads/$branch" || continue
          if g branch -D -q "$branch"; then tidied=$((tidied + 1)); fi
        done < <(g for-each-ref --format='%(refname:short)' refs/heads)

        wait
        echo "$tidied"
      }

      rows >"$run/rows"

      if picker open "$run/rows" "$run/choice" "rebuild ›"; then
        # Behind the open list. The run directory may be gone by the end, if
        # a worktree was picked first.
        (
          picker reload "Checking for merged worktrees and pull requests…" || true
          tidied=$(tidy)
          [ -d "$run" ] || exit 0
          rows >"$run/rows.new" && mv "$run/rows.new" "$run/rows"
          mesg=""
          [ "$tidied" = 0 ] || mesg="Removed $tidied merged worktree(s)/branch(es)"
          picker reload "$mesg" || true
        ) &
        dir=""
        read -r dir <"$run/choice" || true
      else
        # No desk shell: fuzzel, after the tidy-up.
        tidied=$(tidy)
        rows >"$run/rows"
        mesg=()
        [ "$tidied" = 0 ] || mesg=(--mesg "Removed $tidied merged worktree(s)/branch(es)")
        n=$(cut -f 2- "$run/rows" | sed 's/\t/  ·  /g' |
          fuzzel --dmenu --index --prompt "rebuild › " --lines 15 --width 120 "''${mesg[@]}") || n=-1
        dir=$(awk -F '\t' -v n="$n" 'NR == n + 1 { print $1 }' "$run/rows")
      fi
      rm -rf "$run"
      [ -n "$dir" ] && [ -d "$dir" ] || exit 0

      exec xdg-terminal-exec env REBUILD_REPO="$dir" zsh -c "rebuild; print; read -sk '?Done. Press any key to close.'"
    '';
  };
in
{
  environment.systemPackages = [ rebuildMenu ];
}
