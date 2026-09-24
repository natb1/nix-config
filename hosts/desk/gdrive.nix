# Google Drive at /mnt/g, over rclone. Replaces hosts/wsl/mounts.nix, which
# drvfs-mounted the G: that Google Drive for desktop presents on Windows —
# there is no Windows host under this machine to present it.
# docs/desktop-migration.md, Phase 3 "Google Drive", is the design.
#
# Same path as on WSL, so habits and scripts that know /mnt/g carry over.
#
# What carries over from the WSL module is its lesson, not its code: a
# network mount that can vanish mid-session must fail loudly. So there is no
# RemainAfterExit and no healer timer. rclone signals readiness (Type=notify),
# exits when the mount dies, and systemd restarts it — and a boot where the
# Wi-Fi is not up by login is the same case, retried every 30 s.
#
# The OAuth token is hand-provisioned, never in git (this repo is public):
#
#   rclone config    # n → name "gdrive" → type "drive" → scope "drive" →
#                    # defaults → auto config: yes (opens Chrome)
#   systemctl --user start gdrive
#
# Until ~/.config/rclone/rclone.conf exists the unit is skipped by its
# condition rather than failed — "never set up" is not a runtime fault. Once
# the file exists, anything wrong with the remote fails the unit visibly.
# Media storage Step 3 pulls from the same `gdrive` remote with `rclone copy`.

{ pkgs, ... }:

{
  environment.systemPackages = [ pkgs.rclone ];

  # A user FUSE mount needs a mountpoint the user owns.
  systemd.tmpfiles.rules = [ "d /mnt/g 0755 n8 users -" ];

  systemd.user.services.gdrive = {
    description = "Google Drive at /mnt/g (rclone)";
    wantedBy = [ "default.target" ];
    # rclone finds the setuid fusermount3 wrapper through PATH; `path` adds
    # /run/wrappers/bin to the unit's PATH rather than replacing it.
    path = [ "/run/wrappers" ];
    unitConfig = {
      # A system-level user unit reaches every user manager, root's included.
      ConditionUser = "n8";
      ConditionPathExists = "%h/.config/rclone/rclone.conf";
    };
    serviceConfig = {
      Type = "notify";
      ExecStart = builtins.concatStringsSep " " [
        "${pkgs.rclone}/bin/rclone mount gdrive: /mnt/g"
        # Full caching is what makes writes behave like a local disk: files
        # are written to cache and uploaded after, so editors that rewrite
        # in place or seek while writing work.
        "--vfs-cache-mode full"
        # Bounded, because the cache lives on the 200 G root filesystem.
        "--vfs-cache-max-size 20G"
        "--dir-cache-time 5m"
      ];
      ExecStop = "/run/wrappers/bin/fusermount3 -u /mnt/g";
      Restart = "on-failure";
      RestartSec = 30;
    };
  };
}
