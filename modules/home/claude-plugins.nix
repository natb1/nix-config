# Claude Code plugins, declared in user settings.
#
# Registers the `canondb` plugin marketplace (github natb1/CanonDB) and enables
# its `principal` plugin for every Claude Code session on this machine —
# including the Remote Control sessions claude-remote-control.nix spawns in
# nix-config worktrees, which a project-scope setting in CanonDB would never
# reach. Claude Code clones a marketplace its settings declare but it has not
# fetched at the next session start, installs the enabled plugins from it, and
# with autoUpdate refreshes the clone in the background after each session
# starts. The plugin's manifest pins no version, so an install's version is the
# commit it came from and updates track CanonDB's main.
#
# Why an activation script and not home.file: Claude Code writes to
# ~/.claude/settings.json itself (marketplace add, /plugin toggles, auto-update
# state), so the file must stay a writable regular file. This merges the keys
# in with jq on every activation, keeps whatever else the file holds, and does
# nothing when the merge is already present.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  settingsFile = "${config.home.homeDirectory}/.claude/settings.json";

  # One jq program: the keys this module owns, merged over the existing file.
  merge = pkgs.writeText "claude-plugins-merge.jq" ''
    .extraKnownMarketplaces.canondb = {
      source: { source: "github", repo: "natb1/CanonDB" },
      autoUpdate: true
    }
    | .enabledPlugins["principal@canondb"] = true
  '';
in
{
  home.activation.configureClaudePlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -eu

    claudeDir="${config.home.homeDirectory}/.claude"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$claudeDir"

    merged=$(${pkgs.coreutils}/bin/mktemp)
    if [ -f "${settingsFile}" ]; then
      ${pkgs.jq}/bin/jq -f ${merge} "${settingsFile}" > "$merged"
    else
      echo '{}' | ${pkgs.jq}/bin/jq -f ${merge} > "$merged"
    fi
    if ${pkgs.diffutils}/bin/cmp -s "$merged" "${settingsFile}"; then
      ${pkgs.coreutils}/bin/rm -f "$merged"
    else
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/chmod 600 "$merged"
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/mv "$merged" "${settingsFile}"
    fi
  '';
}
