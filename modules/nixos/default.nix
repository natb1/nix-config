# NixOS configuration shared by every Linux host (currently the WSL box; a
# native machine will import this unchanged).
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
    publish = {
      enable = true;
      addresses = true;
      domain = true;
      hinfo = true;
      userServices = true;
      workstation = true;
    };
  };

  users.users.${user} = {
    isNormalUser = true;
    home = "/home/${user}";
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.zsh;
    # Keep the wezterm-mux-server user service alive across logins declaratively,
    # replacing the imperative `loginctl enable-linger`.
    linger = true;
  };

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  virtualisation.docker.enable = true;

  environment.variables.EDITOR = "nvim";

  # Eastern time. America/New_York tracks EST/EDT automatically.
  time.timeZone = "America/New_York";
}
