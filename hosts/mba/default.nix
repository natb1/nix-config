# Host: mba — the Apple Silicon MacBook Air.
#
# Rebuild:  darwin-rebuild switch --flake ~/natb1/nix-config#mba

{ ... }:

{
  imports = [
    ../../modules/darwin/tailscale.nix
  ];

  # Required for flake-based darwin-rebuild.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # nix.enable defaults to true and manages the nix-daemon launchd service;
  # services.nix-daemon.enable is obsolete and must NOT be set.

  time.timeZone = "America/New_York";

  system.stateVersion = 7;
}
