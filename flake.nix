{
  description = "Nix configuration for my machines";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Declarative partitioning for the `desk` host's bulk drive. Used at
    # install time (Phase 2) and for the fileSystems entries it generates from
    # the same declaration — see hosts/desk/disko.nix.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The libvirt domain for the Windows guest (Phase 4). Declared here rather
    # than in Phase 4 because flake inputs are cheap to carry and expensive to
    # add mid-install; the module is imported by `desk` but defines nothing
    # until virtualisation.libvirt is enabled.
    NixVirt = {
      url = "https://flakehub.com/f/AshleyYakeley/NixVirt/*.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # iPhone notifications and messages on `desk` over Bluetooth — see
    # hosts/desk/iphone.nix. Pinned to a rev in the URL, so the weekly
    # `nix flake update` leaves it alone: it is a fast-moving beta that
    # changes how bluetoothd runs, so a bump is a deliberate edit here.
    tether = {
      url = "github:zackb/tether/779b8a4d970f3aa34f105fc9a84d06f186670ec1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, home-manager, claude-code-nix, darwin, nixos-wsl, ... }:
    let
      # direnv 2.37.1 checkPhase hangs when built from source; skip tests.
      direnvSkipTestsOverlay = final: prev: {
        direnv = prev.direnv.overrideAttrs (_: { doCheck = false; });
      };

      # claude-code-nix pins pkgs.claude-code to the sadjow fork that
      # modules/home/claude-code.nix installs. Recent nixpkgs ships its own
      # claude-code, so without this overlay eval still succeeds but resolves to
      # nixpkgs' build/version instead.
      overlay = nixpkgs.lib.composeManyExtensions [
        claude-code-nix.overlays.default
        direnvSkipTestsOverlay
      ];

      # Unfree packages, allowed by name rather than blanket-allowing.
      # google-chrome is desk's browser (hosts/desk/desktop.nix). Naming it
      # here rather than in that host is not a choice: nixpkgs.config is set
      # once by the `home` helper below, so a second definition in a host
      # module conflicts with it instead of extending it.
      unfreePredicate =
        pkg: builtins.elem (nixpkgs.lib.getName pkg) [
          "claude-code"
          "google-chrome"
          # hosts/desk/gaming.nix
          "steam"
          "steam-unwrapped"
          # hosts/desk/home/desktop.nix — the cursor theme. GPL-3 code, but
          # nixpkgs also lists the macOS artwork as unfree.
          "apple_cursor"
        ];

      # Home-manager wiring shared by every host. hostPlatform in-module is the
      # current idiom (the legacy `system` arg to nixosSystem/darwinSystem is
      # discouraged). `extraModules` carries the host-only home modules — see
      # hosts/wsl/home.
      home = { hostPlatform, homeDirectory, extraModules ? [ ] }: {
        nixpkgs.hostPlatform = hostPlatform;
        nixpkgs.overlays = [ overlay ];
        nixpkgs.config.allowUnfreePredicate = unfreePredicate;

        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.extraSpecialArgs = { inherit inputs; };

        # When a switch meets an unmanaged file it wants to own, back it up
        # (.backup) instead of aborting mid-activation. This option exists only
        # in the NixOS/nix-darwin module, not in standalone home-manager.
        home-manager.backupFileExtension = "backup";

        # lib.mkForce is load-bearing, not redundant. home-manager's own
        # nixos/common.nix derives home.homeDirectory from
        # config.users.users.n8.home at priority 100. On darwin, hosts/mba
        # defines no users.users.n8, so that derivation yields null and eval
        # fails with "not of type `absolute path'". mkForce (priority 50) makes
        # the value here win. Do not drop it.
        home-manager.users.n8 = { lib, ... }: {
          imports = [ ./modules/home ] ++ extraModules;
          home.username = lib.mkForce "n8";
          home.homeDirectory = lib.mkForce homeDirectory;
        };
      };

      # The platforms this repo actually targets: the WSL box and a future native
      # NixOS machine (x86_64-linux), and the Apple Silicon Mac (aarch64-darwin).
      # x86_64-darwin is deliberately absent — nixpkgs 26.11 dropped support for
      # it, so listing it breaks `nix flake check --all-systems`.
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      forAllSystems = fn: nixpkgs.lib.genAttrs systems (system: fn {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit system;
      });
    in
    {
      nixosConfigurations.wsl = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          nixos-wsl.nixosModules.default
          ./hosts/wsl
          home-manager.nixosModules.home-manager
          (home {
            hostPlatform = "x86_64-linux";
            homeDirectory = "/home/n8";
            extraModules = [ ./hosts/wsl/home ];
          })
        ];
      };

      # The native desktop. Built from docs/desktop-migration.md; it boots
      # NixOS on the 1 TB NVMe and (from Phase 4) runs the existing Windows
      # install as a GPU-passthrough guest off the 2 TB one.
      nixosConfigurations.desk = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          # Reached via `inputs` rather than the outputs argument list, which
          # does not name disko — matching how the list above is written.
          inputs.disko.nixosModules.disko
          inputs.NixVirt.nixosModules.default
          inputs.tether.nixosModules.tether
          ./hosts/desk
          home-manager.nixosModules.home-manager
          (home {
            hostPlatform = "x86_64-linux";
            homeDirectory = "/home/n8";
            extraModules = [
              ./hosts/desk/home
              ./modules/home/claude-remote-control.nix
            ];
          })
        ];
      };

      darwinConfigurations.mba = darwin.lib.darwinSystem {
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/mba
          home-manager.darwinModules.home-manager
          (home {
            hostPlatform = "aarch64-darwin";
            homeDirectory = "/Users/n8";
            extraModules = [ ./modules/home/claude-remote-control.nix ];
          })
          # macOS uses modules/home/wezterm.nix as-is: it installs the pinned
          # nightly (modules/home/wezterm-package.nix) as a real WezTerm.app and
          # generates ~/.config/wezterm/wezterm.lua. Installing the pinned build
          # here — rather than an out-of-Nix GUI — keeps this Mac's `wezterm
          # connect` client in version lockstep with the WSL mux server, which is
          # built from the same pin. The module's Linux-only mux service is
          # guarded by pkgs.stdenv.hostPlatform.isLinux; the Windows-side pieces live in
          # hosts/wsl/home and are not imported here.
        ];
      };

      # WSL wezterm rebuilt from the pinned nightly (modules/home/wezterm-pin.nix).
      # Exposed so `nix build .#wezterm` can verify the pin and so
      # scripts/sync-wezterm.sh can resolve the vendor hash against it.
      packages = forAllSystems ({ pkgs, ... }: {
        wezterm = pkgs.callPackage ./modules/home/wezterm-package.nix { };
        # Media filing for /srv/media (docs/desktop-migration.md, "Layout on
        # the share"); `nix run .#media-stage -- --help`.
        media-stage = pkgs.callPackage ./pkgs/media-stage { };
        # Search and download into a staging batch; `nix run .#media-fetch -- --help`.
        media-fetch = pkgs.callPackage ./pkgs/media-fetch { };
      });

      # Module regression tests. `nix flake check` is the gate before a switch.
      checks = forAllSystems ({ pkgs, ... }:
        let
          weztermTests = pkgs.callPackage ./tests/wezterm.test.nix { };
          claudeDaemonTests = pkgs.callPackage ./tests/claude-daemon.test.nix { };
        in
        {
          wezterm-test-suite = weztermTests.wezterm-test-suite;
          claude-daemon-test-suite = claudeDaemonTests.claude-daemon-test-suite;
          # Its unit and pipeline tests run in the build.
          media-stage = pkgs.callPackage ./pkgs/media-stage { };
          media-fetch = pkgs.callPackage ./pkgs/media-fetch { };
        }
        // weztermTests.wezterm-tests
        // claudeDaemonTests.claude-daemon-tests
        # desk's niri config, parsed by the niri that will read it. A typo in
        # the KDL is otherwise only found at the next tty1 login, where it is
        # expensive: niri.service dies, and tty1 is the session. Linux only —
        # niri does not build for darwin.
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # Every directory tmpfiles makes under /srv/media keeps group write.
          # On them the group bits are the media group's ACL mask
          # (hosts/desk/media-group.nix), and `d` reapplies the mode on every
          # switch: a 0755 there left the group read-only in rpg/ and the
          # other library folders until someone reset the mask by hand.
          media-acl-mask =
            let
              lib = nixpkgs.lib;
              rules = self.nixosConfigurations.desk.config.systemd.tmpfiles.rules;
              parse = r: lib.splitString " " r;
              under = r: let f = parse r; in builtins.length f > 2
                && builtins.elem (builtins.elemAt f 0) [ "d" "z" "Z" ]
                && lib.hasPrefix "/srv/media" (builtins.elemAt f 1);
              groupWrite = r:
                let m = builtins.elemAt (parse r) 2; in
                m == "-" || builtins.elem
                  (builtins.substring (builtins.stringLength m - 2) 1 m) [ "7" "6" "3" "2" ];
              bad = builtins.filter (r: under r && !(groupWrite r)) rules;
            in
            pkgs.runCommand "media-acl-mask" { } ''
              ${lib.optionalString (bad != [ ]) ''
                echo "tmpfiles rules under /srv/media without group write:" >&2
                printf '  %s\n' ${lib.escapeShellArgs bad} >&2
                exit 1
              ''}
              touch "$out"
            '';
          niri-config =pkgs.runCommand "niri-config-valid" { } ''
            ${pkgs.niri}/bin/niri validate -c ${./hosts/desk/home/niri.kdl}
            touch "$out"
          '';
          # desk's Quickshell config (the panel and the notification daemon),
          # loaded by the Quickshell that will run it. A QML error otherwise
          # shows only after a switch, as no notifications at all. Quickshell
          # has no validate mode and its windows need a layer-shell
          # compositor, so it runs against a headless sway.
          quickshell-config = pkgs.runCommand "quickshell-config-loads" { } ''
            export HOME=$TMPDIR XDG_RUNTIME_DIR=$TMPDIR/run
            mkdir -m 700 "$XDG_RUNTIME_DIR"
            export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
            echo "" > sway.conf
            ${pkgs.sway-unwrapped}/bin/sway -c sway.conf > sway.log 2>&1 &
            for _ in $(seq 100); do
              [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break
              sleep 0.1
            done
            WAYLAND_DISPLAY=wayland-1 timeout 10 \
              ${pkgs.quickshell}/bin/qs -p ${./hosts/desk/home/quickshell} > qs.log 2>&1 || true
            kill %1 || true
            cat qs.log
            grep -q "Configuration Loaded" qs.log
            ! grep -qE "Failed to load configuration|TypeError|ReferenceError" qs.log
            touch "$out"
          '';
        }
      );
    };
}
