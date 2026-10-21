# Steam on the host, for native and Proton titles. Its library is the
# default, ~/.local/share/Steam on the root: enough room for now (decided
# 2026-09-26, replacing the /srv/games subvolume the plan had). Windows' own
# library stays on C:.
#
# It runs under xwayland-satellite (desktop.nix), and its tray icon shows in
# the Quickshell panel (Mod+Shift+N) while it runs.
#
# Battle.net's prefix is on /srv/games instead (2026-10-16): WoW Forever wants
# 128 GB, more than the root has free.
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
  # the WoW folder, /srv/games/battlenet/drive_c/Program Files (x86)/World of
  # Warcraft, which it does not find on its own (~/.config/tsm-app, unmanaged).
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
  # outside Steam: umu-launcher runs GE-Proton the way Steam would, in a prefix
  # of its own at /srv/games/battlenet. The first run downloads Blizzard's
  # installer and runs it; every run after starts the launcher, and the games
  # install from there into the same prefix. GE-Proton comes from nixpkgs, so
  # umu downloads no Proton of its own and the flake bump updates it.
  #
  # It runs as a user service, battlenet.service, not under whatever started
  # it: Battle.net's own cgroup, and its output in the journal, which keeps
  # past sessions across boots — `journalctl --user -u battlenet`, `-b -1` for
  # the boot before. Proton silences Wine and the D3D layers unless told
  # otherwise; set here to errors and warnings, not PROTON_LOG's full trace
  # (gigabytes per evening). WoW rewrites its Logs on every start, so each time
  # the game exits its Logs and Errors are copied to
  # ~/.local/state/battlenet/wow/<time>-<flavor>, the last 30 kept.
  #
  # `battlenet --account <label>` signs into one account of two (2026-10-20),
  # restarting a Battle.net already running to switch. Battle.net keeps one
  # "Keep me logged in" token, the registry's Battle.net\UnifiedAuth key, and
  # signs into whichever account it belongs to, whatever SavedAccountNames
  # says (found 2026-10-21). So each account keeps its own copy in
  # ~/.local/state/battlenet/auth/<label>.reg: before Battle.net starts, the
  # token in the registry is put away under the label last launched (`current`
  # beside it) and the chosen account's copy put back, or none, which brings up
  # the sign-in page. The swap happens at start, not exit, as Wine writes the
  # registry only once the prefix shuts down. Plain `battlenet` leaves the
  # token alone, so an account changed in Battle.net itself is put away under
  # the wrong label. The chosen address also goes first in SavedAccountNames,
  # which fills in the sign-in page. The addresses are not in this repo:
  # ~/.config/battlenet/accounts maps labels to them, one `<label> <email>`
  # per line.
  # Label (the --account argument and the file names) and the name Mod+D shows.
  accounts = {
    nate = "Nate";
    lindsey = "Lindsey";
  };
  battlenet = pkgs.writeShellApplication {
    name = "battlenet";
    runtimeInputs = [ pkgs.umu-launcher pkgs.curl pkgs.coreutils pkgs.util-linux pkgs.procps pkgs.systemd pkgs.jq pkgs.gawk ];
    text = ''
      account=""
      if [ "''${1:-}" = "--account" ]; then
        account="''${2:?battlenet: --account needs a label}"
        shift 2
      fi

      if [ -z "''${BATTLENET_UNIT:-}" ]; then
        if [ -n "$account" ]; then
          # Battle.net rewrites its config on exit, so it is stopped before
          # the config changes, not after.
          systemctl --user stop battlenet.service 2>/dev/null || true
          exec systemd-run --user --quiet --collect --unit=battlenet \
            --description=Battle.net --setenv=BATTLENET_UNIT=1 \
            --setenv=BATTLENET_ACCOUNT="$account" "$0" "$@"
        fi
        if systemctl --user is-active -q battlenet.service; then
          echo "battlenet: already running (journalctl --user -fu battlenet)" >&2
          exit 0
        fi
        exec systemd-run --user --quiet --collect --unit=battlenet \
          --description=Battle.net --setenv=BATTLENET_UNIT=1 "$0" "$@"
      fi

      # Unmounted, /srv/games is a directory on the root: a fresh install
      # there would fill the root, not find the games.
      if ! mountpoint -q /srv/games; then
        echo "battlenet: /srv/games is not mounted" >&2
        exit 1
      fi
      export WINEPREFIX=/srv/games/battlenet
      export PROTONPATH="${pkgs.proton-ge-bin.steamcompattool}"
      export GAMEID=umu-battlenet
      export WINEDEBUG=+timestamp,fixme-all
      export DXVK_LOG_LEVEL=warn DXVK_LOG_PATH=none
      export VKD3D_DEBUG=err VKD3D_SHADER_DEBUG=none
      launcher="$WINEPREFIX/drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe"
      wow="$WINEPREFIX/drive_c/Program Files (x86)/World of Warcraft"
      saved="''${XDG_STATE_HOME:-$HOME/.local/state}/battlenet/wow"
      config="$WINEPREFIX/drive_c/users/steamuser/AppData/Roaming/Battle.net/Battle.net.config"

      if [ -n "''${BATTLENET_ACCOUNT:-}" ]; then
        accounts="''${XDG_CONFIG_HOME:-$HOME/.config}/battlenet/accounts"
        email=$(awk -v l="$BATTLENET_ACCOUNT" '$1 == l { print $2; exit }' "$accounts" 2>/dev/null || true)
        if [ -z "$email" ]; then
          echo "battlenet: no account '$BATTLENET_ACCOUNT' in $accounts" >&2
          exit 1
        fi
        jq --arg a "$email" '
          .Client.SavedAccountNames = ([$a] + ((.Client.SavedAccountNames // "")
            | split(",") | map(select(. != "" and ascii_downcase != ($a | ascii_downcase)))) | join(","))
          | .Client.AutoLogin = "true"
        ' "$config" > "$config.new"
        mv "$config.new" "$config"

        auth="''${XDG_STATE_HOME:-$HOME/.local/state}/battlenet/auth"
        mkdir -p "$auth"
        chmod 700 "$auth"
        reg="$WINEPREFIX/user.reg"
        # The UnifiedAuth section: its header line to the blank line after.
        # shellcheck disable=SC2016 # awk's $0, not the shell's
        unified='
          /^\[/ { in_auth = index($0, "Battle.net") && index($0, "UnifiedAuth]") }
          in_auth && $0 == "" { in_auth = 0; if (drop) next }
          (in_auth && keep) || (!in_auth && drop)
        '
        current=$(cat "$auth/current" 2>/dev/null || true)
        if [ "$current" != "$BATTLENET_ACCOUNT" ]; then
          cp -a "$reg" "$auth/user.reg.bak"
          if [ -n "$current" ]; then
            awk -v keep=1 "$unified" "$reg" > "$auth/$current.reg"
          fi
          awk -v drop=1 "$unified" "$reg" > "$reg.new"
          if [ -s "$auth/$BATTLENET_ACCOUNT.reg" ]; then
            { cat "$auth/$BATTLENET_ACCOUNT.reg"; echo; } >> "$reg.new"
          fi
          mv "$reg.new" "$reg"
          echo "$BATTLENET_ACCOUNT" > "$auth/current"
        fi
        echo "battlenet: signing into account $BATTLENET_ACCOUNT"
      fi

      save_wow_logs() {
        stamp=$(date +%F_%H%M%S)
        for flavor in "$wow"/_*_; do
          [ -d "$flavor/Logs" ] || continue
          dest="$saved/$stamp$(basename "$flavor")"
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
        # Battle.net does. Unless one is already open from the app menu.
        if ! pgrep -u "$(id -u)" -f '/bin/\.?tsm-app' >/dev/null; then
          ${pkgs.lib.getExe tsm-app} &
        fi
        # By process name: Wow.exe, WowClassic.exe, …
        (
          running=0
          while sleep 5; do
            if pgrep -u "$(id -u)" '^Wow[A-Za-z]*\.exe$' >/dev/null; then
              running=1
            elif [ "$running" = 1 ]; then
              save_wow_logs || true
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
  # plain `battlenet` stays on the command line.
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
