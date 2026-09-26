# App keys: Mod+1, Mod+2, … in niri (hosts/desk/home/niri.kdl) each call
# `focus-or-launch APP_ID CMD…`. If a window with that Wayland app_id is open,
# anywhere, it is focused — niri scrolls or switches workspace to it, like
# alt-tab. If not, CMD is started and its window, once it appears, is moved to
# the leftmost column of the current workspace. Its width is a window rule in
# niri.kdl, not set here, so it holds for the window however it was opened.
#
# Web apps need no "Install page as app": `google-chrome-stable --app=URL`
# opens a bare app window with an app_id derived from the URL —
# https://claude.ai/artifact/X gives chrome-claude.ai__artifact_X-Default
# (checked 2026-09-26, Chrome on native Wayland).

{ pkgs, ... }:

let
  focusOrLaunch = pkgs.writeShellApplication {
    name = "focus-or-launch";
    runtimeInputs = [ pkgs.niri pkgs.jq pkgs.coreutils ];
    text = ''
      app_id=$1
      shift

      window_id() {
        niri msg --json windows |
          jq -r --arg a "$app_id" 'first(.[] | select(.app_id == $a) | .id) // empty'
      }

      id=$(window_id)
      if [ -n "$id" ]; then
        exec niri msg action focus-window --id "$id"
      fi

      setsid -f "$@" >/dev/null 2>&1

      # Chrome takes a second or two when it is not already running.
      for _ in $(seq 100); do
        sleep 0.1
        id=$(window_id)
        [ -n "$id" ] || continue
        niri msg action focus-window --id "$id"
        exec niri msg action move-column-to-first
      done
    '';
  };
in
{
  environment.systemPackages = [ focusOrLaunch ];
}
