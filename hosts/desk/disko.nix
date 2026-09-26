# hosts/desk/disko.nix — the BULK DRIVE ONLY.
#
# The fast NVMe (the 2 TB SHPP41-2000GM, serial ADC8N56931060986L) is
# deliberately absent. It belongs to Windows, and this host never mounts it:
# its controller sits at 0000:11:00.0 and is bound to vfio-pci at boot, then
# handed to the guest whole (Phase 4). Adding it here for "completeness" would
# destroy the Windows install — there is no second copy.
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
              "/media" = {
                mountpoint = "/srv/media";
                mountOptions = [ "noatime" ];
              };

              # The HOST-side Steam library (native + Proton titles). Not on the
              # 200 GB root — that was sized before this library was counted.
              # Its own subvolume so snapshots and the restic paths stay
              # media-only.
              #
              # No nodatacow: btrfs mount options are filesystem-wide, so it
              # would silently switch off checksums for /srv/media too, and game
              # files are write-once anyway.
              "/games" = {
                mountpoint = "/srv/games";
                mountOptions = [ "noatime" ];
              };
            };
          };
        };
      };
    };
  };
}
