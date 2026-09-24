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
# rclone.conf is hand-provisioned and never in git (this repo is public). It
# holds a Drive refresh token — full read/write on the whole Drive — so it is
# ENCRYPTED, with its password in gnome-keyring. That is the rule this
# no-lock, no-disk-encryption host runs on: anything sensitive sits behind its
# own encryption, the same reason Chrome is pointed at gnome-libsecret in
# desktop.nix. A plaintext token would be readable by anything that reads the
# 1 TB drive outside the session (a live USB, the drive itself).
#
# Provisioning, all hand-run; the plan's Phase 3 section has the record:
#
#   rclone config create gdrive drive scope=drive \
#     client_id=… client_secret=…     # own client, project nix-config-509614
#   python3 -c 'import secrets; print(secrets.token_urlsafe(32))' \
#     | secret-tool store --label='rclone config password' service rclone
#   rclone config encryption set      # reads the password via the variable below
#   systemctl --user start gdrive
#
# Until ~/.config/rclone/rclone.conf exists the unit is skipped by its
# condition rather than failed — "never set up" is not a runtime fault. Once
# the file exists, anything wrong with the remote fails the unit visibly.
# Media storage Step 3 pulls from the same `gdrive` remote with `rclone copy`.

{ pkgs, ... }:

let
  # rclone runs this whenever it needs the config password. If the keyring is
  # locked, libsecret raises gnome-keyring's unlock prompt — the same one
  # Chrome raises, so one unlock per boot serves both.
  passwordCommand = "${pkgs.libsecret}/bin/secret-tool lookup service rclone";
in
{
  # libsecret for secret-tool, which stores and reads the config password.
  environment.systemPackages = [ pkgs.rclone pkgs.libsecret ];

  # Interactive rclone (`rclone lsf gdrive:`, Media Step 3's `rclone copy`)
  # reads the same encrypted config, so it needs the same password source.
  home-manager.users.n8.home.sessionVariables.RCLONE_PASSWORD_COMMAND =
    passwordCommand;

  # A user FUSE mount needs a mountpoint the user owns.
  systemd.tmpfiles.rules = [ "d /mnt/g 0755 n8 users -" ];

  systemd.user.services.gdrive = {
    description = "Google Drive at /mnt/g (rclone)";
    # The graphical session, not default.target: autologin cannot unlock the
    # keyring, so the password can only arrive through the unlock prompt, and
    # the prompt needs a display. Before niri is up it would just fail.
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    # rclone finds the setuid fusermount3 wrapper through PATH; `path` adds
    # /run/wrappers/bin to the unit's PATH rather than replacing it.
    path = [ "/run/wrappers" ];
    environment.RCLONE_PASSWORD_COMMAND = passwordCommand;
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
      # Start waits on the keyring prompt when the keyring is locked. The
      # default 90 s would kill it mid-prompt and raise a fresh prompt on every
      # restart; 15 min is one prompt, answered whenever you get to it.
      TimeoutStartSec = "15min";
      Restart = "on-failure";
      RestartSec = 30;
    };
  };
}
