# `pick`: a menu for scripts, in the desk shell's list (Picker.qml, the one
# Mod+D uses). The rebuild and power menus are built on it.
#
#   pick [--prompt TEXT] [--refresh COMMAND] <rows
#
# A row is one line: a key, then the lines to show, all tab-separated. The
# chosen row's key is printed; nothing chosen, it exits 1.
#
# --refresh runs COMMAND (bash -c) once the list is open, with a spinner
# showing, and its output replaces the rows: a menu can open at once from
# what it already knows and fill in behind.
#
# The shell answers on a FIFO. If it can't open the list, pick says so and
# exits 2.

{
  writeShellApplication,
  quickshell,
  coreutils,
  libnotify,
}:

writeShellApplication {
  name = "pick";
  runtimeInputs = [
    quickshell
    coreutils
    libnotify
  ];
  text = ''
    prompt="" refresh=""
    while [ $# -gt 0 ]; do
      case $1 in
        --prompt) prompt=$2; shift 2 ;;
        --refresh) refresh=$2; shift 2 ;;
        *) echo "pick: unknown option $1" >&2; exit 2 ;;
      esac
    done

    run=$(mktemp -d "''${XDG_RUNTIME_DIR:-/tmp}/pick.XXXXXX")
    trap 'rm -rf "$run"' EXIT
    mkfifo "$run/choice"
    cat >"$run/rows"

    # Quickshell exits 0 on "Target not found" (an older shell), so any
    # output is a failure too.
    picker() {
      local out
      out=$(qs -c desk ipc call picker "$@" 2>&1) && [ -z "$out" ]
    }

    refresh() {
      if bash -c "$refresh" >"$run/rows.new"; then
        mv "$run/rows.new" "$run/rows"
      fi
    }

    # The shell is also the notification daemon, so with no shell at all
    # there is no notification either: stderr, then.
    if ! picker open "$run/rows" "$run/choice" "$prompt"; then
      msg="The desk shell isn't running, or is too old for pick (systemctl --user status quickshell)"
      echo "pick: $msg" >&2
      notify-send -u critical -a pick "The menu didn't open" "$msg" 2>/dev/null || true
      exit 2
    fi

    if [ -n "$refresh" ]; then
      picker busy "$run/rows" || true
      # Not on this script's stdout, which the caller is reading to its end;
      # and the run directory may be gone by the end, once picked.
      (
        refresh || true
        [ ! -d "$run" ] || picker reload "$run/rows" || true
      ) >/dev/null 2>&1 &
    fi
    key=""
    read -r key <"$run/choice" || true
    [ -n "$key" ] || exit 1
    printf '%s\n' "$key"
  '';
}
