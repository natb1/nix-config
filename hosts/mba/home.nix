# Home-manager modules that exist only on the Mac.
#
# flake.nix imports this alongside modules/home for the mba host only.

{ pkgs, ... }:

{
  # The Mac's terminal, as on desk (hosts/desk/home/desktop.nix). nixpkgs'
  # `ghostty` builds only on Linux; `ghostty-bin` is the upstream signed app,
  # installed to ~/Applications/Home Manager Apps.
  programs.ghostty = {
    enable = true;
    package = pkgs.ghostty-bin;
    settings = {
      # Left Option is Alt, so zellij's Alt bindings work over `ssh desk-term`
      # (modules/home/zellij.nix); right Option still types é and the like.
      macos-option-as-alt = "left";
    };
  };
}
