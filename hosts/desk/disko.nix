# hosts/desk/disko.nix — the BULK DRIVE ONLY.
#
# The fast NVMe (the 2 TB SHPP41-2000GM, serial ADC8N56931060986L) is
# deliberately absent. It belongs to Windows, and this host never mounts it.
# Its controller sits at 0000:11:00.0; Phase 4 will bind it to vfio-pci by
# address and hand it to the guest whole. Until then it is live under the
# ordinary nvme driver and fully visible to Linux, under whichever kernel name
# it gets that boot (it has been both nvme0n1 and nvme1n1) — never aim a
# destructive tool at /dev/nvmeXnY, only at a by-id path. Adding it here for
# "completeness" would destroy the Windows install — there is no second copy.
#
# Both drives are the same SK hynix P41 family and both controllers report
# 1c5c:1959, so the by-id name below is the only thing distinguishing them in
# this file. Phase 0 measured it on 2026-09-24; re-read it before Phase 2's
# destroy run rather than trusting this comment.
{
  disko.devices.disk.bulk = {
    device = "/dev/disk/by-id/nvme-SHPP41-1000GM_SJB8N565511208H0I";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };

        root = {
          size = "200G"; # decided 2026-09-21; the rest is media
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };

        media = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-L" "media" ];
            subvolumes = {
              # btrfs, not ext4, for one reason: this volume holds files nobody
              # opens for months, which is exactly when silent corruption goes
              # unnoticed — and restic would back up the corrupted copy without
              # complaint. Checksums plus a monthly scrub turn bit rot into an
              # alert. No compression: the payload is already-compressed video.
              #
              # nofail: a volume that will not mount must not take the host
              # down with it. Without it local-fs.target fails and desk sits in
              # emergency mode, no SSH or tailnet, until someone is at the
              # keyboard — as it did on 2026-09-26 over a stale /srv/games.
              # With it, the requires = [ "srv-media.mount" ] guards (Samba,
              # restic, Jellyfin, Kavita, Navidrome, slskd, …) fail just those
              # services. nofail also drops the mount's ordering before
              # local-fs.target; x-systemd.before puts it back, so tmpfiles and
              # everything else after local-fs.target still sees the subvolume.
              "/media" = {
                mountpoint = "/srv/media";
                mountOptions = [ "noatime" "nofail" "x-systemd.before=local-fs.target" ];
              };
            };
          };
        };
      };
    };
  };
}
