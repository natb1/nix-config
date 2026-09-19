# Home-manager modules that exist only on the WSL host.
#
# These reach across the WSL boundary into Windows (/mnt/c, the Windows Chrome
# profile, %LOCALAPPDATA%). They are meaningless on macOS and on a native NixOS
# machine, so they are scoped to this host rather than shipped to every host
# behind a `pkgs.stdenv.isLinux` guard — a native NixOS box is also Linux, and
# the guard would wrongly enable them there.
#
# flake.nix imports this alongside modules/home for the wsl host only.

{ ... }:

{
  imports = [
    ./claude-in-chrome.nix
    ./wezterm-windows.nix
  ];
}
