# Zellij in a browser: desk's terminal sessions at https://desk.<tailnet>.ts.net
#
# `zellij web` serves sessions to a browser, one per path: /main is the
# session `main`, the same one `ssh desk-term` attaches to
# (modules/home/zellij.nix), created if there is none and brought back if it
# was written to disk before a reboot. Both views of a session are live.
#
# zellij listens on loopback only, in plain HTTP: it wants a certificate for
# any other address. `tailscale serve` puts it on the tailnet on 443 and
# terminates TLS with the tailnet's certificate for desk, so nothing here
# makes or renews one. Never `tailscale funnel` it: it is a shell as n8, and
# zellij does not rate-limit logins.
#
# Logging in takes a token, made on desk and shown only once:
#   zellij web --create-token          (prints token_<n>: <token>)
#   zellij web --list-tokens / --revoke-token token_<n> / --revoke-all-tokens
# Tokens are state, kept hashed in ~/.local/share/zellij/tokens.db; nothing in
# this repo. "Remember me" at login keeps the browser logged in for four
# weeks. Every tailnet device reaches the login page, including the phones of
# other tailnet users; the token is what keeps them out.
#
# Prerequisite, once per tailnet: HTTPS certificates on, in the Tailscale
# admin console (DNS → HTTPS Certificates; MagicDNS must be on too). Until
# then zellij-web-serve fails and the switch reports it. Turning them on
# publishes desk.<tailnet>.ts.net in the public Certificate Transparency logs.

{ config, pkgs, ... }:

let
  port = 8082;
in
{
  home-manager.users.n8 = { config, ... }: {
    # Off by default: without it the server runs and logs in, and then
    # refuses to show any session.
    programs.zellij.settings.web_sharing = "on";

    systemd.user.services.zellij-web = {
      Unit.Description = "Zellij web server, on loopback for tailscale serve";
      Service = {
        # Foreground unless -d is given.
        ExecStart = "${config.programs.zellij.package}/bin/zellij web --start --ip 127.0.0.1 --port ${toString port}";
        Restart = "on-failure";
        # Sessions opened from the browser are this unit's children. With the
        # default KillMode=control-group, a switch that restarted the unit (any
        # zellij bump) would kill them and every pane in them. This stops only
        # the web server; the sessions keep running for the next one.
        KillMode = "process";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };

  # The NixOS tailscale module has no option for serve. The mapping is kept by
  # tailscaled, so this only asserts it on boot and switch, and removes it
  # when the unit stops (so dropping this module unpublishes zellij).
  systemd.services.zellij-web-serve = {
    description = "Serve desk's zellij web server on the tailnet";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.services.tailscale.package}/bin/tailscale serve --bg --https=443 http://127.0.0.1:${toString port}";
      ExecStop = "${config.services.tailscale.package}/bin/tailscale serve --https=443 off";
      # At boot tailscaled may not be logged in yet.
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStartSec = 60;
    };
  };
}
