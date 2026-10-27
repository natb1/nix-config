# Immich: the photo archives in /srv/media as a photo server, with a
# timeline, a map, faces and search by description — and, from the Immich
# iPhone app, the phones' own backup, in place of iCloud Photos
# (docs/desktop-migration.md, "Step 6").
#
# External libraries, as set up from http://desk:2283 after the first login
# (they are Immich's database, not this file), each read in place:
#   iCloud   /srv/media/icloud   (icloudpd's, hosts/desk/icloud.nix)
#   Flickr   /srv/media/flickr   (the 2026 export, unpacked)
# Immich reads those, never writes: the immich user is "other" on
# /srv/media, which is r-x. Deleting one of them from the app is therefore
# not possible; a photo goes away on the share.
#
# What the phones upload is different: Immich owns it, in its media location,
# /srv/media/immich (upload/ as it arrives, library/ once the storage
# template files it). That is on the bulk SSD, not /var/lib/immich on the
# root disk, so restic's daily snapshot of /srv/media carries the originals
# to Hetzner, and with them backups/, Immich's own nightly pg_dumpall of its
# database (Administration → Settings → Backup; on by default, 14 kept).
# thumbs/ and encoded-video/ are rebuilt by a rescan and stay out of restic
# (hosts/desk/media.nix).
#
# /srv/media/immich is immich's alone, 0700, no ACLs: not the media group's
# (media-acl skips it, hosts/desk/media-group.nix) and not browsable by n8
# over the share. It is the household's personal photos, and nothing but
# Immich should write there. A new directory under /srv/media inherits the
# group's default ACL, which would override Immich's UMask, so the server
# strips ACLs from its tree before each start.
#
# The faces, search and video notes, unchanged: faces and search run on the
# CPU (immich-machine-learning, which fetches its models on first use). Video
# transcoding is left on the CPU too, and accelerationDevices' default, no
# devices, keeps the units' PrivateDevices. Phone videos are now most of
# what it transcodes, for playback only; the originals are what is kept.
#
# The Flickr export has no dates for about a quarter of its files. Each of
# those has an estimated date in a `<file>.xmp` beside it, which Immich reads
# as part of the photo, tagged "Flickr/date estimated" to find them by
# (scripts/flickr-date-estimate.py, and its list in
# /srv/media/flickr/dates-estimated.tsv).
#
# Tailnet-only, like Navidrome and Jellyfin: it listens on every interface,
# the firewall opens nothing for it, and tailscale0 is trusted
# (modules/nixos/tailscale.nix). So the phones back up only while Tailscale
# is connected on them.
#
# Not managed by this repo: Immich's accounts, libraries and settings (the
# storage template, the backup job). The first visit to http://desk:2283
# creates the admin and the libraries above. State is in /srv/media/immich
# and the immich PostgreSQL database (accounts, albums, faces, favourites,
# and which uploaded file is whose).

{ lib, pkgs, ... }:

let
  mediaLocation = "/srv/media/immich";
in
{
  services.immich = {
    enable = true;
    host = "::";
    inherit mediaLocation;
  };

  # The module only adjusts its media location (`e`) and leaves creating a
  # non-default one to the host. `d` does both.
  systemd.tmpfiles.settings.immich.${mediaLocation} = lib.mkForce {
    d = {
      user = "immich";
      group = "immich";
      mode = "0700";
    };
  };

  # The same footgun as the other servers: without the bulk SSD, Immich would
  # scan empty folders and take every photo out of its libraries, albums and
  # faces with them — and now write the phones' uploads to the root disk.
  systemd.services.immich-server = {
    after = [ "srv-media.mount" "media-acl.service" ];
    requires = [ "srv-media.mount" ];
    # As immich, the owner of everything there, which is all setfacl and
    # chmod need. Idempotent; on a tree that already has none, a walk.
    serviceConfig.ExecStartPre = [
      "${pkgs.acl}/bin/setfacl -R -b ${mediaLocation}"
      "${pkgs.coreutils}/bin/chmod -R go= ${mediaLocation}"
    ];
  };
}
