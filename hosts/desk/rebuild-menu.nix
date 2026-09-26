# The rebuild menu: Mod+Shift+R in niri (hosts/desk/home/niri.kdl) opens
# `rebuild-menu`, a fuzzel list of every worktree of ~/natb1/nix-config, and
# runs `rebuild` (modules/home/rebuild.nix) against the one picked — pull, then
# switch — in a terminal for the sudo prompt, held open to read the result.
#
# git lists the main checkout first, so it is the entry already selected: Enter
# alone rebuilds main, as the binding did before there was a menu. Worktrees
# whose directory is gone (prunable) are left out. A worktree whose branch has
# an open pull request shows its number and title (gh, which is already
# logged in); offline, it falls back to the branch name.
#
# Opening the menu first tidies up, so the list is only what is still live.
# After a fetch, a worktree is removed, with its branch, when its HEAD is in
# origin/main, it has no changes (untracked files included) and no session
# holds it. Claude sessions lock their worktree ("claude agent … (pid N …)"),
# so a lock is an open session unless the pid it names has exited. Branches
# with no worktree that are in origin/main are deleted too. The main checkout
# and `main` are never touched. Nothing unmerged is removed, so nothing is
# lost that isn't on GitHub.

{ pkgs, ... }:

let
  rebuildMenu = pkgs.writeShellApplication {
    name = "rebuild-menu";
    runtimeInputs = [
      pkgs.fuzzel
      pkgs.git
      pkgs.gawk
      pkgs.coreutils
      pkgs.gnused
      pkgs.gnugrep
      pkgs.gh
      pkgs.xdg-terminal-exec
    ];
    text = ''
      repo="$HOME/natb1/nix-config"
      g() { git -C "$repo" "$@"; }

      # Offline or slow, the tidy-up runs against the origin/main last fetched:
      # anything in that is merged all the same.
      timeout 15 git -C "$repo" fetch -q origin main || true

      # Open PRs as "branch<TAB>number<TAB>title", fetched while the tidy-up runs.
      prs_file=$(mktemp)
      trap 'rm -f "$prs_file"' EXIT
      (cd "$repo" && timeout 15 gh pr list --state open --limit 100 \
        --json number,title,headRefName \
        --jq '.[] | "\(.headRefName)\t\(.number)\t\(.title)"' >"$prs_file" 2>/dev/null) &

      merged() { g merge-base --is-ancestor "$1" origin/main 2>/dev/null; }
      tidied=0

      # "path|branch|locked|lock reason" per worktree but the main checkout
      # (listed first). Not tabs: read would merge the empty branch field of a
      # detached HEAD into the next one.
      while IFS='|' read -r path branch locked reason; do
        [ -d "$path" ] || continue
        if [ "$locked" = 1 ]; then
          pid=$(sed -n 's/.*(pid \([0-9]*\).*/\1/p' <<<"$reason")
          [ -n "$pid" ] && [ ! -d "/proc/$pid" ] || continue
        fi
        [ -z "$(git -C "$path" status --porcelain)" ] || continue
        merged "$(git -C "$path" rev-parse HEAD)" || continue
        # --force twice is what removes a (stale) locked worktree; the checks
        # above are what make that safe.
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

      # One "path<TAB>branch" line per live worktree, main checkout first.
      worktrees=$(g worktree list --porcelain | awk '
        /^worktree / { path = substr($0, 10); ref = ""; gone = 0 }
        /^HEAD /     { ref = "detached " substr($2, 1, 7) }
        /^branch /   { ref = substr($2, 12) }
        /^prunable/  { gone = 1 }
        /^$/         { if (!gone) print path "\t" ref }
      ')

      mesg=()
      [ "$tidied" = 0 ] || mesg=(--mesg "Removed $tidied merged worktree(s)/branch(es)")

      wait
      declare -A pr_number=() pr_title=()
      while IFS=$'\t' read -r branch number title; do
        pr_number[$branch]=$number
        pr_title[$branch]=$title
      done <"$prs_file"

      # Shown as "#N PR title  ·  last commit's subject", or the branch in
      # place of the PR when there is none: the Claude worktrees' branch names
      # alone don't say what is in them. The subject is left off when it only
      # repeats the PR title, as it does for a one-commit PR.
      choice=$(while IFS=$'\t' read -r path ref; do
          subject=$(git -C "$path" log -1 --format=%s)
          if [ -z "''${pr_number[$ref]:-}" ]; then
            printf '%s  ·  %s\n' "$ref" "$subject"
          elif [ "''${pr_title[$ref]}" = "$subject" ]; then
            printf '#%s %s\n' "''${pr_number[$ref]}" "$subject"
          else
            printf '#%s %s  ·  %s\n' "''${pr_number[$ref]}" "''${pr_title[$ref]}" "$subject"
          fi
        done <<<"$worktrees" |
        fuzzel --dmenu --index --prompt "rebuild › " --lines 15 --width 120 "''${mesg[@]}") || exit 0

      dir=$(printf '%s\n' "$worktrees" | awk -F '\t' -v n="$choice" 'NR == n + 1 { print $1 }')
      [ -n "$dir" ] || exit 0

      exec xdg-terminal-exec env REBUILD_REPO="$dir" zsh -c "rebuild; print; read -sk '?Done. Press any key to close.'"
    '';
  };
in
{
  environment.systemPackages = [ rebuildMenu ];
}
