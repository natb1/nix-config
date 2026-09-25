# The power menu: Mod+Shift+Escape in niri (hosts/desk/home/niri.kdl) opens
# `power-menu`, a fuzzel list of suspend / reboot / reboot-into-something /
# power off / log out, plus the Eco Mode switch that applies (eco.nix).
#
# Everything but Windows is plain logind, which lets the active local session
# do it without a password: `systemctl reboot --firmware-setup`,
# `--boot-loader-menu=` and `--boot-loader-entry=` (systemd-boot one-shots;
# the menu is hidden, boot.loader.timeout = 0).
#
# Windows is not a systemd-boot entry — it is on the other NVMe's ESP, known
# only to the firmware as "Windows Boot Manager" (Boot0001 on 2026-09-25). A
# one-shot boot into it means setting the firmware's BootNext, which needs
# root, so it is a root service the menu starts, and polkit lets this user
# start that one unit and nothing else. The entry is found by name at run
# time, not by number, since firmware renumbers. It is also the way into
# Windows without F12, which BIOS "Ultra Fast" boot takes away.

{ pkgs, ... }:

let
  rebootToWindows = pkgs.writeShellApplication {
    name = "reboot-to-windows";
    runtimeInputs = [
      pkgs.efibootmgr
      pkgs.gnused
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      entry=$(efibootmgr | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} Windows Boot Manager\t.*/\1/p' | head -n 1)
      if [ -z "$entry" ]; then
        echo "no \"Windows Boot Manager\" entry in the firmware's boot list" >&2
        exit 1
      fi
      efibootmgr --quiet --bootnext "$entry"
      systemctl reboot
    '';
  };

  powerMenu = pkgs.writeShellApplication {
    name = "power-menu";
    runtimeInputs = [
      pkgs.fuzzel
      pkgs.systemd
      pkgs.libnotify
      pkgs.niri
    ];
    text = ''
      # Only the Eco Mode switch that applies (hosts/desk/eco.nix keeps the
      # chosen mode in a world-readable file; none means stock).
      if [ "$(cat /var/lib/eco/mode 2>/dev/null)" = on ]; then
        eco_item="Eco Mode → off (stock 142 W)"
      else
        eco_item="Eco Mode → on (88 W)"
      fi

      choice=$(printf '%s\n' \
        "$eco_item" \
        "Suspend" \
        "Reboot" \
        "Reboot → boot menu" \
        "Reboot → firmware setup" \
        "Reboot → Windows" \
        "Reboot → MemTest86+" \
        "Power off" \
        "Log out" |
        fuzzel --dmenu --prompt "power › " --lines 9) || exit 0

      run() {
        if ! "$@"; then
          notify-send -u critical -a "Power menu" "$choice failed" "$* — see journalctl -b"
          return 1
        fi
      }

      case "$choice" in
        "Eco Mode → on (88 W)")
          run systemctl start eco@on.service &&
            notify-send -a "Power menu" "Eco Mode on" "88 W / 75 A / 150 A"
          ;;
        "Eco Mode → off (stock 142 W)")
          run systemctl start eco@off.service &&
            notify-send -a "Power menu" "Eco Mode off" "Stock 142 W / 110 A / 170 A"
          ;;
        "Suspend") run systemctl suspend ;;
        "Reboot") run systemctl reboot ;;
        "Reboot → boot menu") run systemctl reboot --boot-loader-menu=30 ;;
        "Reboot → firmware setup") run systemctl reboot --firmware-setup ;;
        "Reboot → Windows") run systemctl start reboot-to-windows.service ;;
        "Reboot → MemTest86+") run systemctl reboot --boot-loader-entry=memtest86.conf ;;
        "Power off") run systemctl poweroff ;;
        "Log out") run niri msg action quit --skip-confirmation ;;
      esac
    '';
  };
in
{
  environment.systemPackages = [
    powerMenu
    pkgs.efibootmgr
  ];

  systemd.services.reboot-to-windows = {
    description = "Boot Windows once, then reboot";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${rebootToWindows}/bin/reboot-to-windows";
    };
  };

  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "reboot-to-windows.service" &&
          action.lookup("verb") == "start" &&
          subject.user == "n8" && subject.local && subject.active) {
        return polkit.Result.YES;
      }
    });
  '';
}
