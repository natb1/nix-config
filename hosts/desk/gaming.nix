# Steam on the host, for native and Proton titles. Its library is the
# default, ~/.local/share/Steam on the root: enough room for now (decided
# 2026-09-26, replacing the /srv/games subvolume the plan had). Windows' own
# library stays on C:.
#
# It runs under xwayland-satellite (desktop.nix), and its tray icon shows in
# the Quickshell panel (Mod+Shift+N) while it runs.
#
# Battle.net's prefixes and WoW are on /srv/games instead (2026-10-16): WoW
# Forever wants 128 GB, more than the root has free.
#
# Unfree: steam and steam-unwrapped are allowed by name in flake.nix's
# unfreePredicate. A second allowUnfreePredicate here would silently replace
# that one (or be replaced by it), not add to it.

{ lib, pkgs, inputs, ... }:

let
  # TSM's price data: the TradeSkillMaster addon reads it from
  # TradeSkillMaster_AppHelper/AppData.lua, which only the TSM Desktop App
  # writes. This is the unofficial Linux port (flake.nix), a Qt window and a
  # tray icon. It signs in to TSM with the account's password, kept in
  # gnome-keyring, polls hourly, and installs and updates the TSM addons
  # itself. Set by hand once, in its own window: the sign-in, the realms, and
  # the WoW folder, /srv/games/wow, which it does not find on its own
  # (~/.config/tsm-app, unmanaged).
  #
  # Its flake hands hatch-vcs the version as a top-level attribute, which
  # nixpkgs' structuredAttrs no longer exports to the build (and env cannot
  # carry a name the derivation already has), so the build exports it.
  tsm-app = inputs.tsm-app-linux.packages.${pkgs.stdenv.hostPlatform.system}.tsm-app.overrideAttrs (old: {
    preBuild = (old.preBuild or "") + ''
      export SETUPTOOLS_SCM_PRETEND_VERSION=${old.version}
    '';
  });

  # Battle.net (WoW Classic and the rest of Blizzard's games) under Proton,
  # outside Steam: umu-launcher runs GE-Proton the way Steam would. The first
  # run downloads Blizzard's installer and runs it; every run after starts the
  # launcher, and the games install from there. GE-Proton comes from nixpkgs,
  # so umu downloads no Proton of its own and the flake bump updates it.
  #
  # One Battle.net per account, so both can play at once — multiboxing
  # (2026-10-27). `battlenet --account <label>` runs that account's in a
  # prefix of its own, /srv/games/battlenet-<label>, as the user service
  # battlenet-<label>.service. Battle.net remembers one sign-in per prefix,
  # and one prefix runs one Battle.net, so a prefix each is what lets two run
  # side by side; it replaces swapping one prefix's Battle.net state between
  # accounts (2026-10-20 to 2026-10-27), which had to stop Battle.net, and the
  # games with it, to switch. Battle.net's local ports are random, so two do
  # not collide.
  #
  # The games are shared, not installed twice: WoW is /srv/games/wow, and each
  # prefix's Program Files (x86)/World of Warcraft links to it, so Battle.net
  # sees it where it installed it. The link is made before Proton creates a
  # new prefix, and a new prefix's Battle.net does not know the game is there
  # until told: "Locate the game" in it, with no WoW running. Both Battle.nets
  # update the one folder, so after a patch let one finish before starting
  # the other. WTF/Config.wtf (window size and position, the last account) is
  # shared too, as on Windows.
  #
  # A new prefix starts with Battle.net's config naming only the account's
  # address, which brings up the sign-in page with it filled in. The addresses
  # are not in this repo: ~/.config/battlenet/accounts maps labels to them,
  # one `<label> <email>` per line.
  #
  # Each runs as its own user service, not under whatever started it:
  # Battle.net's own cgroup, and its output in the journal, which keeps past
  # sessions across boots — `journalctl --user -u battlenet-<label>`, `-b -1`
  # for the boot before. Proton silences Wine and the D3D layers unless told
  # otherwise; set here to errors and warnings, not PROTON_LOG's full trace
  # (gigabytes per evening). WoW rewrites its Logs on every start, so each time
  # an account's game exits its Logs and Errors are copied to
  # ~/.local/state/battlenet/wow/<time>-<label><flavor>, the last 30 kept.
  #
  # Label (the --account argument and the prefix and unit names) and the name
  # Mod+D shows.
  accounts = {
    nate = "Nate";
    lindsey = "Lindsey";
  };
  battlenet = pkgs.writeShellApplication {
    name = "battlenet";
    runtimeInputs = [ pkgs.umu-launcher pkgs.curl pkgs.coreutils pkgs.util-linux pkgs.procps pkgs.systemd pkgs.jq pkgs.gawk ];
    text = ''
      if [ "''${1:-}" != "--account" ] || [ -z "''${2:-}" ]; then
        echo "usage: battlenet --account <label> [launcher arguments]" >&2
        exit 2
      fi
      account=$2
      shift 2
      unit="battlenet-$account"

      if [ -z "''${BATTLENET_UNIT:-}" ]; then
        if systemctl --user is-active -q "$unit.service"; then
          echo "battlenet: $account already running (journalctl --user -fu $unit)" >&2
          exit 0
        fi
        exec systemd-run --user --quiet --collect --unit="$unit" \
          --description="Battle.net ($account)" --setenv=BATTLENET_UNIT=1 \
          "$0" --account "$account" "$@"
      fi

      # Unmounted, /srv/games is a directory on the root: a fresh install
      # there would fill the root, not find the games.
      if ! mountpoint -q /srv/games; then
        echo "battlenet: /srv/games is not mounted" >&2
        exit 1
      fi
      export WINEPREFIX="/srv/games/battlenet-$account"
      export PROTONPATH="${pkgs.proton-ge-bin.steamcompattool}"
      export GAMEID=umu-battlenet
      export WINEDEBUG=+timestamp,fixme-all
      export DXVK_LOG_LEVEL=warn DXVK_LOG_PATH=none
      export VKD3D_DEBUG=err VKD3D_SHADER_DEBUG=none
      launcher="$WINEPREFIX/drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe"
      wow_shared=/srv/games/wow
      wow="$WINEPREFIX/drive_c/Program Files (x86)/World of Warcraft"
      config="$WINEPREFIX/drive_c/users/steamuser/AppData/Roaming/Battle.net/Battle.net.config"
      saved="''${XDG_STATE_HOME:-$HOME/.local/state}/battlenet/wow"

      mkdir -p "$wow_shared"
      if [ ! -L "$wow" ]; then
        if [ -e "$wow" ]; then
          echo "battlenet: $wow is not a link to $wow_shared" >&2
          exit 1
        fi
        mkdir -p "$(dirname "$wow")"
        ln -s "$wow_shared" "$wow"
      fi

      if [ ! -e "$config" ]; then
        accounts="''${XDG_CONFIG_HOME:-$HOME/.config}/battlenet/accounts"
        email=$(awk -v l="$account" '$1 == l { print $2; exit }' "$accounts" 2>/dev/null || true)
        if [ -z "$email" ]; then
          echo "battlenet: no account '$account' in $accounts" >&2
          exit 1
        fi
        mkdir -p "$(dirname "$config")"
        jq -n --arg a "$email" '{Client: {SavedAccountNames: $a, RememberAccountName: "true", AutoLogin: "true"}}' \
          > "$config"
      fi

      save_wow_logs() {
        stamp=$(date +%F_%H%M%S)
        for flavor in "$wow"/_*_; do
          [ -d "$flavor/Logs" ] || continue
          dest="$saved/$stamp-$account$(basename "$flavor")"
          mkdir -p "$dest"
          cp -a "$flavor/Logs" "$dest/"
          if [ -d "$flavor/Errors" ]; then cp -a "$flavor/Errors" "$dest/"; fi
          echo "battlenet: WoW exited, logs saved to $dest"
        done
        find "$saved" -mindepth 1 -maxdepth 1 -type d | sort | head -n -30 \
          | xargs -r -d '\n' rm -rf
      }

      if [ -e "$launcher" ]; then
        # The TSM app beside the launcher, in the same unit, so it stops when
        # this Battle.net does. Unless one is already open, from the app menu
        # or the other account's.
        if ! pgrep -u "$(id -u)" -f '/bin/\.?tsm-app' >/dev/null; then
          ${pkgs.lib.getExe tsm-app} &
        fi
        # By process name, any case, Wow.exe, WoWClassic.exe, …, in this
        # unit's cgroup only: the other account's game is not this one's.
        cgroup=$(sed -n 's/^0:://p' /proc/self/cgroup)
        (
          running=0
          while sleep 5; do
            if pgrep -i --cgroup "$cgroup" '^wow[a-z]*\.exe$' >/dev/null; then
              running=1
            elif [ "$running" = 1 ]; then
              save_wow_logs || true
              # Auctionator's scans, saved on the way out (tsm-history.nix).
              systemctl --user start --no-block auctionator-history.service || true
              running=0
            fi
          done
        ) &
        watcher=$!
        trap 'kill "$watcher" 2>/dev/null || true' EXIT
        umu-run "$launcher" "$@"
        exit
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

  # The subvolume under /srv/games (disko.nix), created on first boot of a
  # generation that has it, as nofail cannot stand in for a missing one:
  # a /srv/games declared before it existed is what dropped desk into
  # emergency mode on 2026-09-26. Early boot, before the mount, so no default
  # dependencies (they would order it after local-fs.target, which the mount
  # is before).
  systemd.services.srv-games-subvolume = {
    description = "Create the games subvolume on the media volume";
    requiredBy = [ "srv-games.mount" ];
    before = [ "srv-games.mount" ];
    requires = [ "dev-disk-by\\x2dpartlabel-disk\\x2dbulk\\x2dmedia.device" ];
    after = [ "dev-disk-by\\x2dpartlabel-disk\\x2dbulk\\x2dmedia.device" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # The top-level mount below stays inside this unit.
      PrivateMounts = true;
    };
    path = [ pkgs.btrfs-progs pkgs.util-linux ];
    script = ''
      top=/run/srv-games-subvolume
      mkdir -p "$top"
      mount -o subvolid=5 /dev/disk/by-partlabel/disk-bulk-media "$top"
      if [ ! -e "$top/games" ]; then
        btrfs subvolume create "$top/games"
        chown n8:users "$top/games"
      fi
    '';
  };

  # Mod+D lists the accounts (the Quickshell launcher reads desktop entries);
  # the same `battlenet --account <label>` works from a terminal.
  environment.systemPackages = [
    battlenet
    # Its desktop entry, for opening it without Battle.net.
    tsm-app
  ] ++ lib.mapAttrsToList (label: name: pkgs.makeDesktopItem {
    name = "battlenet-${label}";
    desktopName = "Battle.net (${name})";
    comment = "Battle.net, signed into ${name}'s account";
    exec = "battlenet --account ${label}";
    icon = "applications-games";
    categories = [ "Game" ];
  }) accounts;
}
