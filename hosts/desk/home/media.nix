# n8's media on desk: the players, and the filing tools every member of the
# media group gets (./media-tools.nix).

{ pkgs, ... }:

{
  imports = [ ./media-tools.nix ];

  # The music player: a client of desk's own Navidrome (hosts/desk/music.nix),
  # so desk and the phone share favourites, playlists and play counts. First
  # run: server http://localhost:4533, the Navidrome account.
  # The video player: Jellyfin Desktop, a client of desk's own Jellyfin
  # (hosts/desk/jellyfin.nix) that plays through mpv, so files direct-play
  # instead of transcoding. First run: server http://localhost:8096.
  home.packages = [ pkgs.feishin pkgs.jellyfin-desktop ];
}
