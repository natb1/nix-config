# The iPhone, paired to desk over Bluetooth: its notifications in swaync, and
# SMS/iMessage read and reply. docs/desktop-migration.md, "iPhone
# notifications", is the design.
#
# Tether, not ancs4linux (decided 2026-09-24). ancs4linux's author no longer
# uses it and points to Tether, which is actively developed, ships this NixOS
# module, and does the same ANCS notification mirroring plus MAP/PBAP
# messages and contacts. None of that needs an iPhone app: iOS serves it to
# any bonded Bluetooth accessory. Tether's iOS app is for its Wi-Fi features
# (clipboard, files), which stay off — they would need a LAN port and mDNS,
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

{ pkgs, inputs, ... }:

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

  # tetherd, the daemon. The package ships the user unit; this enables it for
  # every login. It is deliberately not tied to the graphical session —
  # it runs without Wayland and only skips clipboard sync.
  systemd.packages = [ pkgs.tether ];
  systemd.user.services.tetherd.wantedBy = [ "default.target" ];

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
