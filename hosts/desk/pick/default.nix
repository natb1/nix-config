# `pick`: dmenu-style, like `fuzzel --dmenu --index`, but a row can be
# several lines — each tab-separated field of an input line is one. Drawn by
# Quickshell (./shell.qml), in the desk shell's colours.
#
#   pick [--prompt TEXT] [--mesg TEXT] <rows
#
# Prints the chosen row's index, from 0; exits 1 when cancelled.

{
  writeShellApplication,
  runCommand,
  quickshell,
  coreutils,
}:

let
  config = runCommand "pick-qml" { } ''
    mkdir $out
    cp ${./shell.qml} $out/shell.qml
    cp ${../home/quickshell/Theme.qml} $out/Theme.qml
  '';
in
writeShellApplication {
  name = "pick";
  runtimeInputs = [
    quickshell
    coreutils
  ];
  text = ''
    prompt="" mesg=""
    while [ $# -gt 0 ]; do
      case $1 in
        --prompt) prompt=$2; shift 2 ;;
        --mesg) mesg=$2; shift 2 ;;
        *) echo "pick: unknown option $1" >&2; exit 2 ;;
      esac
    done

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    cat >"$dir/rows"

    # Quickshell logs to stderr, noisily; the log is shown only on a failure.
    # A config that fails to load leaves Quickshell waiting for a fix rather
    # than exiting, hence the timeout (an hour: long enough for any pick).
    if ! PICK_ROWS="$dir/rows" PICK_OUT="$dir/out" PICK_PROMPT="$prompt" PICK_MESG="$mesg" \
      timeout 1h quickshell --no-color -p ${config}/shell.qml >"$dir/log" 2>&1; then
      cat "$dir/log" >&2
      exit 2
    fi
    [ -s "$dir/out" ] || exit 1
    cat "$dir/out"
  '';
}
