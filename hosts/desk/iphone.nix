# The iPhone, paired to desk over Bluetooth: its notifications in swaync, and
# SMS/iMessage read and reply. docs/desktop-migration.md, "iPhone
# notifications", is the design.
#
# Tether, not ancs4linux (decided 2026-09-24). ancs4linux's author no longer
# uses it and points to Tether, which is actively developed, ships this NixOS
# module, and does the same ANCS notification mirroring plus MAP/PBAP
# messages and contacts. None of that needs an iPhone app: iOS serves it to
# any bonded Bluetooth accessory. Tether's iOS app is for its Wi-Fi features
# (clipboard, files), which are fenced off below — they would need a LAN port and mDNS,
# and desk's services are tailnet-only.
#
# Two things change for the whole machine, both required by Tether:
# - bluetoothd runs with Experimental = true. ANCS needs BlueZ's bearer API,
#   and it must be on *before* pairing: a bond made without it has no LE half
#   and never carries notifications.
# - desk presents as Class of Device Hands-Free (tether-btclass@hci0). iOS
#   only offers "Show Notifications" / "Sync Contacts" to that class.
#
# Pairing is hand-run, once: `tether --bt-status`, then pair from the GTK app
# (tether-gtk) or `tether --bt-pair <addr>`, and allow the permissions on the
# phone. The bond lives in /var/lib/bluetooth and Tether's own state in
# ~/.config/tether — both unmanaged state, listed in the README.

{ lib, pkgs, inputs, ... }:

let
  # The iPhone can stop answering on LE while Classic stays up: texts (MAP)
  # keep arriving, every other notification (ANCS) silently stops, and only
  # turning Bluetooth off and on *on the phone* clears it — nothing on desk
  # can (Tether's docs/BLUETOOTH.md, 2026-08-19; seen here 2026-09-24).
  # That looks like "no notifications lately", so say it out loud: one
  # swaync alert per episode, after five minutes of Classic up and
  # notifications down. Genuinely away, Classic is down too, and it stays
  # quiet. The alert withdraws itself once notifications flow again (after
  # the Bluetooth cycle), and only then: leaving while wedged keeps it up.
  ancsWatch = pkgs.writeShellApplication {
    name = "tether-ancs-watch";
    runtimeInputs = [
      pkgs.tether
      pkgs.libnotify
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.systemd
    ];
    text = ''
      down=0
      alert=""
      while true; do
        status=$(timeout 30 tether --bt-connection 2>/dev/null || true)
        if grep -q '^BR/EDR: *yes' <<<"$status" &&
          grep -q '^Notifications: *no' <<<"$status"; then
          down=$((down + 1))
        else
          down=0
        fi
        if [ "$down" -ge 5 ] && [ -z "$alert" ]; then
          alert=$(notify-send -p -a Tether -i phone "iPhone notifications are stuck" \
            "Texts still arrive; other notifications do not. Turn Bluetooth off and on in the iPhone's Settings.")
        fi
        if [ -n "$alert" ] && grep -q '^Notifications: *yes' <<<"$status"; then
          busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications \
            org.freedesktop.Notifications CloseNotification u "$alert" || true
          alert=""
        fi
        sleep 60
      done
    '';
  };
