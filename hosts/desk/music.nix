# Navidrome: /srv/media/music as a music server, for the phone and desk alike.
#
# Why a server rather than players reading the SMB share: the library is filed
# by beets (hosts/desk/home/media.nix) and every file carries full tags and
# MusicBrainz ids, so a tag-reading server gives albums, artists, compilations
# and multi-disc sets as MusicBrainz knows them, whatever the folder names.
# It streams (transcoding if asked) and speaks the Subsonic API, so the phone
# uses a Subsonic app with offline caching and CarPlay (Amperfy, recommended
# in docs/desktop-migration.md, "Listening"), and desk uses Feishin, below.
# Favourites, play counts and playlists live here once, not per device.
#
# Tailnet-only, like the Samba share: it listens on every interface, but the
# firewall opens nothing for it, and tailscale0 is trusted
# (modules/nixos/tailscale.nix). From the phone: http://desk:4533.
#
# Not managed by this repo: Navidrome's accounts. The first visit to
# http://desk:4533 creates the admin; the phone logs in with it. State is in
# /var/lib/navidrome (the database, rebuilt by a rescan if lost, except
# playlists, favourites and play counts).

{ ... }:

{
  services.navidrome = {
    enable = true;
    settings = {
      MusicFolder = "/srv/media/music";
      Address = "0.0.0.0";
      Port = 4533;
      # Albums as beets filed them: MusicBrainz album ids group the discs of
      # a set and keep two releases of one title apart.
      Scanner.GroupAlbumReleases = false;
      # New imports appear without a manual rescan; the file watcher is the
      # default, this is the backstop.
      Scanner.Schedule = "@every 6h";
      EnableInsightsCollector = false;
    };
  };

  # The same footgun as Samba (hosts/desk/media.nix): without the bulk SSD,
  # Navidrome would scan an empty /srv/media/music on the root filesystem and
  # mark the whole library missing.
  systemd.services.navidrome = {
    after = [ "srv-media.mount" ];
    requires = [ "srv-media.mount" ];
  };

  # beets creates it on the first import; the server should not wait for one.
  systemd.tmpfiles.rules = [ "d /srv/media/music 0755 n8 users -" ];
}
