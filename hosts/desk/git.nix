# /srv/git: bare git repositories that live on desk and nowhere else.
#
# For work that should not be on GitHub: the repository is the remote, and
# the offsite copy is the restic backup (hosts/desk/media.nix), which takes
# this directory along with /srv/media. A bare repository holds only what
# was committed and pushed, so the backup never catches a working tree
# half-edited.
#
# n8's alone: 0700, so no other account on desk reads it, and it is not on
# either SMB share. It is reached as a path on desk and over SSH from the
# tailnet:
#
#   git init --bare -b main /srv/git/<name>.git      # once, on desk
#   git clone /srv/git/<name>.git                    # on desk
#   git clone desk:/srv/git/<name>.git               # from the Mac
#
# On the root filesystem, not under /srv/media: media-acl
# (hosts/desk/media-group.nix) gives the media group everything under there.
#
# Not managed by this repo: the repositories themselves. Which ones exist,
# and what they hold, is not this file's business.

{ ... }:

{
  systemd.tmpfiles.rules = [
    "d /srv/git 0700 n8 users -"
  ];

  # Added to the media backup rather than given a repository of its own: the
  # Storage Box key is pinned to that one repository (media.nix), and a
  # second would need a second key and password provisioned by hand.
  # --one-file-system there is per path, so this one on / is still walked.
  services.restic.backups.media.paths = [ "/srv/git" ];

  # slskd runs as n8 (soulseek.nix), so 0700 does not keep it out, and it
  # serves files to strangers. It shares only music/, and its sandbox makes
  # the rest read-only; this takes /srv/git out of its view altogether, so
  # no share added later, by config or through its API, can reach in here.
  # (/home is already hidden from it: the module sets ProtectHome.)
  systemd.services.slskd.serviceConfig.InaccessiblePaths = [ "/srv/git" ];
}
