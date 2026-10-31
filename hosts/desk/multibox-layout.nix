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
# WoW 1, the main window, is the focused WoW (or else the one focused last):
# focus the one to play from and press the key, and it moves to the left.
# Chrome is the Chrome window focused last. Run it again to swap the WoWs or
# after one restarts; it starts from whatever is there.
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

      # One read, before any action: niri answers queries at once but may
      # apply an action a moment later, so a read between actions can see
      # the layout from before them.
      windows=$(niri msg --json windows)
      # The focused WoW first, then by when they were focused: a window's
      # focus_timestamp is only set once it has kept the focus a moment, so
      # a WoW clicked just before the key can still look like the older one.
      mapfile -t wows < <(jq -r '
        [.[] | select(.title == "World of Warcraft")]
        | sort_by(if .is_focused then 0 else 1 end,
                  -(.focus_timestamp.secs // 0), -(.focus_timestamp.nanos // 0))
        | .[].id' <<<"$windows")
      chrome=$(jq -r '
        [.[] | select(.app_id == "google-chrome")]
        | sort_by(if .is_focused then 0 else 1 end,
                  -(.focus_timestamp.secs // 0), -(.focus_timestamp.nanos // 0))
        | first(.[].id) // empty' <<<"$windows")

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

      ws_id=$(niri msg --json workspaces | jq --arg n "$ws" 'first(.[] | select(.name == $n)).id')

      # niri can run an action after the next one's reply, so each focus is
      # waited for before acting on the focused column, and the result is
      # read back and the whole thing run again if it came out wrong.
      focus() {
        act focus-window --id "$1"
        for _ in $(seq 20); do
          [ "$(niri msg --json focused-window | jq '.id')" = "$1" ] && return
          sleep 0.05
        done
      }

      arrange() {
        local id
        # Each to the workspace, alone in a column of its own. Expelling a
        # window already alone in its column does nothing.
        for id in "$main" $second $chrome; do
          if [ "$(niri msg --json windows | jq --argjson i "$id" 'first(.[] | select(.id == $i)).workspace_id')" != "$ws_id" ]; then
            act move-window-to-workspace --window-id "$id" --focus false "$ws"
          fi
          focus "$id"
          act expel-window-from-column
        done

        focus "$main"
        act move-column-to-index 1
        act set-column-width "66.667%"
        # A height set on a window stays with it, also into this column.
        act reset-window-height --id "$main"

        if [ -n "$right" ]; then
          focus "$right"
          act move-column-to-index 2
          act set-column-width "33.333%"
          act reset-window-height --id "$right"
        fi
        if [ -n "$second" ] && [ -n "$chrome" ]; then
          focus "$chrome"
          act move-column-to-index 3
          act consume-or-expel-window-left --id "$chrome"
          act reset-window-height --id "$chrome"
        fi

        focus "$main"
      }

      # Column and row of each, as "col,row" — "1,1 2,1 2,2" is the layout —
      # and the two in the right column within a few pixels of one height.
      arranged() {
        local want="1,1"
        [ -n "$right" ] && want="$want 2,1"
        [ -n "$second" ] && [ -n "$chrome" ] && want="$want 2,2"
        sleep 0.5
        niri msg --json windows | jq -e --arg want "$want" \
          --argjson ids "[$main''${right:+,$right}''${second:+''${chrome:+,$chrome}}]" '
          [$ids[] as $i | first(.[] | select(.id == $i))] as $w
          | ([$w[].layout.pos_in_scrolling_layout | map(tostring) | join(",")] | join(" ")) == $want
            and ($w | length < 3 or (($w[1].layout.tile_size[1] - $w[2].layout.tile_size[1]) | fabs) <= 4)' \
          >/dev/null
      }

      right=''${second:-$chrome}
      for _ in 1 2 3; do
        arrange
        arranged && exit 0
      done
      echo "multibox-layout: the windows did not end up in place" >&2
      exit 1
    '';
  };
in
{
  environment.systemPackages = [ multiboxLayout ];
}
