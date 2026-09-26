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
    ./desktop.nix
    ./gdrive.nix
    ./media.nix
    ./music.nix
    ./jellyfin.nix
    ./kavita.nix
    ./icloud.nix
    ./printing.nix
    ./iphone.nix
    ./eco.nix
    ./sensors.nix
    ./power-menu.nix
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
  # MemTest86+ as a boot menu entry, for BIOS tuning's validation set
  # (docs/desktop-migration.md): no USB stick needed for it.
  boot.loader.systemd-boot.memtest86.enable = true;

  # A bad generation falls back on its own, without the boot menu — the
  # precondition for firmware Fast Boot "Ultra Fast", which turns the keyboard
  # off until Linux loads (docs/desktop-migration.md, BIOS tuning step 7).
  # - bootCounting: each new entry gets 3 tries; systemd-bless-boot marks it
  #   good once boot-complete.target is reached, and an entry that runs out of
  #   tries is skipped for the previous generation.
  # - panic=10: a kernel panic reboots after 10 s (the default is to hang).
  # - RuntimeWatchdogSec: systemd pets the chipset's SP5100 TCO watchdog; if
  #   the system hangs hard enough that it stops, the board resets in 30 s.
  # Together a panic or a hang costs a try instead of waiting for a person.
  boot.loader.systemd-boot.bootCounting.enable = true;
  # No menu countdown (5.3 s of every boot, measured 2026-09-25). The menu is
  # still there: hold Space while the machine boots, or ask for it from Linux
  # with `systemctl reboot --boot-loader-menu=30`, or skip it with
  # `systemctl reboot --boot-loader-entry=<entry>` (list: `=help`).
  boot.loader.timeout = 0;
  boot.kernelParams = [ "panic=10" ];
  systemd.settings.Manager.RuntimeWatchdogSec = "30s";

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

  # Without this the machine is unadministrable on first boot, and finding
  # that out costs a live-USB chroot.
  #
  # This repo sets no password for n8 and none for root — nothing in
  # modules/nixos/ ever needed one, because NixOS-WSL arranges its own
  # passwordless sudo for the default user. On a native host that inheritance
  # does not apply: getty autologin lets you *in* without a password, but
  # `sudo` and `su` then prompt for passwords that do not exist, so
  # `nixos-rebuild switch` is impossible on the machine you just installed.
  #
  # Passwordless sudo rather than a password because it costs nothing here
  # that is not already spent. The desktop decision (see desktop.nix) is
  # autologin on tty1 with no screen lock, so physical access already means
  # full access; a sudo password on top would be theatre. What actually
  # protects things is elsewhere and unaffected: SSH is key-only with
  # PasswordAuthentication off, and secrets live in gnome-keyring under its
  # own password.
  #
  # nixos-install still prompts for a root password at the end of Phase 2.
  # Set one — it is the break-glass for single-user mode if this file ever
  # stops evaluating.
  security.sudo.wheelNeedsPassword = false;

  # NOT time.hardwareClockInLocalTime. Phase 0 measured this Windows as
  # RealTimeIsUniversal = 1 — it already keeps the RTC in UTC, which is also
  # NixOS's default. Setting localtime here would *create* the clock fight it
  # looks like it prevents. See docs/desktop-migration.md.

  # First install of this system is on NixOS 26.05. Leave it alone from here;
  # it pins defaults for stateful data, not the release being tracked.
  system.stateVersion = "26.05";
}
