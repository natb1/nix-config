# Steam on the host, for native and Proton titles. docs/desktop-migration.md,
# "Where the Steam library lives", is the design: Windows' own library stays
# on C:, and this one goes on /srv/games (disko.nix), not the 200 GB root.
#
# It runs under xwayland-satellite (desktop.nix), and its tray icon shows in
# the Quickshell panel (Mod+Shift+N) while it runs.
#
# Unfree: steam and steam-unwrapped are allowed by name in flake.nix's
# unfreePredicate, which is the only place nixpkgs.config can be set.

{ ... }:

{
  # Also turns on 32-bit graphics drivers and Steam's controller udev rules.
  programs.steam.enable = true;

  # The subvolume is created root-owned, so Steam could not add it as a
  # library folder. Add it once in Settings → Storage and leave the default
  # (~/.local/share/Steam) empty.
  systemd.tmpfiles.settings."10-games"."/srv/games".d = {
    user = "n8";
    group = "users";
    mode = "0755";
  };
}
