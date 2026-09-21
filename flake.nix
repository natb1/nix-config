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

      # claude-code is unfree; allow it by name rather than blanket-allowing.
      unfreePredicate =
        pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "claude-code" ];

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

      darwinConfigurations.mba = darwin.lib.darwinSystem {
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/mba
          home-manager.darwinModules.home-manager
          (home {
            hostPlatform = "aarch64-darwin";
            homeDirectory = "/Users/n8";
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
        }
        // weztermTests.wezterm-tests
        // claudeDaemonTests.claude-daemon-tests
      );
    };
}
