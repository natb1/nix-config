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

{ pkgs, ... }:

let
  # Battle.net (WoW Classic and the rest of Blizzard's games) under Proton,
  # outside Steam: umu-launcher runs GE-Proton the way Steam would, in a prefix
  # of its own at ~/Games/battlenet. The first run downloads Blizzard's
  # installer and runs it; every run after starts the launcher, and the games
  # install from there into the same prefix. GE-Proton comes from nixpkgs, so
  # umu downloads no Proton of its own and the flake bump updates it.
  battlenet = pkgs.writeShellApplication {
    name = "battlenet";
    runtimeInputs = [ pkgs.umu-launcher pkgs.curl pkgs.coreutils ];
    text = ''
      export WINEPREFIX="$HOME/Games/battlenet"
      export PROTONPATH="${pkgs.proton-ge-bin.steamcompattool}"
      export GAMEID=umu-battlenet
      launcher="$WINEPREFIX/drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe"

      if [ -e "$launcher" ]; then
        exec umu-run "$launcher" "$@"
      fi

      # In the prefix, not /tmp: umu's sandbox has a /tmp of its own.
      setup="$WINEPREFIX/setup"
      mkdir -p "$setup"
      trap 'rm -rf "$setup"' EXIT
      curl -fL -o "$setup/Battle.net-Setup.exe" \
        'https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe'
      umu-run "$setup/Battle.net-Setup.exe" --lang=enUS
    '';
  };
in
{
  # Also turns on 32-bit graphics drivers and Steam's controller udev rules.
  programs.steam.enable = true;
  # GE-Proton in Steam's compatibility tool list too, for non-Steam games.
  programs.steam.extraCompatPackages = [ pkgs.proton-ge-bin ];

  environment.systemPackages = [
    battlenet
    # Mod+D lists it (the Quickshell launcher reads desktop entries).
    (pkgs.makeDesktopItem {
      name = "battlenet";
      desktopName = "Battle.net";
      comment = "Blizzard's launcher (WoW Classic) under Proton";
      exec = "battlenet";
      icon = "applications-games";
      categories = [ "Game" ];
    })
  ];
}
