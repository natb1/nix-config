# Steam on the host, for native and Proton titles. Its library is the
# default, ~/.local/share/Steam on the root: enough room for now (decided
# 2026-09-26, replacing the /srv/games subvolume the plan had). Windows' own
# library stays on C:.
#
# It runs under xwayland-satellite (desktop.nix), and its tray icon shows in
# the Quickshell panel (Mod+Shift+N) while it runs.
#
# Unfree: steam and steam-unwrapped are allowed by name in flake.nix's
# unfreePredicate. A second allowUnfreePredicate here would silently replace
# that one (or be replaced by it), not add to it.

{ ... }:

{
  # Also turns on 32-bit graphics drivers and Steam's controller udev rules.
  programs.steam.enable = true;
}
