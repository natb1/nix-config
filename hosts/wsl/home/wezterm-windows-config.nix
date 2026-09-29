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
  # before attempting to copy it to Windows, and after "resolveWindowsUser"
  # (windows-user.nix), which picks the Windows profile it goes into.
  home.activation.copyWeztermToWindows = lib.hm.dag.entryAfter [ "linkGeneration" "resolveWindowsUser" ] ''
    # Structured error codes for programmatic error handling by callers
    readonly ERR_SOURCE_MISSING=13
    readonly ERR_COPY_FAILED=14
    readonly ERR_SOURCE_EMPTY=15

    # WINDOWS_USER is empty when not running on WSL (see windows-user.nix).
    if [ -n "$WINDOWS_USER" ]; then
      TARGET_FILE="/mnt/c/Users/$WINDOWS_USER/.wezterm.lua"

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

      # The source is a read-only store file, and on /mnt/c a missing write bit
      # is enforced (DrvFs also turns it into the Windows read-only attribute;
      # see wezterm-windows.nix). A plain cp gives a new target the source's
      # 0444, and the next switch's cp then fails on it. So copy without the
      # source's mode, and first repair a copy an older generation left
      # read-only. A chmod failure is left to the cp below to report.
      if [ -e "$TARGET_FILE" ] && [ ! -w "$TARGET_FILE" ]; then
        $DRY_RUN_CMD chmod u+w "$TARGET_FILE" 2>/dev/null || true
      fi

      # Copy config file with error checking and stderr capture
      if [ -z "$DRY_RUN_CMD" ]; then
        # Normal mode: capture stderr for better diagnostics
        if ! copy_error=$(cp --no-preserve=mode ''${VERBOSE_ARG:+"$VERBOSE_ARG"} "$SOURCE_FILE" "$TARGET_FILE" 2>&1); then
          echo "ERROR: Failed to copy WezTerm config to $TARGET_FILE" >&2
          echo "  Copy error: $copy_error" >&2
          echo "  Common causes: permissions, disk space, file locked by running WezTerm" >&2
          exit $ERR_COPY_FAILED
        fi
      else
        # Dry run mode: execute but don't fail on dry run
        $DRY_RUN_CMD cp --no-preserve=mode ''${VERBOSE_ARG:+"$VERBOSE_ARG"} "$SOURCE_FILE" "$TARGET_FILE"
      fi
      echo "Copied WezTerm config to Windows location: $TARGET_FILE"
    else
      echo "Not running on WSL, skipping Windows config copy"
    fi
  '';
}
