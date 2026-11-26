# Sunshine: desk streams its own screen, WoW and all, to Moonlight on another
# device, in place of GeForce Now (2026-11-26). The game runs here, on the
# RX 6600 XT, under the Battle.net of gaming.nix, with the same install,
# addons and multibox layout as at the desk; the client only shows the
# picture and sends back keyboard, mouse and controller.
#
# Tailnet-only, like everything desk serves: tailscale0 is trusted
# (modules/nixos/tailscale.nix), so openFirewall stays off and nothing on the
# Wi-Fi reaches the ports (47984-48010). Away from home, Moonlight connects
# to `desk` through Tailscale; T-Mobile's carrier-grade NAT leaves no port to
# forward anyway.
#
# Capture is niri's wlr-screencopy, as the session user: no cap_sys_admin
# wrapper, which KMS capture would need. niri renders on the iGPU and the
# monitor hangs off the iGPU's HDMI-A-2 (docs/desktop-migration.md), so the
# frame is already on the iGPU, and the iGPU's VCN encodes it there: no copy
# across PCIe, and the dGPU's time stays the game's. By path, not
# renderD129: the render nodes' numbers follow probe order (the dGPU is
# renderD128 today). Tried by hand on 2026-11-26, Sunshine as n8 in the
# running session: it found HDMI-A-2 at 3440x1440 and h264_vaapi and
# hevc_vaapi on the iGPU; av1_vaapi has no entrypoint there, so no AV1.
#
# What Moonlight gets is the monitor's own mode, 3440x1440: there is no
# virtual display, so a 16:10 client shows it letterboxed. Ask Moonlight for
# 3440x1440 (or 2560x1080 to save bandwidth) rather than the client's size.
#
# niri draws nothing while its monitors are off, so swayidle's
# power-off-monitors (home/desktop.nix) would leave a black stream: each app
# below powers them back on as a stream starts. Moonlight's input arrives
# through uinput, which niri should count as activity (not yet seen in a
# stream). A monitor unplugged, or switched off
# hard enough to drop hot-plug, leaves niri no output to capture at all.
#
# Set by hand once (README, "desk (once, after its first switch)"): the web
# UI's login and pairing each client, both kept in ~/.config/sunshine.

{ lib, pkgs, ... }:

let
  niri = lib.getExe pkgs.niri;
  # The module clears PATH for the tray's sake, so commands are absolute.
  wakeMonitors = {
    do = "${niri} msg action power-on-monitors";
    undo = "";
  };
in
{
  services.sunshine = {
    enable = true;
    autoStart = true;
    capSysAdmin = false;
    openFirewall = false;
    settings = {
      sunshine_name = "desk";
      capture = "wlr";
      encoder = "vaapi";
      adapter_name = "/dev/dri/by-path/pci-0000:12:00.0-render";
    };
    applications.apps = [
      {
        name = "Desktop";
        prep-cmd = [ wakeMonitors ];
      }
      # Every account's Battle.net, stacked as Mod+D's entry does
      # (gaming.nix); an account already running is left as it is. Ending
      # the stream leaves them running.
      {
        name = "Battle.net";
        prep-cmd = [ wakeMonitors ];
        detached = [ "/run/current-system/sw/bin/battlenet-all" ];
      }
    ];
  };
}
