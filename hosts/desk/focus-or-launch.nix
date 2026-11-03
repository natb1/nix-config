# App keys: Mod+1, Mod+2, … in niri (hosts/desk/home/niri.kdl) each call
# `focus-or-launch COLUMN APP_ID CMD…`. If a window with that Wayland app_id is
# open, anywhere, it is focused — niri scrolls or switches workspace to it,
# like alt-tab. If not, CMD is started and its window, once it appears, is
# moved to column COLUMN (1 is leftmost) of the current workspace. Its width
# comes from niri.kdl (the default column width, or a window rule), not from
# here, so it holds for the window however it was opened.
#
# The exception is a window on the "multibox" workspace (multibox-layout.nix,
# Mod+Shift+M): it is brought home, to column COLUMN of the first workspace
# at the default quarter width, and focused there. Of several windows with
# the app_id, that one is the one taken.
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
      column=$1
      app_id=$2
      shift 2

      multibox=$(niri msg --json workspaces |
        jq 'first(.[] | select(.name == "multibox") | .id) // null')

      window_id() {
        niri msg --json windows |
          jq -r --arg a "$app_id" --argjson m "$multibox" '
            [.[] | select(.app_id == $a)] | sort_by(.workspace_id != $m)
            | first(.[].id) // empty'
      }

      # niri can apply an action after replying to it, so wait for the focus
      # before acting on the focused column.
      focus() {
        niri msg action focus-window --id "$1"
        for _ in $(seq 20); do
          [ "$(niri msg --json focused-window | jq '.id')" = "$1" ] && return
          sleep 0.05
        done
      }

      id=$(window_id)
      if [ -n "$id" ]; then
        on=$(niri msg --json windows | jq --argjson i "$id" 'first(.[] | select(.id == $i)).workspace_id')
        if [ "$on" != "$multibox" ]; then
          exec niri msg action focus-window --id "$id"
        fi
        niri msg action move-window-to-workspace --window-id "$id" --focus false 1
        focus "$id"
        niri msg action move-column-to-index "$column"
        exec niri msg action set-column-width "25%"
      fi

      setsid -f "$@" >/dev/null 2>&1

      # Chrome takes a second or two when it is not already running.
      for _ in $(seq 100); do
        sleep 0.1
        id=$(window_id)
        [ -n "$id" ] || continue
        niri msg action focus-window --id "$id"
        exec niri msg action move-column-to-index "$column"
      done
    '';
  };
in
{
  environment.systemPackages = [ focusOrLaunch ];
}