in
{
  # The flake's overlay rather than the module's default package: the default
  # calls package.nix without the npmConfigHook the flake itself passes.
  nixpkgs.overlays = [ inputs.tether.overlays.default ];

  programs.tether = {
    enable = true;
    package = pkgs.tether;
    bluetooth.enable = true;
  };

  # The MT7922's Bluetooth half; firmware comes with
  # hardware.enableRedistributableFirmware in default.nix.
  hardware.bluetooth.powerOnBoot = true;
  # Pairing UI for everything that is not the phone. The applet is started by
  # home-manager's user unit, not XDG autostart, which niri does not run.
  services.blueman.enable = true;
  home-manager.users.n8.services.blueman-applet.enable = true;

  # tetherd, the daemon. The package ships the user unit; this starts it with
  # the graphical session. Upstream deliberately leaves it untied (it runs
  # headless, only skipping clipboard sync), but on desk it has to launch a
  # GUI: a notification's Reply button runs `tether-gtk --thread=…`, which
  # inherits tetherd's environment. Started from default.target, tetherd can
  # come up before niri exports WAYLAND_DISPLAY, and Reply would then have no
  # display to open on.
  systemd.packages = [ pkgs.tether ];
  systemd.user.services.tetherd = {
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    # Both are run from PATH, which a user unit keeps minimal: tether-gtk for
    # Reply (it failed with "No such file or directory", 2026-09-24), and
    # btmgmt for a read-only `btmgmt info` — the secure-connections line in
    # `tether --bt-status`.
    path = [
      pkgs.tether
      pkgs.bluez
    ];
    # tetherd looks for BlueZ once, at start, and if org.bluez is not on the
    # system bus it disables messages and notifications until restarted. A
    # user unit cannot order itself after bluetooth.service, and on the first
    # switch it lost that race by a second (2026-09-24), so wait for the name.
    # After 60 s it starts anyway — without Bluetooth, and it says so in its
    # log — rather than not at all.
    serviceConfig.ExecStartPre = [
      (pkgs.writeShellScript "tetherd-wait-for-bluez" ''
        for _ in $(${pkgs.coreutils}/bin/seq 60); do
          ${pkgs.systemd}/bin/busctl --system status org.bluez >/dev/null 2>&1 && exit 0
          ${pkgs.coreutils}/bin/sleep 1
        done
        echo "org.bluez is not on the system bus after 60 s; starting without it" >&2
      '')
    ];
  };

  systemd.user.services.tether-ancs-watch = {
    description = "Alert when the iPhone stops sending notifications to tetherd";
    wantedBy = [ "graphical-session.target" ];
    after = [
      "graphical-session.target"
      "tetherd.service"
    ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = lib.getExe ancsWatch;
      Restart = "on-failure";
    };
  };

  # tetherd's Wi-Fi half has no off switch: it always listens on 5134 and
  # always publishes _tether._tcp through avahi, whatever programs.tether.wifi
  # says (that option only configures avahi and the firewall). Scope it from
  # outside instead, the same tailnet-only rule as media.nix and printing.nix:
  #
  # - No mDNS announcement: stop avahi publishing *application* services on
  #   desk. That is only Tether here — CUPS browsing is off and Samba has no
  #   mDNS — and desk.local itself (publish.addresses) is unaffected.
  # - No port 5134 on the tailnet, which is otherwise open because
  #   tailscale0 is trusted. Inserted at the top of nixos-fw, ahead of the
  #   trusted-interface accept. Wi-Fi never had it.
  services.avahi.publish.userServices = lib.mkForce false;
  networking.firewall.extraCommands = ''
    iptables -I nixos-fw -i tailscale0 -p tcp --dport 5134 -j nixos-fw-refuse
    ip6tables -I nixos-fw -i tailscale0 -p tcp --dport 5134 -j nixos-fw-refuse
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D nixos-fw -i tailscale0 -p tcp --dport 5134 -j nixos-fw-refuse 2>/dev/null || true
    ip6tables -D nixos-fw -i tailscale0 -p tcp --dport 5134 -j nixos-fw-refuse 2>/dev/null || true
  '';

  # Keep the phone's audio on the phone. Stock WirePlumber advertises desk as
  # a speaker and hands-free unit, and a bonded iPhone routes its calls,
  # music and system sounds to it. These roles keep only what headphones use
  # (playback and the headset mic), which is Tether's own recommendation —
  # and dropping hfp_hf is also what gives BlueZ, and so Tether, call control.
  services.pipewire.wireplumber.extraConfig."51-no-phone-audio" = {
    "monitor.bluez.properties"."bluez5.roles" = [
      "a2dp_source"
      "bap_source"
      "hfp_ag"
    ];
  };
}
