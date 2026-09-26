# The rebuild menu: Mod+Shift+R in niri (hosts/desk/home/niri.kdl) opens
# `rebuild-menu`, a fuzzel list of every worktree of ~/natb1/nix-config, and
# runs `rebuild` (modules/home/rebuild.nix) against the one picked — pull, then
# switch — in a terminal for the sudo prompt, held open to read the result.
#
# git lists the main checkout first, so it is the entry already selected: Enter
# alone rebuilds main, as the binding did before there was a menu. Worktrees
# whose directory is gone (prunable) are left out.

{ pkgs, ... }:

let
  rebuildMenu = pkgs.writeShellApplication {
    name = "rebuild-menu";
    runtimeInputs = [
      pkgs.fuzzel
      pkgs.git
      pkgs.gawk
      pkgs.xdg-terminal-exec
    ];
    text = ''
      repo="$HOME/natb1/nix-config"

      # One "path<TAB>branch" line per live worktree, main checkout first.
      worktrees=$(git -C "$repo" worktree list --porcelain | awk '
        /^worktree / { path = substr($0, 10); ref = ""; gone = 0 }
        /^HEAD /     { ref = "detached " substr($2, 1, 7) }
        /^branch /   { ref = substr($2, 12) }
        /^prunable/  { gone = 1 }
        /^$/         { if (!gone) print path "\t" ref }
      ')

      # Shown as "branch  ·  last commit's subject": the Claude worktrees'
      # branch names alone don't say what is in them.
      choice=$(while IFS=$'\t' read -r path ref; do
          printf '%s  ·  %s\n' "$ref" "$(git -C "$path" log -1 --format=%s)"
        done <<<"$worktrees" |
        fuzzel --dmenu --index --prompt "rebuild › " --lines 15 --width 100) || exit 0

      dir=$(printf '%s\n' "$worktrees" | awk -F '\t' -v n="$choice" 'NR == n + 1 { print $1 }')
      [ -n "$dir" ] || exit 0

      exec xdg-terminal-exec env REBUILD_REPO="$dir" zsh -c "rebuild; print; read -sk '?Done. Press any key to close.'"
    '';
  };
in
{
  environment.systemPackages = [ rebuildMenu ];
}
