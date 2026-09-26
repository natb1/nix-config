# `rebuild`: pull ~/natb1/nix-config and switch this machine to it, one command on
# every host. The pull is fast-forward only, so a branch that has diverged from
# its remote stops it before anything is built; the new commits are listed
# before the switch. Extra arguments go to the rebuild (e.g. `rebuild --show-trace`).
#
# REBUILD_REPO switches from another checkout instead — a worktree of the repo,
# as desk's Mod+Shift+R picker does (hosts/desk/rebuild-menu.nix). A branch with
# no upstream, or a detached HEAD, has nothing to pull and is built as it is.
#
# The flake target: on NixOS, nixos-rebuild picks the configuration named after
# the hostname (desk, wsl). The Mac's hostname is not `mba`, so darwin names it.
# The rebuild tools themselves come from the system PATH, not from here.

{ pkgs, ... }:

let
  target =
    if pkgs.stdenv.hostPlatform.isDarwin then
      ''sudo darwin-rebuild switch --flake "$repo#mba" "$@"''
    else
      ''sudo nixos-rebuild switch --flake "$repo" "$@"'';
in
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "rebuild";
      runtimeInputs = [ pkgs.git ];
      text = ''
        repo="''${REBUILD_REPO:-$HOME/natb1/nix-config}"
        echo "$repo ($(git -C "$repo" rev-parse --abbrev-ref HEAD))"
        if git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
          before=$(git -C "$repo" rev-parse HEAD)
          git -C "$repo" pull --ff-only
          git -C "$repo" --no-pager log --oneline "$before..HEAD"
        else
          echo "no upstream to pull; building $(git -C "$repo" rev-parse --short HEAD) as checked out"
        fi
        ${target}
      '';
    })
  ];
}
