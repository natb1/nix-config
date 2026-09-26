# Filing into desk's media share, for the hosts that use it: desk itself
# (hosts/desk/home/media.nix) and the Mac (hosts/mba/desk.nix). Not in
# modules/home/default.nix — the WSL box has no share to file into.
#
# media-stage is the tool (docs/desktop-migration.md, "Filing a batch"). The
# rest is so that Claude Code, started fresh on either host and asked to "put
# these videos on the media share", uses it rather than copying files into
# the library:
#   - a skill, loaded when a request matches its description, whatever
#     directory the session started in, holding the procedure;
#   - a line in the user-level CLAUDE.md, always loaded, naming the skill.
# Neither is a guarantee — the read-only `media` share on desk is
# (hosts/desk/media.nix). These make the right way the first thing tried.

{ pkgs, ... }:

{
  home.packages = [ (pkgs.callPackage ../../pkgs/media-stage { }) ];

  home.file.".claude/skills/media-share/SKILL.md".source = ./media-share/SKILL.md;

  # `text` is `lines`, so another module can add to this file.
  home.file.".claude/CLAUDE.md".text = ''
    - Files going onto desk's media share (`/Volumes/media`,
      `/Volumes/media-staging`, `smb://desk/…`, `/srv/media`) go through
      `media-stage` — follow the `media-share` skill. Never cp, mv or rsync
      straight into the library (`music/ books/ rpg/ movies/ tv/ youtube/`).
  '';
}
