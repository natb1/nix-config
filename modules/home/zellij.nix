# Zellij, the terminal multiplexer, on every host.
#
# The session lives on the machine it runs on and outlasts the connection: from
# the Mac, `ssh desk-term` (modules/home/ssh.nix) attaches to desk's `main`
# session, creating it the first time. Detach with Ctrl+o d; the panes keep
# running.
#
# Nothing here starts a session. A systemd unit that created one would own it:
# units stop with KillMode=control-group, so a switch that restarted the unit
# would kill the zellij server and every pane in it. A session created from an
# ssh login sits in that login's scope, which logind leaves alone when the
# connection closes.

{ ... }:

{
  programs.zellij = {
    enable = true;

    # Off, and tests hold them off (flake.nix, zellij-config): the integration
    # starts zellij in every interactive shell with a terminal, which would
    # include each ssh login and the panes of zellij itself on another host.
    enableZshIntegration = false;
    enableBashIntegration = false;
    enableFishIntegration = false;

    settings = {
      show_startup_tips = false;

      # Sessions are written to disk by default, so `zellij attach` offers
      # them again after a reboot. This adds what each pane showed.
      serialize_pane_viewport = true;
      scrollback_lines_to_serialize = 10000;
    };
  };
}
