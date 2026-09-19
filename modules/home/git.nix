# Git Configuration Module
#
# Shared across every host. The identity is set here rather than per-host: it is
# the same on the WSL box, the Mac, and any future machine, so there is exactly
# one place to change it.

{ ... }:

{
  programs.git = {
    enable = true;

    settings = {
      user = {
        name = "Nathan Buesgens";
        email = "nathan@natb1.com";
      };

      # Core settings
      pull = {
        rebase = true;
      };

      init = {
        defaultBranch = "main";
      };

      # Common aliases
      alias = {
        st = "status";
        co = "checkout";
        br = "branch";
        ci = "commit";
        unstage = "reset HEAD --";
        last = "log -1 HEAD";
        visual = "log --graph --oneline --all";
      };
    };
  };
}
