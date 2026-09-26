# drlindsey — a second user on desk whose only job is running their own
# `claude rc` (modules/home/claude-remote-control.nix), signed in to their own
# Claude account, in their own clone of this repo at ~/natb1/nix-config (the
# module's default directory).
#
# Deliberately not given n8's home config (modules/home): that carries n8's git
# identity and n8's SSH authorized_keys. Of it they get only what is generic —
# claude-code, gh, jq and python3. Not in wheel, no password: nobody logs in
# as drlindsey directly. n8 reaches the account with
#
#   sudo machinectl shell drlindsey@
#
# and the one-time setup there is `gh auth login` for their GitHub account, then
# `cd ~/natb1/nix-config && claude` — sign in with /login and accept the
# workspace trust dialog. Until then the rc service exits with an error and
# retries every 10 s.
#
# Media: their agent gets the media-fetch and media-share skills and runs the
# whole procedure, search to filing, as n8's does. They are in the media
# group (hosts/desk/media-group.nix) and get the same tools and beets config
# (home/media-tools.nix), so they run media-fetch, media-stage and beet as
# themself, on the shared state: staging and the library, media-fetch's jobs,
# beets' library, slskd's API key. Nothing of n8's account beyond that.
#
# One place the media-share skill assumes n8 (their CLAUDE.md line below
# overrides it): the Media Filing Review page is n8's artifact, which
# drlindsey's Claude account can't list, so they have their own.
#
# linger: the rc service is a systemd user unit, and without linger drlindsey's
# user manager — and so the service — only runs while drlindsey is logged in.

{ pkgs, ... }:

let
  user = "drlindsey";
  reviewPage = "https://claude.ai/artifact/D4LiLNMwES1pCW8iHebEqC";
in
{
  users.users.${user} = {
    isNormalUser = true;
    home = "/home/${user}";
    linger = true;
    extraGroups = [ "media" ];
  };

  home-manager.users.${user} =
    { config, lib, ... }:
    {
      imports = [
        ../../modules/home/claude-code.nix
        ../../modules/home/claude-remote-control.nix
        ../../modules/home/gh.nix
        ./home/media-tools.nix
      ];

      home.packages = [
        pkgs.jq
        pkgs.python3
      ];

      home.file.".claude/CLAUDE.md".text = ''
        - Media Filing Review page (media-share step 6): ${reviewPage}
          — yours; the shared one isn't visible to this account.
      '';

      # A managed git config, with no identity: gh.nix's credential helper is
      # written into it, so `gh auth login` also covers git over https.
      programs.git.enable = true;

      # The system default shell is zsh; without a managed .zshrc the first
      # shell stops at zsh-newuser-install.
      programs.zsh.enable = true;

      # rc's worktree mode needs a git repo to branch from, so clone this one
      # (public, so no credentials needed) on first activation. Left alone once
      # it exists. A failed clone (no network) only warns; the next activation
      # retries, and until then the rc service retries too.
      home.activation.claudeRemoteControlRepo = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        repo="${config.services.claudeRemoteControl.directory}"
        if [ ! -e "$repo/.git" ]; then
          $DRY_RUN_CMD ${pkgs.git}/bin/git clone -q \
            https://github.com/natb1/nix-config.git "$repo" \
            || echo "warning: could not clone nix-config into $repo" >&2
        fi
      '';

      home.stateVersion = "24.11";
    };
}
