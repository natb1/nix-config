# Jellyfin: /srv/media as a video server, and a second way to its music.
#
# Navidrome (hosts/desk/music.nix) stays the music server: the Subsonic API
# is what Amperfy on the phone speaks, and Navidrome reads beets' tags more
# faithfully. Jellyfin adds what Navidrome cannot do, movies, TV and YouTube,
# and reads music/ too so one app can play both. The two keep separate
# favourites, playlists and play counts; Navidrome's are the ones the phone
# sees.
#
# Libraries, as the first-run wizard at http://desk:8096 sets them up (they
# are Jellyfin's database, not this file):
#   Movies        /srv/media/movies
#   Shows         /srv/media/tv
#   Home Videos   /srv/media/youtube   (no metadata lookups to get wrong)
#   Music         /srv/media/music
# The layout (docs/desktop-migration.md, "Layout on the share") is the
# naming Jellyfin parses without per-file hints. Jellyfin cannot write to the
# library (n8's, 0755), which is right: artwork and metadata stay in its own
# state, never beside the files beets and media-stage own.
#
# Tailnet-only, like Navidrome: the firewall opens nothing for it, and
# tailscale0 is trusted (modules/nixos/tailscale.nix). openFirewall would
# open 8096 and the discovery ports on Wi-Fi too.
#
# Not managed by this repo: Jellyfin's accounts and libraries. The first
# visit to http://desk:8096 creates the admin and the libraries above. State
# is in /var/lib/jellyfin (accounts, libraries, watched state) and
# /var/cache/jellyfin (images and transcodes, disposable).

{ ... }:

{
  services.jellyfin = {
    enable = true;

    # Transcoding on the iGPU (12:00.0), not the dGPU: the iGPU is the host's
    # always (docs/desktop-migration.md, "GPU topology"), while the dGPU goes
    # to the Windows guest. By PCI address, because renderD128/129 is not a
    # stable name (Phase 0 found them the reverse of the guess). Raphael's
    # VCN decodes H.264, HEVC (10-bit too), VP9 and AV1, and encodes H.264
    # and HEVC.
    hardwareAcceleration = {
      enable = true;
      type = "vaapi";
      device = "/dev/dri/by-path/pci-0000:12:00.0-render";
    };
    transcoding = {
      hardwareDecodingCodecs = {
        h264 = true;
        hevc = true;
        hevc10bit = true;
        vp9 = true;
        av1 = true;
      };
      hardwareEncodingCodecs.hevc = true;
    };
    # This file, not the dashboard, decides the transcoding settings; a
    # dashboard change is backed up and replaced on the next start.
    forceEncodingConfig = true;
  };

  # The same footgun as Samba and Navidrome: without the bulk SSD, Jellyfin
  # would scan an empty /srv/media and drop the whole library, watched state
  # with it.
  systemd.services.jellyfin = {
    after = [ "srv-media.mount" ];
    requires = [ "srv-media.mount" ];
  };

  # media-stage creates them on the first video batch; the libraries should
  # not wait for one.
  systemd.tmpfiles.rules = [
    "d /srv/media/movies 0755 n8 users -"
    "d /srv/media/tv 0755 n8 users -"
    "d /srv/media/youtube 0755 n8 users -"
  ];
}
