#!/usr/bin/env bash
# Runtime tests for the WSL host's copy-to-Windows activation steps:
# resolveWindowsUser (hosts/wsl/home/windows-user.nix), then
# copyWeztermToWindows (hosts/wsl/home/wezterm-windows-config.nix).
#
# tests/wezterm.test.nix hands over the real text of both steps, as the modules
# generate it, in $COPY_SCRIPT, and the home directory it was generated for in
# $MOCK_HOME. Each case builds a temp tree standing in for /mnt/c and the home
# directory, points a copy of the text at it, and runs that the way
# home-manager's activation script runs its steps: at top level, under
# `set -eu` and `set -o pipefail`, after an EXIT trap of home-manager's own,
# with DRY_RUN_CMD and VERBOSE_ARG exported and no Windows directory on PATH.
# It then checks the exit code, the output and the files left behind.
#
# Run with:  nix build .#checks.x86_64-linux.test-activation-script-runtime

if [[ -z "${COPY_SCRIPT:-}" || ! -f "$COPY_SCRIPT" || -z "${MOCK_HOME:-}" ]]; then
  echo "COPY_SCRIPT and MOCK_HOME are set by tests/wezterm.test.nix; run" >&2
  echo "  nix build .#checks.x86_64-linux.test-activation-script-runtime" >&2
  exit 2
fi

FAILURES=0
PASSES=0
CLEANUP_DIRS=()

cleanup() {
  for dir in "${CLEANUP_DIRS[@]}"; do
    chmod -R u+rwx "$dir" 2>/dev/null
    rm -rf "$dir" 2>/dev/null || echo "WARNING: Failed to cleanup directory: $dir" >&2
  done
  return 0 # Don't fail the trap
}
trap cleanup EXIT

report_pass() {
  echo "PASS: $1"
  ((PASSES++))
}

report_fail() {
  echo "FAIL: $1"
  if [[ -n "${2:-}" ]]; then
    echo "$2"
  fi
  ((FAILURES++))
}

# check DESCRIPTION COMMAND...: passes when COMMAND succeeds. A failure shows
# the case's exit code and output.
check() {
  local description="$1"
  shift
  if "$@"; then
    report_pass "$description"
  else
    report_fail "$description" "  exit $RC; output:"$'\n'"$(sed 's/^/    /' <<<"$OUT")"
  fi
}
rc_is() { [[ $RC -eq $1 ]]; }
has_out() { [[ "$OUT" == *"$1"* ]]; }
lacks_out() { [[ "$OUT" != *"$1"* ]]; }
same_file() { cmp -s "$1" "$2"; }

# new_case: a fresh tree — $MNT standing in for /mnt/c (with no Users yet),
# $SOURCE for the generated config, read-only like the store file home-manager
# links there — and $SCRIPT, the activation text pointed at them.
new_case() {
  ROOT=$(mktemp -d)
  CLEANUP_DIRS+=("$ROOT")
  MNT="$ROOT/mnt/c"
  HOME_DIR="$ROOT/home"
  SOURCE="$HOME_DIR/.config/wezterm/wezterm.lua"
  mkdir -p "$MNT" "$(dirname "$SOURCE")"
  printf -- '-- generated wezterm config\n' > "$SOURCE"
  chmod 444 "$SOURCE"
  SCRIPT="$ROOT/activate.sh"
  sed -e "s#/mnt/c#$MNT#g" -e "s#$MOCK_HOME#$HOME_DIR#g" "$COPY_SCRIPT" > "$SCRIPT"
}

# users NAME...: entries in the stand-in C:\Users; a name ending in .ini is a
# file, anything else a directory.
users() {
  local name
  mkdir -p "$MNT/Users"
  for name in "$@"; do
    if [[ "$name" == *.ini ]]; then
      touch "$MNT/Users/$name"
    else
      mkdir -p "$MNT/Users/$name"
    fi
  done
}

