# /srv/media as an SMB share — Media storage Step 1.
# docs/desktop-migration.md, "Media storage", is the design; Steps 2 (restic
# to Hetzner) and 3 (bringing the media in) land here later, in that order.
#
# SMB, not NFS: the clients are the MacBook and Windows (bare metal over the
# LAN, or the guest over virbr0), and SMB is the one protocol both speak well.
#
# Not managed by this repo: Samba's own password database. `smbpasswd -a n8`
# is hand-provisioned, and listed in the README's unmanaged-state section.

{ ... }:

{
  services.samba = {
    enable = true;
    openFirewall = false; # opened per-interface below instead

    # Both default on, and this share needs neither. nmbd is NetBIOS naming,
    # which only SMB1-era clients use — discovery is mDNS (Finder) and
    # WS-Discovery (Windows) — and winbindd is for joining a domain.
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
        "hosts allow" = "127.0.0.1 192.168.0.0/16 100.64.0.0/10"; # LAN + virbr0 + tailnet CGNAT
        "hosts deny" = "0.0.0.0/0";
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

  # Discovery: WS-Discovery for Windows, mDNS for Finder.
  services.samba-wsdd.enable = true;

  # avahi itself is on for every Linux host (modules/nixos/default.nix), but
  # smbd cannot register with it: nixpkgs builds samba with enableMDNS = false,
  # so `multicast dns register = yes` is silently a no-op and only
  # _workstation gets published (seen 2026-09-24). A static service file does
  # the same job without rebuilding samba from source. _device-info is only
  # the Finder sidebar icon.
  services.avahi.extraServiceFiles.smb = ''
    <?xml version="1.0" standalone='no'?>
    <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
    <service-group>
      <name replace-wildcards="yes">%h</name>
      <service>
        <type>_smb._tcp</type>
        <port>445</port>
      </service>
      <service>
        <type>_device-info._tcp</type>
        <port>0</port>
        <txt-record>model=RackMac</txt-record>
      </service>
    </service-group>
  '';

  # tailscale0 is a trusted interface in modules/nixos/tailscale.nix, so the
  # tailnet needs no rule here. Wi-Fi and the guest's NAT bridge do.
  networking.firewall.interfaces.wlp14s0 = {
    allowedTCPPorts = [ 445 5357 ];
    allowedUDPPorts = [ 3702 ];
  };
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
