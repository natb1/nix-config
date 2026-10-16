# Home-manager modules that exist only on the desk host.
#
# These configure a graphical session — niri, Quickshell, swayidle.
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

  # rc servers for desk's private repos, beside the nix-config one
  # (modules/home/claude-remote-control.nix). Each must be trusted once:
  # `claude` in the repo, accept the dialog.
  services.claudeRemoteControl.extraDirectories = {
    ledger = "/srv/git/ledger";
    archai = "/srv/git/archai";
  };
}
