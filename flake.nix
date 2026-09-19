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

        home-manager.users.n8 = {
          imports = [ ./modules/home ] ++ extraModules;
          home.username = "n8";
          home.homeDirectory = homeDirectory;
        };
      };

      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
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
          {
            # modules/home/wezterm.nix sets programs.wezterm.enable = true for
            # the Linux mux server; macOS runs the WezTerm GUI installed outside
            # Nix, so disable the home-manager copy here.
            home-manager.users.n8 = { lib, ... }: {
              programs.wezterm.enable = lib.mkForce false;
            };
          }
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
        let weztermTests = pkgs.callPackage ./tests/wezterm.test.nix { };
        in { wezterm-test-suite = weztermTests.wezterm-test-suite; }
           // weztermTests.wezterm-tests
      );
    };
}
