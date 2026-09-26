# drlindsey — a second user on desk whose only job is running their own
# `claude rc` (modules/home/claude-remote-control.nix), signed in to their own
# Claude account, in their own repo at ~/work.
#
# Deliberately not given n8's home config (modules/home): that carries n8's git
# identity and n8's SSH authorized_keys. Not in wheel, no password: nobody logs
# in as drlindsey directly. n8 reaches the account with
#
#   sudo machinectl shell drlindsey@
#
# and the one-time setup there is `cd ~/work && claude` — sign in with /login
# and accept the workspace trust dialog. Until then the rc service exits with an
# error and retries every 10 s.
#
# linger: the rc service is a systemd user unit, and without linger drlindsey's
# user manager — and so the service — only runs while drlindsey is logged in.

{ pkgs, ... }:

let
  user = "drlindsey";
in
{
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
      ];

      services.claudeRemoteControl.directory = "${config.home.homeDirectory}/work";

      home.packages = [ pkgs.git ];

      # The system default shell is zsh; without a managed .zshrc the first
      # shell stops at zsh-newuser-install.
      programs.zsh.enable = true;

      # rc's worktree mode needs a git repo with a commit to branch from, so
      # make one on first activation. Left alone once it exists.
      home.activation.claudeRemoteControlRepo = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        repo="${config.services.claudeRemoteControl.directory}"
        if [ ! -e "$repo/.git" ]; then
          $DRY_RUN_CMD ${pkgs.git}/bin/git init -q "$repo"
          $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$repo" \
            -c user.name=${user} -c user.email=${user}@desk \
            commit -q --allow-empty -m "Initial commit"
        fi
      '';

      home.stateVersion = "24.11";
    };
}
