# Home Manager Configuration Entry Point — shared by every host.
#
# Activated through each host's integrated configuration, never via a standalone
# `home-manager switch`:
#   - NixOS/WSL: `sudo nixos-rebuild switch --flake .#wsl` builds
#     nixosConfigurations.wsl, which integrates home-manager as a NixOS module.
#   - macOS: `darwin-rebuild switch --flake .#mba` builds
#     darwinConfigurations.mba, which integrates it via nix-darwin.
# On those integrated paths the NixOS/nix-darwin module sets
# `home-manager.backupFileExtension` automatically (see flake.nix).
#
# Host-specific home modules do NOT belong here. They live next to their host —
# see hosts/wsl/home/ for the Windows-facing modules that only make sense under
# WSL. Modules here must evaluate on every platform; where behavior genuinely
# differs by platform (not by host), they guard on pkgs.stdenv.isLinux /
# isDarwin.

{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./claude-code.nix
    ./direnv.nix
    ./gh.nix
    ./git.nix
    ./gpg.nix
    ./neovim.nix
    ./nix.nix
    ./ssh.nix
    ./ssh-authorized-keys.nix
    ./ssh-keygen.nix
    ./wezterm.nix
    ./zsh.nix
  ];

  # Public keys accepted by every machine this config builds, so each host can
  # reach the others. Authoritative: the list is written verbatim to
  # ~/.ssh/authorized_keys, and removing a key here revokes it on next rebuild.
  services.sshAuthorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBzEPhvoentKLmUnWPI0mfPHEFNP2bj0ekvC3N5LcI58 n8@nixos"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM7rlIYWYTjLuwkOyKsO4PxewINlxA8HezSW+GTpE9os n8@Nathans-MacBook-Air.local"
  ];

  home.packages = [
    pkgs.jq
    pkgs.google-cloud-sdk
    pkgs.pass
    pkgs.python3
  ] ++ lib.optionals pkgs.stdenv.isDarwin [
    # macOS: manage these with Nix instead of Homebrew. After switching, run
    # `brew uninstall go` so the Nix copy is the one on PATH.
    # (gh is already installed by programs.gh in gh.nix; jq above is Nix-only
    # and not a brew formula — both are already Nix-managed on macOS.)
    pkgs.go
  ];

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # Disable version mismatch check since we're using home-manager/master with nixos-unstable
  home.enableNixpkgsReleaseCheck = false;

  home.stateVersion = "24.11";
}
