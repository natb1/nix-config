# Immich: the photo archives in /srv/media as a photo server, with a
# timeline, a map, faces and search by description.
#
# External libraries, as set up from http://desk:2283 after the first login
# (they are Immich's database, not this file), each read in place:
#   iCloud   /srv/media/icloud   (icloudpd's, hosts/desk/icloud.nix)
#   Flickr   /srv/media/flickr   (the 2026 export, unpacked)
# Immich reads, never writes: the immich user is "other" on /srv/media, which
# is r-x, so thumbnails, faces and albums stay in /var/lib/immich and its
# PostgreSQL database, never beside the photos. Deleting from the app is
# therefore not possible; a photo goes away on the share.
#
# The Flickr export has no dates for about a quarter of its files. Each of
# those has an estimated date in a `<file>.xmp` beside it, which Immich reads
# as part of the photo, tagged "Flickr/date estimated" to find them by
# (scripts/flickr-date-estimate.py, and its list in
# /srv/media/flickr/dates-estimated.tsv).
#
# Faces and search run on the CPU (immich-machine-learning, which fetches its
# models on first use). Video transcoding is left on the CPU too: Immich
# transcodes only for playback of the few videos here, and
# accelerationDevices' default, no devices, keeps the units' PrivateDevices.
#
# Tailnet-only, like Navidrome and Jellyfin: it listens on every interface,
# the firewall opens nothing for it, and tailscale0 is trusted
# (modules/nixos/tailscale.nix).
#
# Not managed by this repo: Immich's accounts and libraries. The first visit
# to http://desk:2283 creates the admin and the libraries above. State is in
# /var/lib/immich (thumbnails and video encodes, rebuilt by a rescan) and the
# immich PostgreSQL database (accounts, albums, faces, favourites).

{ ... }:

{
  services.immich = {
    enable = true;
    host = "::";
  };

  # The same footgun as the other servers: without the bulk SSD, Immich would
  # scan empty folders and take every photo out of its libraries, albums and
  # faces with them.
  systemd.services.immich-server = {
    after = [ "srv-media.mount" ];
    requires = [ "srv-media.mount" ];
  };
}
