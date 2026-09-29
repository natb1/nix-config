# Claude-in-Chrome WSL→Windows Bridge (WSL only)
#
# Claude in Chrome doesn't officially support WSL, but a working bridge exists
# (anthropics/claude-code#41625): Windows-host Chrome talks to a WSL `claude`
# process via Chrome's native-messaging mechanism.
#
# This module installs the Windows-side artifacts on each home-manager
# activation:
#   1. C:\Users\<user>\.claude\chrome\chrome-native-host.bat — calls
#      `wsl.exe -d <distro> -- bash -lc 'claude --chrome-native-host'`
#   2. C:\Users\<user>\.claude\chrome\<host>.json — Chrome native-messaging
#      manifest pointing at the .bat
#   3. HKCU\Software\Google\Chrome\NativeMessagingHosts\<host> — REG_SZ value
#      pointing at the manifest path (HKCU needs no admin)
#   4. ~/.config/google-chrome/Default/Extensions → /mnt/c/.../Default/Extensions
#      symlink so claude inside WSL can read the installed extension
#
# What stays manual: installing the extension from the Chrome Web Store, and
# fully restarting Chrome (system tray) once after the first activation.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  extensionId = "fcoeoabgfenejglbffodgkkbkcdhcgfn";
  hostName = "com.anthropic.claude_code_browser_extension";

  # The distro the .bat enters. Chrome starts it with no WSL environment, so it
  # has to name one. This is the name the install is registered under on
  # Windows, not the NixOS hostname (README "Naming", hosts/wsl/default.nix);
  # modules/home/wezterm.nix and wezterm-windows-config.nix use the same
  # literal. Detecting it instead cannot work here: activation runs in
  # home-manager-<user>.service, whose environment never has WSL_DISTRO_NAME,
  # and the Windows default distro may be a different one.
  wslDistro = "NixOS";
in
{
  # DAG ordering: after "resolveWindowsUser" (windows-user.nix), which picks the
  # Windows profile.
  home.activation.installClaudeChromeBridge =
    lib.hm.dag.entryAfter [ "linkGeneration" "resolveWindowsUser" ] ''
      readonly CC_ERR_INSTALL_FAILED=34

      # WINDOWS_USER is empty when not running on WSL (see windows-user.nix).
      if [ -z "$WINDOWS_USER" ]; then
        echo "Not running on WSL, skipping Claude-in-Chrome bridge install"
      else
        CHROME_DIR="/mnt/c/Users/$WINDOWS_USER/.claude/chrome"
        BAT_PATH="$CHROME_DIR/chrome-native-host.bat"
        JSON_PATH="$CHROME_DIR/${hostName}.json"

        $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$CHROME_DIR"

        if [ -z "$DRY_RUN_CMD" ]; then
          # The .bat invokes WSL with a login shell so the user's nix profile
          # puts `claude` on PATH. Avoids baking a nix-store path that would
          # churn on every claude-code update.
          cat > "$BAT_PATH" <<BATEOF
@echo off
wsl.exe -d ${wslDistro} -- bash -lc "claude --chrome-native-host"
BATEOF

          # Native-messaging manifest. Backslashes are doubled for JSON
          # encoding of the Windows path. Single-quoted heredoc preserves the
          # literal backslashes; sed substitutes the username afterwards.
          cat > "$JSON_PATH" <<'JSONEOF'
{
  "name": "${hostName}",
  "description": "Claude Code WSL native-messaging host",
  "path": "C:\\Users\\__WINDOWS_USER__\\.claude\\chrome\\chrome-native-host.bat",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://${extensionId}/"
  ]
}
JSONEOF
          ${pkgs.gnused}/bin/sed -i "s/__WINDOWS_USER__/$WINDOWS_USER/g" "$JSON_PATH"

          echo "Wrote $BAT_PATH (WSL distro: ${wslDistro})"
          echo "Wrote $JSON_PATH"

          # Register HKCU NativeMessagingHosts key. /f overwrites without
          # prompting, making this idempotent. HKCU is unprivileged.
          WIN_JSON_PATH='C:\Users\'"$WINDOWS_USER"'\.claude\chrome\${hostName}.json'
          if /mnt/c/Windows/System32/reg.exe add \
              "HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\${hostName}" \
              /ve /t REG_SZ /d "$WIN_JSON_PATH" /f >/dev/null 2>&1; then
            echo "Registered HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\${hostName}"
          else
            echo "ERROR: Failed to register native-messaging host in HKCU" >&2
            exit $CC_ERR_INSTALL_FAILED
          fi
        fi

        # WSL-side Extensions symlink: only when the Default Chrome profile
        # actually exists on Windows. ln -sfn replaces an existing symlink.
        WIN_EXTENSIONS_DIR="/mnt/c/Users/$WINDOWS_USER/AppData/Local/Google/Chrome/User Data/Default/Extensions"
        WSL_CHROME_PROFILE="$HOME/.config/google-chrome/Default"
        if [ -d "$WIN_EXTENSIONS_DIR" ]; then
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$WSL_CHROME_PROFILE"
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/ln -sfn "$WIN_EXTENSIONS_DIR" "$WSL_CHROME_PROFILE/Extensions"
          echo "Linked $WSL_CHROME_PROFILE/Extensions -> $WIN_EXTENSIONS_DIR"
        else
          echo "Windows Chrome Default profile not found at $WIN_EXTENSIONS_DIR; skipping Extensions symlink"
        fi

        echo ""
        echo "Claude-in-Chrome bridge installed."
        echo "  Fully quit Chrome from the system tray and relaunch to activate."
        echo "  Then run 'claude --chrome' inside WSL to start bridging."
      fi
    '';
}
