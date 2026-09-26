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
# The shell answers on a FIFO. If it isn't running, the menu is fuzzel, one
# line per row, after the refresh.

{
  writeShellApplication,
  quickshell,
  fuzzel,
  coreutils,
  gawk,
  gnused,
}:

writeShellApplication {
  name = "pick";
  runtimeInputs = [
    quickshell
    fuzzel
    coreutils
    gawk
    gnused
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

    if picker open "$run/rows" "$run/choice" "$prompt"; then
      if [ -n "$refresh" ]; then
        picker busy "$run/rows" || true
        # Not on this script's stdout, which the caller is reading to its
        # end; and the run directory may be gone by the end, once picked.
        (
          refresh || true
          [ ! -d "$run" ] || picker reload "$run/rows" || true
        ) >/dev/null 2>&1 &
      fi
      key=""
      read -r key <"$run/choice" || true
    else
      [ -z "$refresh" ] || refresh
      n=$(cut -f 2- "$run/rows" | sed 's/\t/  ·  /g' |
        fuzzel --dmenu --index --prompt "$prompt " --lines 15 --width 120) || n=-1
      key=$(awk -F '\t' -v n="$n" 'NR == n + 1 { print $1 }' "$run/rows")
    fi
    [ -n "$key" ] || exit 1
    printf '%s\n' "$key"
  '';
}
