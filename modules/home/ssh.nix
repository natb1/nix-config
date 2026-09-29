# SSH Configuration Module
#
# This module configures SSH client settings through Home Manager.
# Home Manager will manage your ~/.ssh/config file declaratively.
#
# Features:
# - SSH agent integration
# - Security-focused defaults (modern ciphers, key algorithms)
# - Host-specific configurations
#
# To add a new host, add an entry to programs.ssh.settings

{ ... }:

{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    # No KexAlgorithms: OpenSSH's own default puts the post-quantum hybrids it
    # has (mlkem768x25519-sha256, sntrup761x25519-sha512) first, and a list
    # here would either leave them out or name one the Mac's system ssh may
    # not know, which it rejects as a fatal config error.
    extraConfig = ''
      Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
      MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
      HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
    '';

    settings = {
      "*" = {
        ForwardAgent = false;
        Compression = false;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "auto";
        ControlPath = "~/.ssh/sockets/%r@%h:%p";
        ControlPersist = "10m";
        ServerAliveInterval = 60;
        ServerAliveCountMax = 3;
        HashKnownHosts = true;
        AddKeysToAgent = "no";
        StrictHostKeyChecking = "ask";
        VerifyHostKeyDNS = "yes";
      };

      "github.com" = {
        HostName = "github.com";
        User = "git";
        IdentityFile = "~/.ssh/id_ed25519";
        IdentitiesOnly = true;
      };
    };
  };

  # SSH Agent service - manages SSH keys in memory
  services.ssh-agent = {
    enable = true;
  };

  # Ensure the sockets directory exists for ControlMaster
  home.file.".ssh/sockets/.keep".text = "";
}
