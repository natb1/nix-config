# /srv/media as an SMB share — Media storage Step 1.
# docs/desktop-migration.md, "Media storage", is the design; Steps 2 (restic
# to Hetzner) and 3 (bringing the media in) land here later, in that order.
#
# SMB, not NFS: the clients are the MacBook and Windows, and SMB is the one
# protocol both speak well.
#
# Tailnet-only, plus the Windows guest over virbr0 — decided 2026-09-24. The
# Mac already reaches desk over a *direct* tailnet path (tailscale ping shows
# no relay), so the LAN would add no speed, only a second way in: port 445 on
# Wi-Fi, where `hosts allow` also turned out to let IPv6 through. What that
# gives up is Finder's sidebar discovery (mDNS is LAN-only; use
# smb://desk/media) and access from bare-metal Windows unless it runs
# Tailscale — install Tailscale there rather than reopening Wi-Fi.
#
# Not managed by this repo: Samba's own password database. `smbpasswd -a n8`
# is hand-provisioned, and listed in the README's unmanaged-state section.

{ ... }:

{
  services.samba = {
    enable = true;
    openFirewall = false; # opened per-interface below instead

    # Both default on, and this share needs neither. nmbd is NetBIOS naming,
    # which only SMB1-era clients use, and winbindd is for joining a domain.
    nmbd.enable = false;
    winbindd.enable = false;

    settings = {
      global = {
        "server string" = "desk";
        "workgroup" = "WORKGROUP";
        # Reachability is scoped by `hosts allow` plus the per-interface
        # firewall rules below — NOT by `bind interfaces only`. smbd binds the
        # interfaces that exist when it starts and never picks up later ones,
        # and tailscale0 and virbr0 both routinely appear after it: the share
        # would silently be unreachable from the tailnet and the guest until
        # the next restart.
        #
        # Loopback, libvirt's default NAT network, and the tailnet's IPv4
        # (CGNAT) and IPv6 ranges — MagicDNS can hand the Mac either.
        "hosts allow" = "127.0.0.1 ::1 192.168.122.0/24 100.64.0.0/10 fd7a:115c:a1e0::/48";
        # ALL, not 0.0.0.0/0: that matches only IPv4, and an IPv6 client that
        # matched neither list was let straight through (found 2026-09-24).
        "hosts deny" = "ALL";
        "server min protocol" = "SMB3";
        # macOS: resource forks and xattrs without littering ._ files everywhere.
        "vfs objects" = "catia fruit streams_xattr";
        "fruit:metadata" = "stream";
        "fruit:posix_rename" = "yes";
      };
      media = {
        path = "/srv/media";
        browseable = "yes";
        "read only" = "no";
        "valid users" = "n8";
        "force user" = "n8";
        "create mask" = "0644";
        "directory mask" = "0755";
      };
    };
  };

  # disko creates the subvolume root-owned, and `force user = n8` means every
  # write through the share is n8's — so without this the share is read-only
  # in practice. `d` adjusts the owner of a directory that already exists.
  systemd.tmpfiles.rules = [ "d /srv/media 0755 n8 users -" ];

  # WS-Discovery, so the Windows guest finds the share on virbr0. Multicast
  # discovery does not cross the tailnet, so this is for the guest only.
  #
  # No mDNS advertisement, deliberately: it would announce on Wi-Fi a share
  # Wi-Fi cannot reach. (If the LAN ever comes back, note that nixpkgs builds
  # samba with enableMDNS = false, so smbd's `multicast dns register` is a
  # silent no-op — it needs a static services.avahi.extraServiceFiles entry.)
  services.samba-wsdd.enable = true;

  # tailscale0 is a trusted interface in modules/nixos/tailscale.nix, so the
  # tailnet needs no rule here. No rule for wlp14s0 either: that is what keeps
  # the share off the LAN.
  #
  # The Windows guest, NATed behind virbr0. The bridge arrives with libvirt
  # (Phase 4); a rule for an interface that does not exist yet is inert.
  networking.firewall.interfaces.virbr0 = {
    allowedTCPPorts = [ 445 5357 ];
    allowedUDPPorts = [ 3702 ];
  };

  # Bit rot on a volume nobody reads for months is the failure you find out
  # about from a restore. Make it an alert instead.
  #
  # Listed explicitly: the default is every btrfs mountpoint, and /srv/media
  # and /srv/games are two subvolumes of one filesystem — the default would
  # scrub the same device twice. Scrub works per filesystem, so this one entry
  # covers the games subvolume too.
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/srv/media" ];
  };

  # THE footgun. Without this, a bulk SSD that fails to mount leaves Samba
  # serving an empty /srv/media *on the root filesystem* — and clients
  # cheerfully write into it. Silent, and you find out when the root disk fills.
  systemd.services.samba-smbd = {
    after = [ "srv-media.mount" ];
    requires = [ "srv-media.mount" ];
  };
}
