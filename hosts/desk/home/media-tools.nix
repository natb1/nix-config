# The filing tools on desk, for every member of the media group
# (hosts/desk/media-group.nix): n8 (./media.nix) and drlindsey
# (hosts/desk/drlindsey.nix). Each runs them as themself, on the same shared
# state — media-fetch's jobs, beets' library — so an agent works the same
# whichever account it runs in.
#
# Filing media into /srv/media — docs/desktop-migration.md, "Layout on the
# share". media-stage moves everything but music; beets owns music/, because
# music is best named from its tags (and from MusicBrainz), not its file names.
#
# beets' library database is state, not config: it lives in /var/lib/beets
# (one library, whoever imports) and can be rebuilt from the tags with
# `beet import -A -C /srv/media/music` (as-is, no copy/move), since `write`
# puts everything it knows in the files. The directory is made by tmpfiles:
# beets asks before creating it, and a prompt is fatal to `beet
# stage-review`, which runs without a terminal.

{ pkgs, ... }:

{
  # media-stage, and the Claude Code guidance that makes an agent use it.
  imports = [ ../../../modules/home/media-share.nix ];

  # Searching and downloading, through desk's slskd (hosts/desk/soulseek.nix).
  # Here, not in media-share.nix: only desk has a backend to call; the Mac
  # runs it as `ssh desk media-fetch …`.
  home.packages = [
    (pkgs.callPackage ../../../pkgs/media-fetch { stateDir = "/var/lib/media-fetch"; })
  ];

  programs.beets = {
    enable = true;
    settings = {
      directory = "/srv/media/music";
      library = "/var/lib/beets/library.db";
      # Staging is emptied by the import, as media-stage apply does for the rest.
      import = {
        move = true;
        write = true;
        log = "/var/lib/beets/import.log";
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
    };
  };
}
