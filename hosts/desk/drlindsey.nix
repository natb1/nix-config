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
# whole procedure, search to filing. The tools run as n8, through sudo: the
# slskd API key, the media-fetch jobs the pump service serves
# (hosts/desk/soulseek.nix) and /srv/media are all n8's. `media-fetch`,
# `media-stage` and `beet` in drlindsey's PATH are wrappers for
# `sudo -u n8 -H <n8's copy>`, so the skills' commands work unchanged, on
# n8's state and beets config. The sudo rule takes any arguments, and beet
# takes --config and plugin paths — so this is, in effect, drlindsey running
# code as n8. Chosen knowingly; narrow it with a wrapper that checks the
# arguments if that stops being acceptable. Use absolute /srv/media paths:
# n8 cannot read drlindsey's home, so relative paths from there fail.
#
# Two places the media-share skill assumes n8 (their CLAUDE.md lines below
# override them): the Media Filing Review page is n8's artifact, which
# drlindsey's Claude account can't list, so they have their own; and
# /srv/media/staging is n8's and not writable for drlindsey, so the page's
# answers are saved to answersDir instead — drlindsey's, readable by n8.
#
# linger: the rc service is a systemd user unit, and without linger drlindsey's
# user manager — and so the service — only runs while drlindsey is logged in.

{ pkgs, ... }:

let
  user = "drlindsey";

  # n8's own copies, by their stable profile path, so the sudo rule survives
  # rebuilds.
  n8Bin = "/etc/profiles/per-user/n8/bin";
  mediaTools = [ "media-fetch" "media-stage" "beet" ];

  answersDir = "/var/lib/media-answers";
  reviewPage = "https://claude.ai/artifact/D4LiLNMwES1pCW8iHebEqC";
in
{
  security.sudo.extraRules = [
    {
      users = [ user ];
      runAs = "n8";
      commands = map (tool: {
        command = "${n8Bin}/${tool}";
        options = [ "NOPASSWD" ];
      }) mediaTools;
    }
  ];

  systemd.tmpfiles.rules = [ "d ${answersDir} 0755 ${user} users -" ];

  users.users.${user} = {
    isNormalUser = true;
    home = "/home/${user}";
    linger = true;
  };

  home-manager.users.${user} =
    { config, lib, ... }:
    {
      imports = [
        ../../modules/home/claude-code.nix
        ../../modules/home/claude-remote-control.nix
        ../../modules/home/gh.nix
        ../../modules/home/media-skills.nix
      ];

      home.packages = [
        pkgs.jq
        pkgs.python3
      ]
      ++ map (
        tool: pkgs.writeShellScriptBin tool ''
          exec /run/wrappers/bin/sudo -u n8 -H ${n8Bin}/${tool} "$@"
        ''
      ) mediaTools;

      home.file.".claude/CLAUDE.md".text = ''
        - Media Filing Review page (media-share step 6): ${reviewPage}
          — yours; the shared one isn't visible to this account.
        - media-share answers (step 7): staging isn't writable for you, so
          save them to `${answersDir}/<batch>.answers` instead.
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
