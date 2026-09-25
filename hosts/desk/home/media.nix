# Filing media into /srv/media — docs/desktop-migration.md, "Layout on the
# share". media-stage moves everything but music; beets owns music/, because
# music is best named from its tags (and from MusicBrainz), not its file names.
#
# beets' library database is state, not config: it lives under XDG data and
# can be rebuilt from the tags with `beet import -A -C /srv/media/music`
# (as-is, no copy/move), since `write` puts everything it knows in the files.

{ ... }:

{
  # media-stage, and the Claude Code guidance that makes an agent use it.
  imports = [ ../../../modules/home/media-share.nix ];

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
      # chroma: AcoustID fingerprints, for files with no usable tags.
      # duplicates, info: the checks before and after an import.
      plugins = [ "chroma" "duplicates" "info" "inline" ];
    };
  };
}
