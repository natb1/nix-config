# Filing media into /srv/media — docs/desktop-migration.md, "Layout on the
# share". media-stage moves everything but music; beets owns music/, because
# music is best named from its tags (and from MusicBrainz), not its file names.
#
# beets' library database is state, not config: it lives under XDG data and
# can be rebuilt from the tags with `beet import -A -C /srv/media/music`
# (as-is, no copy/move), since `write` puts everything it knows in the files.

{ pkgs, ... }:

{
  # media-stage, and the Claude Code guidance that makes an agent use it.
  imports = [ ../../../modules/home/media-share.nix ];

  # The music player: a client of desk's own Navidrome (hosts/desk/music.nix),
  # so desk and the phone share favourites, playlists and play counts. First
  # run: server http://localhost:4533, the Navidrome account.
  # The video player: Jellyfin Desktop, a client of desk's own Jellyfin
  # (hosts/desk/jellyfin.nix) that plays through mpv, so files direct-play
  # instead of transcoding. First run: server http://localhost:8096.
  home.packages = [ pkgs.feishin pkgs.jellyfin-desktop ]
    # Searching and downloading, through desk's slskd (hosts/desk/soulseek.nix).
    # Here, not in media-share.nix: only desk has a backend to call; the Mac
    # runs it as `ssh desk media-fetch …`.
    ++ [ (pkgs.callPackage ../../../pkgs/media-fetch { }) ];

  programs.beets = {
    enable = true;
    settings = {
      directory = "/srv/media/music";
      library = "~/.local/share/beets/library.db";
      # Staging is emptied by the import, as media-stage apply does for the rest.
      import = {
        move = true;
        write = true;
        log = "~/.local/share/beets/import.log";
      };
      # music/<album artist>/<album> (<year>)/<disc>-<track> <title>, the disc
      # only on multi-disc releases. beets' default `replace` rules already
      # keep names SMB-safe for the Windows clients.
      # Compilations too (album artist "Various Artists"), instead of beets'
      # default top-level Compilations/.
      paths = rec {
        default = "$albumartist/$album%aunique{}%if{$year, ($year)}/%if{$multidisc,$disc-}$track $title";
        comp = default;
      };
      item_fields.multidisc = "1 if disctotal > 1 else 0";
      # musicbrainz: the metadata source. A plugin like any other since beets
      # 2.x — without it in this list, nothing is ever matched.
      # chroma: AcoustID fingerprints, for files with no usable tags.
      # duplicates, info: the checks before and after an import.
      # stagereview: `beet stage-review`, the import without prompts that
      # media-stage batches use, and `beet stage-audit`, its check afterwards
      # (pkgs/media-stage/beetsplug/stagereview.py). Its duplicate check runs
      # chroma's fpcalc, and keeps each library track's fingerprint in the
      # beets field `stage_fp`.
      plugins = [ "musicbrainz" "chroma" "duplicates" "info" "inline" "stagereview" ];
      pluginpath = [ "${../../../pkgs/media-stage/beetsplug}" ];
      # beets counts chroma as a second metadata source and so charges every
      # MusicBrainz match a "data_source" penalty: a perfect match scored 88%,
      # never "strong", and every album went to the review page. MusicBrainz
      # is the only source of releases here, so nothing is to be weighed.
      musicbrainz.data_source_mismatch_penalty = 0.0;
    };
  };

  # beets asks before creating its library's directory, and a prompt is
  # fatal to `beet stage-review`, which runs without a terminal.
  xdg.dataFile."beets/.keep".text = "";
}
