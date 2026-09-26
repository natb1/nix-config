# The Claude Code guidance for desk's media share: the media-share and
# media-fetch skills and the CLAUDE.md lines naming them. Split from
# media-share.nix so a user who runs the tools some other way — drlindsey,
# through sudo as n8 (hosts/desk/drlindsey.nix) — gets the same guidance
# without the tools.

{ ... }:

{
  home.file.".claude/skills/media-share/SKILL.md".source = ./media-share/SKILL.md;
  home.file.".claude/skills/media-fetch/SKILL.md".source = ./media-fetch/SKILL.md;

  # `text` is `lines`, so another module can add to this file.
  home.file.".claude/CLAUDE.md".text = ''
    - Files going onto desk's media share (`/Volumes/media`,
      `/Volumes/media-staging`, `smb://desk/…`, `/srv/media`) go through
      `media-stage` — follow the `media-share` skill. Never cp, mv or rsync
      straight into the library (`music/ books/ rpg/ movies/ tv/ youtube/`).
    - Finding or downloading media (an album, books, …): follow the
      `media-fetch` skill.
  '';
}
