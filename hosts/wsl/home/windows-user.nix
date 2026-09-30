# Which Windows profile the WSL-only activation steps write into.
#
# copyWeztermToWindows (wezterm-windows-config.nix), installWeztermWindows
# (wezterm-windows.nix) and installClaudeChromeBridge (claude-in-chrome.nix) all
# write under C:\Users\<you>. This step resolves <you> once, ahead of all three,
# so they cannot pick different profiles, and leaves it in WINDOWS_USER:
# activation steps run in one shell, the way home-manager's own
# checkFilesChanged hands changedFiles to onFilesChange. WINDOWS_USER stays
# empty off WSL (no /mnt/c/Users), and each step skips itself on that.
#
# Resolution:
#   1. Ask Windows: cmd.exe's %USERPROFILE%, when it is C:\Users\<name> and that
#      directory exists. This is the authoritative answer, and the only one that
#      holds when C:\Users has several profiles.
#   2. Otherwise (interop unavailable, or a profile outside C:\Users) the first
#      entry of C:\Users that is not a system directory. Only this tier fails
#      the switch when it finds nothing.
#
# Activation runs in home-manager-<user>.service with home-manager's own fixed
# PATH (home.emptyActivationPath), which has none of the Windows directories WSL
# appends to login shells, so cmd.exe is called by its full path. Nothing from
# the shell that ran `nixos-rebuild switch` reaches that service either, which
# is why there is no environment-variable override.
#
# Activation also runs under `set -eu -o pipefail`, where a bare failing
# `var=$(...)` aborts the whole switch before the message after it can print,
# so each command substitution below keeps its failure local.

{ lib, ... }:

{
  home.activation.resolveWindowsUser = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    # Structured error codes for programmatic error handling by callers
    readonly WU_ERR_PERMISSION_DENIED=11
    readonly WU_ERR_USERNAME_DETECTION=12

    WINDOWS_USER=""
    if [ -d "/mnt/c/Users" ]; then
      if [ ! -r "/mnt/c/Users" ]; then
        echo "ERROR: Permission denied accessing /mnt/c/Users/" >&2
        echo "  WSL mount exists but directory is not readable" >&2
        echo "" >&2
        echo "To fix:" >&2
        echo "  1. Check mount options: mount | grep /mnt/c" >&2
        echo "  2. Check directory permissions: ls -ld /mnt/c/Users" >&2
        echo "  3. May need to remount with proper permissions" >&2
        exit $WU_ERR_PERMISSION_DENIED
      fi

      # 1. Windows' own answer. A miss (no interop, no output, a profile that is
      # not a directory straight under C:\Users) falls through to 2.
      WU_CMD_EXE=/mnt/c/Windows/System32/cmd.exe
      if [ -x "$WU_CMD_EXE" ]; then
        WU_PROFILE=$("$WU_CMD_EXE" /c echo %USERPROFILE% 2>/dev/null | tr -d '\r') || WU_PROFILE=""
        WU_NAME=""
        case "$WU_PROFILE" in
          [Cc]:\\Users\\*) WU_NAME="''${WU_PROFILE#?:\\Users\\}" ;;
        esac
        case "$WU_NAME" in
          "" | *\\* | */*) ;;
          *) if [ -d "/mnt/c/Users/$WU_NAME" ]; then WINDOWS_USER="$WU_NAME"; fi ;;
        esac
        if [ -z "$WINDOWS_USER" ] && [ -n "$WU_PROFILE" ]; then
          echo "WARNING: Windows reports %USERPROFILE% as '$WU_PROFILE', not a directory under /mnt/c/Users/; falling back to the first profile there" >&2
        fi
      fi

      # 2. The first entry of /mnt/c/Users that is not a system directory.
      if [ -z "$WINDOWS_USER" ]; then
        if ! WU_LS_OUTPUT=$(ls /mnt/c/Users/ 2>&1); then
          echo "ERROR: Failed to list /mnt/c/Users/ directory" >&2
          echo "  Error output:" >&2
          echo "$WU_LS_OUTPUT" | sed 's/^/    /' >&2
          echo "  Check permissions and mount status" >&2
          exit $WU_ERR_PERMISSION_DENIED
        fi

        WINDOWS_USER=$(grep -m1 -v -E '^(All Users|Default|Default User|Public|desktop.ini)$' <<<"$WU_LS_OUTPUT") || WINDOWS_USER=""

        if [ -z "$WINDOWS_USER" ]; then
          echo "ERROR: Failed to detect Windows username" >&2
          echo "  Directory is readable but no valid user directories found" >&2
          echo "  Available directories:" >&2
          echo "$WU_LS_OUTPUT" | sed 's/^/    /' >&2
          exit $WU_ERR_USERNAME_DETECTION
        fi

        # A candidate that is not a directory: a stray file in C:\Users, or the
        # mount going away between the listing and this check.
        if [ ! -d "/mnt/c/Users/$WINDOWS_USER" ]; then
          echo "ERROR: Detected Windows username '$WINDOWS_USER' but /mnt/c/Users/$WINDOWS_USER is not a directory" >&2
          echo "  Available directories:" >&2
          echo "$WU_LS_OUTPUT" | sed 's/^/    /' >&2
          exit $WU_ERR_USERNAME_DETECTION
        fi
      fi
    fi
  '';
}
