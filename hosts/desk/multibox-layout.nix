# Mod+Shift+M in niri (hosts/desk/home/niri.kdl) runs `multibox-layout`: it
# moves both WoW windows and a Chrome window to the "multibox" workspace and
# lays them out for multiboxing (gaming.nix) —
#
#     +----------------------+----------+
#     |                      |  WoW 2   |
#     |        WoW 1         +----------+
#     |                      |  Chrome  |
#     +----------------------+----------+
#              2/3               1/3
#
# WoW 1, the main window, is the WoW focused last: focus the one to play from
# and press the key. Chrome is the Chrome window focused last. Run it again
# to swap the WoWs or after one restarts; it starts from whatever is there.
#
# The WoWs are told apart from Battle.net by title alone: under umu every
# window of both Battle.nets and both games has the app_id
# steam_app_battlenet, and xwayland-satellite gives them all its own pid.

{ pkgs, ... }:

let
  multiboxLayout = pkgs.writeShellApplication {
    name = "multibox-layout";
    runtimeInputs = [ pkgs.niri pkgs.jq ];
    text = ''
      ws=multibox

      # Most recently focused first.
      by_title() {
        niri msg --json windows | jq -r --arg t "$1" '
          [.[] | select(.title | test($t))]
          | sort_by(-(.focus_timestamp.secs // 0), -(.focus_timestamp.nanos // 0))
          | .[].id'
      }
      mapfile -t wows < <(by_title '^World of Warcraft$')
      chrome=$(niri msg --json windows | jq -r '
        [.[] | select(.app_id == "google-chrome")]
        | sort_by(-(.focus_timestamp.secs // 0), -(.focus_timestamp.nanos // 0))
        | first(.[].id) // empty')

      if [ "''${#wows[@]}" -eq 0 ]; then
        echo "multibox-layout: no World of Warcraft window" >&2
        exit 1
      fi
      main=''${wows[0]}
      second=''${wows[1]:-}
      act() { niri msg action "$@"; }

      # Named at run time, not declared in niri.kdl: a declared workspace goes
      # first and would push Mod+Alt+1 and the rest along. The first time, it
      # is the empty workspace niri keeps at the end of the focused output.
      if ! niri msg --json workspaces | jq -e --arg n "$ws" 'any(.[]; .name == $n)' >/dev/null; then
        last=$(niri msg --json workspaces | jq -r '
          (first(.[] | select(.is_focused)).output) as $o
          | [.[] | select(.output == $o) | .idx] | max')
        act set-workspace-name --workspace "$last" "$ws"
      fi

      # Each to the workspace, alone in a column of its own.
      for id in "$main" $second $chrome; do
        act move-window-to-workspace --window-id "$id" --focus false "$ws"
        act focus-window --id "$id"
        col=$(niri msg --json windows | jq --argjson id "$id" '
          (.[] | select(.id == $id)) as $w
          | [.[] | select(.workspace_id == $w.workspace_id and .is_floating == false
                          and .layout.pos_in_scrolling_layout[0] == $w.layout.pos_in_scrolling_layout[0])]
          | length')
        if [ "$col" -gt 1 ]; then act expel-window-from-column; fi
      done

      act focus-window --id "$main"
      act move-column-to-index 1
      act set-column-width "66.667%"

      right=''${second:-$chrome}
      if [ -n "$right" ]; then
        act focus-window --id "$right"
        act move-column-to-index 2
        act set-column-width "33.333%"
        act reset-window-height --id "$right"
      fi
      if [ -n "$second" ] && [ -n "$chrome" ]; then
        act focus-window --id "$chrome"
        act move-column-to-index 3
        act consume-or-expel-window-left --id "$chrome"
        act reset-window-height --id "$chrome"
      fi

      act focus-window --id "$main"
    '';
  };
in
{
  environment.systemPackages = [ multiboxLayout ];
}
