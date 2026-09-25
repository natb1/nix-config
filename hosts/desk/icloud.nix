# iCloud Photos → /srv/media/icloud/<instance>, over icloudpd.
# docs/desktop-migration.md, Media storage "Step 4", is the design.
#
# One template, `icloudpd@<instance>`, and one hand-provisioned env file per
# instance, ~/.config/icloudpd/<instance>.env (the Apple IDs stay out of this
# public repo):
#
#   APPLE_ID=someone@example.com
#   LIBRARY=PrimarySync          # or SharedSync-<UUID>, from `icloudpd-login`
#
# Three instances, two shapes:
#   shared     n8's Apple ID, the Shared Library. Daily timer, forever.
#   n8, <wife> each personal library (PrimarySync), once, by hand:
#              `systemctl --user start --no-block icloudpd@n8`. A rerun
#              downloads only what is new, so it doubles as the verification.
#
# Until an instance's env file exists it is skipped by its condition rather
# than failed, as in gdrive.nix — "never set up" is not a runtime fault.
#
# Add-only, deliberately: no --auto-delete, no --delete-after-download, no
# --keep-icloud-recent-days. Anyone in the Shared Library can delete from it,
# and the backup is what is left when they do.
#
# A user unit, not a system one, for the password: it lives in gnome-keyring
# (icloudpd's `keyring` provider, service `pyicloud://icloud-password`), the
# same no-plaintext rule as rclone's config password in gdrive.nix. The
# session cookies are NOT behind that encryption — pyicloud writes them in the
# clear to ~/.local/state/icloudpd/<apple-id>/, and they are photo access for
# as long as Apple honours them (roughly two months). Accepted for n8's own
# account; for anyone else's, `icloudpd-forget` once the backfill is verified.
#
# Provisioning, per Apple ID, from a terminal on desk (or over SSH once the
# keyring is unlocked):
#
#   icloudpd-login <instance>     # password (saved to the keyring) + 2FA code,
#                                 # then prints the account's libraries
#
# The session lapses on Apple's schedule. The next run then fails for want of
# a 2FA code — there is no terminal to type it into — and icloudpd-failed@
# says so on the desktop. The fix is `icloudpd-login shared` again.

{ pkgs, ... }:

let
  envFile = instance: "$HOME/.config/icloudpd/${instance}.env";

  # Same --cookie-directory as the unit, so a login here is the session the
  # unit uses. Keyed on the Apple ID, not the instance: `shared` and `n8` are
  # one account and share one session.
  loginScript = pkgs.writeShellApplication {
    name = "icloudpd-login";
    runtimeInputs = [ pkgs.icloudpd ];
    text = ''
      instance=''${1:?usage: icloudpd-login <instance>}
      # shellcheck source=/dev/null
      . "${envFile "$instance"}"
      cookies="''${XDG_STATE_HOME:-$HOME/.local/state}/icloudpd/$APPLE_ID"
      # keyring first, so a stored password is used; console second, and
      # icloudpd writes a console-typed password back to the keyring.
      icloudpd --username "$APPLE_ID" --cookie-directory "$cookies" \
        --password-provider keyring --password-provider console \
        --mfa-provider console --log-level info --auth-only
      icloudpd --username "$APPLE_ID" --cookie-directory "$cookies" \
        --password-provider keyring --log-level error --list-libraries
    '';
  };

  # For an account whose backfill is done: drop its session and password, so
  # nothing on this machine can reach it any more.
  forgetScript = pkgs.writeShellApplication {
    name = "icloudpd-forget";
    runtimeInputs = [ pkgs.libsecret pkgs.coreutils ];
    text = ''
      instance=''${1:?usage: icloudpd-forget <instance>}
      # shellcheck source=/dev/null
      . "${envFile "$instance"}"
      rm -rf -- "''${XDG_STATE_HOME:-$HOME/.local/state}/icloudpd/$APPLE_ID"
      # Python keyring's Secret Service attributes. Not `icloud
      # --delete-from-keyring`: it goes on to log in after deleting.
      secret-tool clear service pyicloud://icloud-password username "$APPLE_ID"
      echo "forgot $APPLE_ID; ${envFile "$instance"} left in place"
    '';
  };
in
{
  environment.systemPackages = [ pkgs.icloudpd loginScript forgetScript ];

  systemd.user.services."icloudpd@" = {
    description = "iCloud Photos → /srv/media/icloud/%i";
    # The keyring is only reachable inside the session, as for gdrive.
    after = [ "graphical-session.target" ];
    unitConfig = {
      ConditionUser = "n8";
      ConditionPathExists = "%h/.config/icloudpd/%i.env";
      # A user unit cannot `requires=` the system's srv-media.mount, so this
      # is media.nix's Samba guard in the form a user unit can have: without
      # the bulk SSD mounted, fail rather than fill the root filesystem.
      AssertPathIsMountPoint = "/srv/media";
      OnFailure = "icloudpd-failed@%i.service";
    };
    serviceConfig = {
      # oneshot: no start timeout, which a first backfill of a whole library
      # needs — it runs for hours.
      Type = "oneshot";
      EnvironmentFile = "%h/.config/icloudpd/%i.env";
      StateDirectory = "icloudpd";
      StateDirectoryMode = "0700";
      # Folder layout, sizes and Live Photo handling are icloudpd's defaults:
      # originals, YYYY/MM/DD, the Live Photo video beside its still.
      ExecStart = builtins.concatStringsSep " " [
        "${pkgs.icloudpd}/bin/icloudpd"
        "--username \${APPLE_ID}"
        "--cookie-directory %S/icloudpd/\${APPLE_ID}"
        # keyring only: a run with no terminal must fail, not wait on a prompt.
        "--password-provider keyring"
        "--mfa-provider console"
        "--library \${LIBRARY}"
        "--directory /srv/media/icloud/%i"
        "--log-level info"
        "--no-progress-bar"
      ];
    };
  };

  # The alert until the plan's ntfy exists (<FILL_ME_notify_unit>): a
  # critical pop-up, which swaync keeps in its history if nobody was looking.
  systemd.user.services."icloudpd-failed@" = {
    description = "Alert: icloudpd@%i failed";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = builtins.concatStringsSep " " [
        "${pkgs.libnotify}/bin/notify-send -u critical -a iCloud"
        "'iCloud backup failed: %i'"
        "'journalctl --user -u icloudpd@%i — if it wants a 2FA code: icloudpd-login %i'"
      ];
    };
  };

  # Only the shared library is ongoing; the personal ones are one-time.
  # Persistent, because desk sleeps: a run missed while suspended happens on
  # wake.
  systemd.user.timers."icloudpd@shared" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
