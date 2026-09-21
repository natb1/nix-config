# WezTerm on the Windows side of the WSL host.
#
# The WSL box runs the wezterm mux server (modules/home/wezterm.nix); the GUI
# the user actually looks at is the Windows WezTerm, which reads
# C:\Users\<you>\.wezterm.lua rather than anything in the WSL home. This module
# makes the shared config serve that GUI:
#
# - a Lua fragment, guarded on target_triple at runtime, that makes the Windows
#   GUI launch into the NixOS distro and auto-connect to the `wsl` mux domain.
#   The NixOS mux server reads the same file, and wsl.exe only exists on the
#   Windows side — hence the runtime guard rather than a build-time one.
# - an activation step that copies the generated config to the Windows profile.
#
# Both are WSL-only: on macOS or a native NixOS machine there is no Windows GUI
# to serve. Installing the Windows binary itself is wezterm-windows.nix.

{
  config,
  lib,
  ...
}:

{
  # Ordered after the `local config = wezterm.config_builder()` fragment and
  # before the shared body in modules/home/wezterm.nix.
  programs.wezterm.extraConfig = lib.mkOrder 600 ''
    -- WSL Integration: set default_prog only when running on Windows.
    -- This config is generated on NixOS and copied to Windows, but the NixOS
    -- mux server also reads it — wsl.exe only exists on the Windows side.
    if wezterm.target_triple:find('windows') then
      config.default_prog = { 'wsl.exe', '-d', 'NixOS', '--cd', '/home/' .. ${lib.strings.toJSON config.home.username} }
      config.default_gui_startup_args = { 'connect', 'wsl' }
    end
  '';

  # Copy config to the Windows WezTerm location.
  # DAG ordering: Must run after "linkGeneration" to ensure the source file exists
  # before attempting to copy it to Windows.
  home.activation.copyWeztermToWindows = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    # Structured error codes for programmatic error handling by callers
    readonly ERR_PERMISSION_DENIED=11
    readonly ERR_USERNAME_DETECTION=12
    readonly ERR_SOURCE_MISSING=13
    readonly ERR_COPY_FAILED=14
    readonly ERR_SOURCE_EMPTY=15

    # Check if running on WSL (Windows mount point exists)
    if [ -d "/mnt/c/Users" ]; then
      # Verify /mnt/c/Users is readable
      if [ ! -r "/mnt/c/Users" ]; then
        echo "ERROR: Permission denied accessing /mnt/c/Users/" >&2
        echo "  WSL mount exists but directory is not readable" >&2
        echo "" >&2
        echo "To fix:" >&2
        echo "  1. Check mount options: mount | grep /mnt/c" >&2
        echo "  2. Check directory permissions: ls -ld /mnt/c/Users" >&2
        echo "  3. May need to remount with proper permissions" >&2
        exit $ERR_PERMISSION_DENIED
      fi

      # Three-tier resolution of the Windows user profile dir (TARGET_DIR).
      # The fallback chain is intended behavior per issue #62: each tier is
      # tried in order and falls through to the next on a miss; only the
      # final fallback tier raises a hard error.
      TARGET_DIR=""
      WINDOWS_USER=""

      # Tier 1 (override): an explicit WEZTERM_WINDOWS_USER env var wins when
      # it names a real profile. If set but missing, warn and fall through —
      # the override is a safe escape hatch, not a hard requirement.
      if [ -n "''${WEZTERM_WINDOWS_USER:-}" ]; then
        if [ -d "/mnt/c/Users/$WEZTERM_WINDOWS_USER" ]; then
          WINDOWS_USER="$WEZTERM_WINDOWS_USER"
          TARGET_DIR="/mnt/c/Users/$WINDOWS_USER"
        else
          echo "WARNING: WEZTERM_WINDOWS_USER='$WEZTERM_WINDOWS_USER' set but /mnt/c/Users/$WEZTERM_WINDOWS_USER does not exist; falling back to auto-detection" >&2
        fi
      fi

      # Tier 2 (WSL interop): ask Windows for its own %USERPROFILE% and map it
      # to a WSL path with wslpath. This is the authoritative answer on a real
      # WSL host. Any miss (interop absent, empty output, non-dir) falls through.
      if [ -z "$TARGET_DIR" ] && command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
        WIN_PROFILE=$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')
        CAND=$(wslpath -u "$WIN_PROFILE" 2>/dev/null)
        if [ -n "$CAND" ] && [ -d "$CAND" ]; then
          case "$CAND" in
            /mnt/c/Users/*)
              TARGET_DIR="$CAND"
              WINDOWS_USER=$(basename "$CAND")
              ;;
            *)
              echo "WARNING: wslpath returned '$CAND' which is not under /mnt/c/Users/; falling back to heuristic" >&2
              ;;
          esac
        fi
      fi

      # Tier 3 (fallback heuristic): list /mnt/c/Users, drop known system
      # directories, take the first remaining entry. This is the last resort
      # and the only tier that raises a hard error when it cannot resolve a
      # valid profile directory.
      if [ -z "$TARGET_DIR" ]; then
        LS_STDERR=$(mktemp)
        trap 'if ! rm -f "$LS_STDERR" 2>&1; then echo "WARNING: Failed to cleanup stderr temp file: $LS_STDERR" >&2; fi' EXIT
        LS_OUTPUT=$(ls /mnt/c/Users/ 2>"$LS_STDERR")
        LS_EXIT_CODE=$?

        if [ $LS_EXIT_CODE -ne 0 ]; then
          echo "ERROR: Failed to list /mnt/c/Users/ directory" >&2
          echo "  Exit code: $LS_EXIT_CODE" >&2
          if [ -s "$LS_STDERR" ]; then
            echo "  Error output:" >&2
            if ! cat "$LS_STDERR" 2>/dev/null | sed 's/^/    /' >&2; then
              echo "    (failed to read error file - may indicate filesystem issue)" >&2
              echo "    Error file location: $LS_STDERR" >&2
            fi
          fi
          echo "  Check permissions and mount status" >&2
          echo "  Diagnostic directory listing:" >&2
          ls -ld /mnt/c/Users/ 2>&1 || echo "  (diagnostic ls failed)" >&2
          exit $ERR_PERMISSION_DENIED
        fi

        WINDOWS_USER=$(echo "$LS_OUTPUT" | grep -v -E '^(All Users|Default|Default User|Public|desktop.ini)$' | head -n1)

        # Terminal failure: no candidate after filtering system directories.
        if [ -z "$WINDOWS_USER" ]; then
          echo "ERROR: Failed to detect Windows username" >&2
          echo "  Directory is readable but no valid user directories found" >&2
          echo "  Available directories:" >&2
          echo "$LS_OUTPUT" | sed 's/^/    /' >&2
          exit $ERR_USERNAME_DETECTION
        fi

        # Terminal failure: a candidate name was detected but its directory
        # does not exist (e.g. a race in mount availability).
        if [ ! -d "/mnt/c/Users/$WINDOWS_USER" ]; then
          echo "ERROR: Detected Windows username '$WINDOWS_USER' but directory does not exist" >&2
          echo "  Expected directory: /mnt/c/Users/$WINDOWS_USER" >&2
          echo "" >&2

          if ! ls_output=$(ls -1 /mnt/c/Users/ 2>&1); then
            echo "ERROR: Additionally, cannot list /mnt/c/Users/ for diagnostics" >&2
            echo "  Directory passed initial checks but is now inaccessible" >&2
            echo "  This indicates a filesystem or permission issue" >&2
            echo "  Error: $ls_output" >&2
            exit $ERR_USERNAME_DETECTION
          fi

          echo "Available directories in /mnt/c/Users/:" >&2
          echo "$ls_output" | sed 's/^/  /' >&2
          echo "" >&2
          echo "This may indicate:" >&2
          echo "  - WSL mount configuration issue" >&2
          echo "  - Incorrect user directory detection logic" >&2
          echo "  - Race condition in directory availability" >&2
          exit $ERR_USERNAME_DETECTION
        fi

        TARGET_DIR="/mnt/c/Users/$WINDOWS_USER"
      fi

      # TARGET_DIR is guaranteed set here: each tier either set it or, in the
      # case of tier 3, exited. Copy logic is keyed on TARGET_DIR/TARGET_FILE.
      TARGET_FILE="$TARGET_DIR/.wezterm.lua"

      # Verify source file exists before copying
      SOURCE_FILE="${config.home.homeDirectory}/.config/wezterm/wezterm.lua"
      if [ ! -f "$SOURCE_FILE" ]; then
        echo "ERROR: Source WezTerm config not found at $SOURCE_FILE" >&2
        echo "Home-Manager may have failed to generate the configuration" >&2
        exit $ERR_SOURCE_MISSING
      fi

      # Verify source file is not empty
      if [ ! -s "$SOURCE_FILE" ]; then
        echo "ERROR: Source WezTerm config is empty at $SOURCE_FILE" >&2
        echo "This may indicate:" >&2
        echo "  - Home-Manager configuration has empty extraConfig" >&2
        echo "  - File generation failed or was truncated" >&2
        echo "  - Accidental empty string in programs.wezterm.extraConfig" >&2
        exit $ERR_SOURCE_EMPTY
      fi

      # Copy config file with error checking and stderr capture
      if [ -z "$DRY_RUN_CMD" ]; then
        # Normal mode: capture stderr for better diagnostics
        if ! copy_error=$(cp ''${VERBOSE_ARG:+"$VERBOSE_ARG"} "$SOURCE_FILE" "$TARGET_FILE" 2>&1); then
          echo "ERROR: Failed to copy WezTerm config to $TARGET_FILE" >&2
          echo "  Copy error: $copy_error" >&2
          echo "  Common causes: permissions, disk space, file locked by running WezTerm" >&2
          exit $ERR_COPY_FAILED
        fi
      else
        # Dry run mode: execute but don't fail on dry run
        $DRY_RUN_CMD cp ''${VERBOSE_ARG:+"$VERBOSE_ARG"} "$SOURCE_FILE" "$TARGET_FILE"
      fi
      echo "Copied WezTerm config to Windows location: $TARGET_FILE"
    else
      echo "Not running on WSL, skipping Windows config copy"
    fi
  '';
}
