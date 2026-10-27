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
}