# fake_cmd_exe: a cmd.exe at the full path the resolver calls. It answers with
# $FAKE_PROFILE (when set) ended by the CRLF Windows prints, then exits
# $FAKE_STATUS. It is not on PATH, just as activation's PATH has no Windows
# directories.
fake_cmd_exe() {
  mkdir -p "$MNT/Windows/System32"
  cat > "$MNT/Windows/System32/cmd.exe" <<'EOF'
#!/bin/sh
if [ -n "${FAKE_PROFILE:-}" ]; then printf '%s\r\n' "$FAKE_PROFILE"; fi
exit "${FAKE_STATUS:-0}"
EOF
  chmod +x "$MNT/Windows/System32/cmd.exe"
}

# run_case [VAR=VALUE...]: runs $SCRIPT as described at the top and sets RC and
# OUT (stdout and stderr together). The arguments go to env, so a case can set
# DRY_RUN_CMD, VERBOSE_ARG, PATH or the fake cmd.exe's answer.
run_case() {
  OUT=$(env DRY_RUN_CMD= VERBOSE_ARG= "$@" "$BASH" -c '
    set -eu
    set -o pipefail
    trap "echo HM_EXIT_TRAP_RAN" EXIT
    source "$1"
  ' activate "$SCRIPT" 2>&1)
  RC=$?
}

echo "Running the copyWeztermToWindows activation text..."

echo ""
echo "=== Not WSL: no /mnt/c/Users ==="
new_case
run_case
check "exits 0 off WSL" rc_is 0
check "says it is skipping the copy" has_out "Not running on WSL, skipping Windows config copy"

echo ""
echo "=== No interop: the first non-system profile gets the config ==="
new_case
users alice bob Public Default "Default User" "All Users" desktop.ini
run_case
check "exits 0" rc_is 0
check "copies the config into alice's profile" same_file "$SOURCE" "$MNT/Users/alice/.wezterm.lua"
check "leaves bob's profile alone" test ! -e "$MNT/Users/bob/.wezterm.lua"
check "reports the copy" has_out "Copied WezTerm config to Windows location: $MNT/Users/alice/.wezterm.lua"
check "keeps home-manager's own EXIT trap" has_out "HM_EXIT_TRAP_RAN"

echo ""
echo "=== No interop: a profile name with spaces ==="
new_case
users "John Doe" Public
run_case
check "copies into 'John Doe'" same_file "$SOURCE" "$MNT/Users/John Doe/.wezterm.lua"

echo ""
echo "=== Interop: Windows' %USERPROFILE% wins over the first profile ==="
new_case
users alice bob
fake_cmd_exe
run_case 'FAKE_PROFILE=C:\Users\bob'
check "exits 0" rc_is 0
check "copies into bob's profile, the one Windows names" same_file "$SOURCE" "$MNT/Users/bob/.wezterm.lua"
check "leaves alice's profile alone" test ! -e "$MNT/Users/alice/.wezterm.lua"
check "does not warn" lacks_out "WARNING"

echo ""
echo "=== Interop fails: falls back to the first profile ==="
new_case
users alice bob
fake_cmd_exe
run_case FAKE_STATUS=1
check "exits 0" rc_is 0
check "copies into alice's profile" same_file "$SOURCE" "$MNT/Users/alice/.wezterm.lua"

echo ""
echo "=== Interop names a profile outside C:\\Users: warns and falls back ==="
new_case
users alice bob
fake_cmd_exe
run_case 'FAKE_PROFILE=D:\Profiles\bob'
check "exits 0" rc_is 0
check "copies into alice's profile" same_file "$SOURCE" "$MNT/Users/alice/.wezterm.lua"
check "warns about the unusable answer" has_out 'WARNING: Windows reports %USERPROFILE% as '"'"'D:\Profiles\bob'"'"

echo ""
echo "=== Interop names a missing profile: warns and falls back ==="
new_case
users alice bob
fake_cmd_exe
run_case 'FAKE_PROFILE=C:\Users\ghost'
check "exits 0" rc_is 0
check "copies into alice's profile" same_file "$SOURCE" "$MNT/Users/alice/.wezterm.lua"
check "warns about the unusable answer" has_out "WARNING: Windows reports %USERPROFILE%"

echo ""
echo "=== Only system directories: exit 12 with the listing ==="
new_case
users Public Default desktop.ini
run_case
check "exits 12" rc_is 12
check "explains the failure" has_out "ERROR: Failed to detect Windows username"
check "lists what it found" has_out "    Public"
check "keeps home-manager's own EXIT trap on failure" has_out "HM_EXIT_TRAP_RAN"

echo ""
echo "=== Empty C:\\Users: exit 12 ==="
new_case
users
run_case
check "exits 12" rc_is 12
check "explains the failure" has_out "ERROR: Failed to detect Windows username"

echo ""
echo "=== First entry is not a directory: exit 12 ==="
new_case
users bob
touch "$MNT/Users/aaa-stray-file"
run_case
check "exits 12" rc_is 12
check "names the entry" has_out "ERROR: Detected Windows username 'aaa-stray-file'"

echo ""
echo "=== C:\\Users not readable: exit 11 ==="
new_case
users alice
chmod 000 "$MNT/Users"
if [[ -r "$MNT/Users" ]]; then
  echo "SKIP: running as root, which reads a mode-000 directory"
else
  run_case
  check "exits 11" rc_is 11
  check "explains the failure" has_out "ERROR: Permission denied accessing"
fi
chmod 755 "$MNT/Users"

echo ""
echo "=== Listing C:\\Users fails after the readable check: exit 11 ==="
new_case
users alice
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/ls" <<'EOF'
#!/bin/sh
echo "ls: reading directory '$1': Input/output error" >&2
exit 2
EOF
chmod +x "$ROOT/bin/ls"
run_case PATH="$ROOT/bin:$PATH"
check "exits 11" rc_is 11
check "explains the failure" has_out "ERROR: Failed to list $MNT/Users/ directory"
check "shows ls's own error" has_out "Input/output error"

echo ""
echo "=== Source config missing: exit 13 ==="
new_case
users alice
chmod u+w "$SOURCE" && rm -f "$SOURCE"
run_case
check "exits 13" rc_is 13
check "explains the failure" has_out "ERROR: Source WezTerm config not found at $SOURCE"

echo ""
echo "=== Source config empty: exit 15 ==="
new_case
users alice
chmod u+w "$SOURCE" && : > "$SOURCE"
run_case
check "exits 15" rc_is 15
check "explains the failure" has_out "ERROR: Source WezTerm config is empty"

echo ""
echo "=== A read-only copy an older generation left is replaced ==="
new_case
users alice
printf -- '-- old config\n' > "$MNT/Users/alice/.wezterm.lua"
chmod 444 "$MNT/Users/alice/.wezterm.lua"
run_case
check "exits 0" rc_is 0
check "replaces its content" same_file "$SOURCE" "$MNT/Users/alice/.wezterm.lua"
check "leaves it writable" test -w "$MNT/Users/alice/.wezterm.lua"

echo ""
echo "=== The copy from a read-only source is writable, so the next switch works ==="
new_case
users alice
run_case
check "first switch exits 0" rc_is 0
check "the new copy is writable" test -w "$MNT/Users/alice/.wezterm.lua"
run_case
check "second switch exits 0" rc_is 0

echo ""
echo "=== Profile not writable: exit 14 ==="
new_case
users alice
chmod 555 "$MNT/Users/alice"
if [[ -w "$MNT/Users/alice" ]]; then
  echo "SKIP: running as root, which writes a mode-555 directory"
else
  run_case
  check "exits 14" rc_is 14
  check "explains the failure" has_out "ERROR: Failed to copy WezTerm config to $MNT/Users/alice/.wezterm.lua"
fi
chmod 755 "$MNT/Users/alice"

echo ""
echo "=== Dry run: nothing is written ==="
new_case
users alice
run_case DRY_RUN_CMD=echo
check "exits 0" rc_is 0
check "writes no file" test ! -e "$MNT/Users/alice/.wezterm.lua"

echo ""
echo "=== Verbose: cp takes home-manager's VERBOSE_ARG ==="
new_case
users alice
run_case VERBOSE_ARG=--verbose
check "exits 0" rc_is 0
check "copies the config" same_file "$SOURCE" "$MNT/Users/alice/.wezterm.lua"

echo ""
echo "================================"
echo "Passed: $PASSES"
echo "Failed: $FAILURES"
echo "================================"

if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
