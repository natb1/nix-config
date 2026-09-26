# Home-manager modules that exist only on the desk host.
#
# These configure a graphical session — niri, waybar, swaync, fuzzel, swayidle.
# They are meaningless on the WSL box and on macOS, so they are scoped to this
# host rather than shipped to every host behind a platform guard: WSL is also
# Linux, and such a guard would wrongly enable them there.
#
# flake.nix imports this alongside modules/home for the desk host only.

{ ... }:

{
  imports = [
    ./desktop.nix
    ./media.nix
  ];
}
