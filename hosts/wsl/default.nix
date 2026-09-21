# Host: wsl — the NixOS-WSL box on the Windows desktop.
#
# Everything here is WSL-specific. Config a native NixOS machine would also want
# lives in modules/nixos/ and is imported below.
#
# Rebuild:  sudo nixos-rebuild switch --flake ~/natb1/nix-config#wsl
#
# The `--flake` form is required: the `wsl.*` options below come from
# nixos-wsl.nixosModules.default, which flake.nix injects into this
# configuration. A channel-based `nixos-rebuild switch` has no such module and
# fails with an undefined-option error for `wsl.enable`.

{ ... }:

{
  imports = [
    ../../modules/nixos
    ./mounts.nix
  ];

  wsl.enable = true;
  wsl.defaultUser = "n8";

  # Renamed from the NixOS-WSL default ("nixos") so the three machines are
  # distinguishable. This name is what Tailscale registers as the node name
  # (wsl.<tailnet>.ts.net), what avahi publishes (wsl.local), and what the
  # wezterm mux domain in hosts/wsl/home/wezterm-windows-config.nix connects to
  # (`default_gui_startup_args = { 'connect', 'wsl' }`) — those three move
  # together, so change them together.
  #
  # NOT affected: the Windows-side WSL distro name stays "NixOS". That is
  # registered with Windows, not with NixOS, so `wsl.exe -d NixOS` and the
  # `//wsl$/NixOS/...` UNC paths in the wezterm modules are unchanged.
  networking.hostName = "wsl";

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.11"; # Did you read the comment?
}
