# NixOS configuration shared by every Linux host (wsl and desk).
#
# WSL-specific system config does NOT belong here — it lives in hosts/wsl/
# (wsl.* options, the Windows drive mounts, the hostname). What is here is
# config a native NixOS machine would want identically.

{ pkgs, ... }:

let
  # One user, one repo — no indirection. A second user would become an option.
  user = "n8";
in
{
  imports = [
    ./tailscale.nix
  ];

  # Enable OpenSSH server
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # Enable Avahi for mDNS (allows <hostname>.local resolution)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    settings.publish = {
      disable-publishing = false;
      disable-user-service-publishing = false;
      publish-addresses = true;
      publish-domain = true;
      publish-hinfo = true;
      publish-workstation = true;
    };
  };

  users.users.${user} = {
    isNormalUser = true;
    home = "/home/${user}";
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.zsh;
    # The user manager runs from boot, not from the first login, and outlives
    # the last: user services (claude-remote-control on desk) need no one
    # logged in. Replaces the imperative `loginctl enable-linger`.
    linger = true;
  };

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  virtualisation.docker.enable = true;

  environment.variables.EDITOR = "nvim";

  # Eastern time. America/New_York tracks EST/EDT automatically.
  time.timeZone = "America/New_York";

  # Keep the store from filling the root disk. Every switch adds a system
  # generation, and each one pins its whole closure; with no GC, desk's root
  # filled at 116 generations (~100G of /nix/store). Weekly, drop generations
  # older than two weeks — that still leaves recent ones to roll back to.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  # Hard-link identical store files as they are added.
  nix.settings.auto-optimise-store = true;

  # Cap the persistent journal; unbounded it had grown to 3.7G on desk.
  services.journald.settings.Journal.SystemMaxUse = "1G";
}
