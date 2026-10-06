# Navidrome: /srv/media/music as a music server, for the phone and desk alike.
#
# Why a server rather than players reading the SMB share: the library is filed
# by beets (hosts/desk/home/media-tools.nix) and every file carries full tags
# and MusicBrainz ids, so a tag-reading server gives albums, artists,
# compilations and multi-disc sets as MusicBrainz knows them, whatever the
# folder names.
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
#
# Those three are why the database is backed up (Backup, below): Navidrome
# writes a consistent copy of it every night, and the media backup takes the
# copies offsite. To restore one: stop navidrome, copy the chosen
# backups/navidrome_backup_<date>.db over /var/lib/navidrome/navidrome.db
# (owner navidrome, and delete navidrome.db-wal and -shm beside it), start
# navidrome. That is the whole database as of that night.
#
# Playlists are managed from a shell, and by an agent, with media-playlist
# (pkgs/media-playlist, the media-playlist skill), a client like the others.

{ ... }:

let
  backups = "/var/lib/navidrome/backups";
in
{
  services.navidrome = {
    enable = true;
    settings = {
      MusicFolder = "/srv/media/music";
      Address = "0.0.0.0";
      Port = 4533;
      # Albums as beets filed them, with nothing to set: Navidrome's default
      # PID.Album keys an album on its MusicBrainz album id first, which
      # groups the discs of a set and keeps two releases of one title apart.
      # (Scanner.GroupAlbumReleases, once set here, is deprecated and did
      # nothing. Setting PID.Album to anything but the default re-keys every
      # album at the next scan, which can orphan album favourites and play
      # counts.)

      # New imports appear without a manual rescan; the file watcher is the
      # default, this is the backstop.
      Scanner.Schedule = "@every 6h";
      # A copy of the database each night, the last two weeks kept. Inside
      # the state directory: the unit's sandbox lets Navidrome write nowhere
      # else. Before midnight, so restic's daily run takes the new one.
      Backup = {
        Path = backups;
        Schedule = "30 22 * * *";
        Count = 14;
      };
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

  # Offsite with the media backup, as /srv/git is (hosts/desk/git.nix says
  # why not a repository of its own). The copies, not the live database:
  # restic reading a SQLite file mid-write can save a torn one.
  services.restic.backups.media.paths = [ backups ];

  # beets creates it on the first import; the server should not wait for one.
  systemd.tmpfiles.rules = [
    # Navidrome makes it at its first backup; restic, which fails on a path
    # that is missing, may run before that.
    "d ${backups} 0700 navidrome navidrome -"
    # 0775, not 0755: the group bits are the media group's ACL mask
    # (hosts/desk/media-group.nix), and `d` reapplies the mode on every
    # switch, so 0755 took the group's write away. Only the ACL's media
    # entry gains it; the owning group's own entry stays r-x.
    "d /srv/media/music 0775 n8 users -"
  ];
}
