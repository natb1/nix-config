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
#   - a media-fetch skill (also /media-fetch) for finding and downloading
#     media, which hands its batch to the first. media-fetch itself is only
#     on desk (hosts/desk/home/media.nix); the Mac runs it over ssh;
#   - a line in the user-level CLAUDE.md, always loaded, naming the skill.
# Those are in media-skills.nix. Neither is a guarantee — the read-only
# `media` share on desk is (hosts/desk/media.nix). These make the right way the first thing tried.

{ pkgs, ... }:

{
  imports = [ ./media-skills.nix ];

  home.packages = [ (pkgs.callPackage ../../pkgs/media-stage { }) ];
}
