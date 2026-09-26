# /srv/media as an SMB share — Media storage Step 1.
# docs/desktop-migration.md, "Media storage", is the design. Step 2 (restic
# to Hetzner) is below; Step 3 (bringing the media in) is by hand.
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

{ pkgs, ... }:

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
      # The library is read-only over SMB; batches arrive through
      # media-staging, and media-stage moves them in, on desk. Added
      # 2026-09-25 so that nothing — Finder, a script, an agent that never
      # heard of media-stage — writes into the library past the rename table,
      # the checks and the locks (docs/desktop-migration.md, "Filing a
      # batch"). Deleting or renaming inside the library is done on desk too.
      media = {
        path = "/srv/media";
        browseable = "yes";
        "read only" = "yes";
        "valid users" = "n8";
        "force user" = "n8";
      };
      media-staging = {
        path = "/srv/media/staging";
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
  systemd.tmpfiles.rules = [
    "d /srv/media 0755 n8 users -"
    "d /srv/media/staging 0755 n8 users -"
  ];

  # The procedure, where anyone listing either share sees it. Installed, not
  # symlinked (Samba will not follow a link out of the share into the store),
  # and rewritten by any switch that changes it — tmpfiles' C never replaces
  # an existing file.
  systemd.services.media-readme = {
    description = "Install README.md on the media shares";
    after = [ "srv-media.mount" "systemd-tmpfiles-setup.service" ];
    requires = [ "srv-media.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -m 0444 ${./media-README.md} /srv/media/README.md
      install -m 0444 ${./media-README.md} /srv/media/staging/README.md
    '';
  };

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

  # Step 2: restic to the Hetzner Storage Box u676942, append-only.
  #
  # The box's authorized_keys pins /etc/restic/id_ed25519 to
  #   command="rclone serve restic --stdio --append-only restic/media",restrict
  # so whatever remote command restic sends is ignored, and the repository
  # path lives on the box, not here. desk can add snapshots and cannot delete
  # them: proved 2026-09-25, `forget` got 403 Forbidden and the snapshot
  # survived. Hence no pruneOpts — forget would fail every run. Retention is a
  # manual job with the offline prune key.
  #
  # Not managed by this repo: /etc/restic/media.password (the repository's
  # encryption key: no reset, lose it and the backup is unreadable) and
  # /etc/restic/id_ed25519. Both root 0600, listed in the README.
  services.restic.backups.media = {
    initialize = true;
    paths = [ "/srv/media" ];
    repository = "rclone:";
    passwordFile = "/etc/restic/media.password";
    extraOptions = [
      # BatchMode: an ssh prompt inside restic's pipe cannot be answered and
      # surfaces as an HTTP timeout; fail fast with ssh's own error instead.
      "rclone.program='ssh -p 23 -i /etc/restic/id_ed25519 -o BatchMode=yes u676942@u676942.your-storagebox.de'"
    ];
    extraBackupArgs = [ "--exclude-caches" "--one-file-system" ];
    runCheck = true;
    # Samples, not a full download: ~15 GB/day at 730 GB, over Wi-Fi.
    # %% because the module puts this in ExecStart, where % is a specifier.
    checkOpts = [ "--read-data-subset=2%%" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "2h";
      Persistent = true; # catch up after downtime
      # No WakeSystem: this board's RTC has no alarm (rtc_cmos: "IRQ index 0
      # not found", "no alarms"), and with it set the timer fails to load —
      # "Failed to add realtime event source: Operation not supported".
    };
  };

  systemd.services.restic-backups-media = {
    # Same footgun as Samba: without the bulk SSD, restic would snapshot an
    # empty directory on the root filesystem and report success.
    after = [ "srv-media.mount" ];
    requires = [ "srv-media.mount" ];
    unitConfig.OnFailure = "restic-backups-media-failed.service";
  };

  # The alert until the plan's ntfy exists (<FILL_ME_notify_unit>), as in
  # icloud.nix — but this is a system unit, so it has to reach into n8's
  # session bus. If nobody is logged in, the alert is lost; that is the gap
  # the retirement gate's alerting item closes.
  systemd.services.restic-backups-media-failed = {
    description = "Alert: restic-backups-media failed";
    serviceConfig.Type = "oneshot";
    script = ''
      uid=$(${pkgs.coreutils}/bin/id -u n8)
      ${pkgs.util-linux}/bin/runuser -u n8 -- \
        ${pkgs.coreutils}/bin/env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
        ${pkgs.libnotify}/bin/notify-send -u critical -a restic \
          'Media backup failed' 'journalctl -u restic-backups-media'
    '';
  };

  # The unit runs as root; ssh reads this system-wide known_hosts. The
  # non-default port makes the [host]:port form mandatory.
  # SHA256:XqONwb1S0zuj5A1CDxpOSuD2hnAArV1A3wKY7Z3sdgM, matched against
  # docs.hetzner.com/storage/storage-box/general on 2026-09-25.
  programs.ssh.knownHosts.storagebox = {
    hostNames = [ "[u676942.your-storagebox.de]:23" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICf9svRenC/PLKIL9nk6K/pxQgoiFC41wTNvoIncOxs";
  };
}
