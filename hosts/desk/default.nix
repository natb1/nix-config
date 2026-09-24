# Host: desk — the native NixOS desktop (Ryzen 7600X, B650I AORUS ULTRA).
#
# Everything here is desk-specific. Config a native NixOS machine and the WSL
# box would both want lives in modules/nixos/ and is imported below.
#
# Rebuild:  sudo nixos-rebuild switch --flake ~/natb1/nix-config#desk
#
# This host shares the machine with a Windows install on the *other* NVMe.
# NixOS owns the 1 TB drive outright (see disko.nix); the 2 TB drive is
# Windows' and is never mounted here. docs/desktop-migration.md is the plan
# this host is being built from, and the reason for most of what looks odd.

{ ... }:

{
  imports = [
    ../../modules/nixos
    ./hardware-configuration.nix
    ./disko.nix
  ];

  # Simultaneously the Tailscale node name, what avahi publishes (desk.local),
  # and the wezterm mux domain — per the README's rule those three move
  # together, so change them together. This is a new Tailscale node, not a
  # rename of `wsl`.
  networking.hostName = "desk";

  # systemd-boot, not GRUB. Two reasons it is spelled out rather than left to
  # the default: NixOS defaults to GRUB, and without a boot loader chosen
  # `nixos-install` fails at *evaluation* asking for boot.loader.grub.devices —
  # which would be discovered at the worst possible moment, with the drive
  # already wiped.
  #
  # canTouchEfiVariables is what writes the NVRAM entry that Phase 2 then
  # reorders with `efibootmgr -o` to put NixOS ahead of Windows.
  #
  # No configurationLimit: this ESP is 1 GiB and nothing competes for it.
  # Secure Boot stays off until Phase 2b swaps this for lanzaboote.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Wi-Fi is the only link: the Intel I225-V port is not cabled, and Phase 0
  # confirmed it (enp13s0, NO-CARRIER). The MediaTek RZ616 (MT7922, mt7921e)
  # is wlp14s0 and needs redistributable firmware to come up at all.
  #
  # The PSK itself is hand-provisioned state under
  # /etc/NetworkManager/system-connections/ — deliberately not in this repo,
  # which is public.
  hardware.enableRedistributableFirmware = true;
  networking.networkmanager.enable = true;

  # networkmanager: nmcli/nmtui without sudo.
  # The remaining groups (libvirtd, kvm, input) arrive with the phases that
  # need them, so a group this host does not yet create cannot warn on switch.
  users.users.n8.extraGroups = [ "networkmanager" ];

  # NOT time.hardwareClockInLocalTime. Phase 0 measured this Windows as
  # RealTimeIsUniversal = 1 — it already keeps the RTC in UTC, which is also
  # NixOS's default. Setting localtime here would *create* the clock fight it
  # looks like it prevents. See docs/desktop-migration.md.

  # First install of this system is on NixOS 26.05. Leave it alone from here;
  # it pins defaults for stateful data, not the release being tracked.
  system.stateVersion = "26.05";
}
