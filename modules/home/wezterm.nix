# WezTerm Configuration Module
#
# Configures WezTerm terminal emulator through Home Manager, for every host.
#
# Platform-specific behavior:
# - Linux: runs the mux server as a systemd user service
# - macOS: Includes native fullscreen mode setting
# - All: Minimal config using config_builder(), Tailscale-discovered ssh_domains
#
# WSL-only behavior (Windows GUI defaults, copying the config to the Windows
# profile) lives in hosts/wsl/home/wezterm-windows-config.nix.

{
  config,
  pkgs,
  lib,
  ...
}:

{
  programs.wezterm = {
    enable = true;

    # Build wezterm from the pinned nightly (modules/home/wezterm-pin.nix) rather
    # than the nixpkgs snapshot, so every mux client and server this repo installs
    # — the WSL mux server, the Mac GUI, and the Windows GUI that
    # hosts/wsl/home/wezterm-windows.nix mirrors — share one version. The
    # mux-server user service below references config.programs.wezterm.package,
    # so it follows this automatically. Refresh with scripts/sync-wezterm.sh.
    package = pkgs.callPackage ./wezterm-package.nix { };

    # extraConfig is assembled from ordered fragments so host modules can add
    # Lua between the config_builder() call and the shared body (e.g.
    # hosts/wsl/home/wezterm-windows-config.nix, at mkOrder 600). The opening
    # and the closing `return config` are pinned at mkBefore / mkAfter.
    extraConfig = lib.mkMerge [
      (lib.mkBefore ''
        local config = wezterm.config_builder()
      '')

      (lib.mkIf pkgs.stdenv.isDarwin ''
        -- Enable macOS native fullscreen mode
        config.native_macos_fullscreen_mode = true
      '')

      ''
        -- Auto-discover Tailscale peers for ssh_domains.
        -- Wrapped in pcall so config loads cleanly if tailscale is unavailable.
        -- On Windows, tailscale runs inside WSL so invoke it via a login shell
        -- to get the NixOS PATH (a non-login shell won't have tailscale on PATH).
        local is_windows = wezterm.target_triple:find('windows')
        local tailscale_status_cmd = { 'tailscale', 'status', '--json' }
        if is_windows then
          tailscale_status_cmd = { 'wsl.exe', '-d', 'NixOS', '--', 'bash', '-lc', 'tailscale status --json' }
        end

        local ssh_domains = {}
        local pcall_ok, pcall_err = pcall(function()
          local ok, stdout, stderr = wezterm.run_child_process(tailscale_status_cmd)
          if not ok then
            wezterm.log_warn('tailscale status failed: ' .. (stderr or '(no stderr)'))
            return
          end
          local status = wezterm.json_parse(stdout)
          if not status then
            wezterm.log_warn('Failed to parse tailscale status JSON; stdout length: ' .. #stdout)
            return
          end
          -- Collect all nodes: Self + Peers
          local nodes = {}
          if status.Self then
            table.insert(nodes, status.Self)
          end
          if status.Peer then
            for _, peer in pairs(status.Peer) do
              table.insert(nodes, peer)
            end
          end
          for _, node in ipairs(nodes) do
            if node.DNSName then
              -- DNSName has a trailing dot; strip it and take the short hostname
              local fqdn = node.DNSName:gsub('%.$', "")
              local hostname = fqdn:match('^([^.]+)')
              if hostname then
                local domain = {
                  name = hostname,
                  remote_address = hostname,
                  username = ${lib.strings.toJSON config.home.username},
                }
                -- On Windows, point to the WSL SSH key via the \\wsl$ UNC share
                -- since WezTerm's built-in SSH client can't see the WSL filesystem.
                if is_windows then
                  domain.ssh_option = {
                    identityfile = '//wsl$/NixOS/home/' .. ${lib.strings.toJSON config.home.username} .. '/.ssh/id_ed25519',
                  }
                end
                table.insert(ssh_domains, domain)
              end
            end
          end
        end)
        if not pcall_ok then
          wezterm.log_warn('ssh_domains discovery failed: ' .. tostring(pcall_err))
        end
        config.ssh_domains = ssh_domains

        config.keys = {
          { key = '9', mods = 'CMD', action = wezterm.action.ActivateTabRelative(1) },
        }

        wezterm.on('format-tab-title', function(tab)
          local index = tab.tab_index + 1
          local branch = tab.active_pane.user_vars.git_branch or ""
          local title = tab.active_pane.title
          if branch ~= "" then
            return index .. ': ' .. branch .. ' > ' .. title
          end
          return index .. ': ' .. title
        end)
      ''

      (lib.mkAfter ''
        return config
      '')
    ];
  };

  # NixOS: run the mux server as a managed systemd user service.
  #
  # Otherwise the mux server is spawned lazily by `wezterm connect` as a detached
  # process that never restarts. After `home-manager switch` upgrades wezterm, that
  # stale process keeps the old binary, and a freshly-upgraded client fails the mux
  # version handshake ("unexpected response ... UnitResponse").
  #
  # As a managed unit its ExecStart store path tracks the active generation, so
  # home-manager's sd-switch (startServices defaults to true) restarts it onto the
  # new binary on every switch — keeping the running mux in lockstep with the
  # installed version. Cost: the restart drops live remote panes, which is inherent
  # to upgrading the binary.
  #
  # Note: on a headless server this user service only runs while the user has a
  # session. To keep it up across logins, enable lingering once on the box:
  #   loginctl enable-linger <user>
  systemd.user.services.wezterm-mux-server = lib.mkIf pkgs.stdenv.isLinux {
    Unit = {
      Description = "WezTerm multiplexer server";
      After = [ "default.target" ];
    };
    Service = {
      # --daemonize is a bare boolean flag (no `=value` form accepted); its
      # absence already means "run in the foreground", which is what a
      # systemd-supervised process needs.
      ExecStart = "${config.programs.wezterm.package}/bin/wezterm-mux-server";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
