# Zsh Shell Configuration
#
# Minimal zsh config managed by Home Manager.
# Ensures .zshrc and .zshenv exist so zsh-newuser-install doesn't prompt.

{ lib, pkgs, ... }:

{
  programs.zsh = {
    enable = true;
    # Put Homebrew on PATH for login shells. Previously this lived in an
    # unmanaged ~/.zprofile; managing it here lets Home Manager own the file.
    profileExtra = lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      eval "$(/opt/homebrew/bin/brew shellenv)"
    '';
    initContent = lib.mkOrder 1000 ''
      # Let `# ...` comments in pasted or typed commands be ignored, as in
      # bash; zsh's interactive default treats `#` as an argument.
      setopt interactive_comments
    '';
  };
}
