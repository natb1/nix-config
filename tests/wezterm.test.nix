# WezTerm Module Tests
#
# Validates the WezTerm Home Manager configuration as each host composes it:
# - modules/home/wezterm.nix alone (macOS, a native NixOS machine)
# - plus hosts/wsl/home/wezterm-windows-config.nix and the Windows-profile
#   resolver it runs after, hosts/wsl/home/windows-user.nix (the WSL host)
#
# Covers:
# 1. Lua syntax validation for generated config
# 2. Platform-specific and host-specific logic
# 3. Variable interpolation (username, home directory)
# 4. The WSL copy-to-Windows activation text, run for real (wezterm_test.sh)
#
# Modules are evaluated with lib.evalModules against stub declarations of the
# few home-manager options they touch, so fragment ordering (mkBefore/mkOrder/
# mkAfter) and mkIf are resolved exactly as home-manager would resolve them.

{ pkgs, lib, ... }:

let
  weztermModule = ../modules/home/wezterm.nix;
  wslWeztermModule = ../hosts/wsl/home/wezterm-windows-config.nix;
  wslWindowsUserModule = ../hosts/wsl/home/windows-user.nix;

  # lib.hm.dag stand-in: records the DAG entry so tests can inspect it.
  hmLib = lib.extend (
    _final: _prev: {
      hm.dag.entryAfter = deps: data: {
        _type = "dagEntryAfter";
        after = deps;
        inherit data;
      };
    }
  );

  # Declarations for the home-manager options the modules under test set.
  stubOptions =
    { lib, ... }:
    {
      options = {
        home.username = lib.mkOption { type = lib.types.str; };
        home.homeDirectory = lib.mkOption { type = lib.types.str; };
        home.activation = lib.mkOption {
          type = lib.types.attrsOf lib.types.raw;
          default = { };
        };
        programs.wezterm = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          package = lib.mkOption { type = lib.types.raw; };
          extraConfig = lib.mkOption {
            type = lib.types.lines;
            default = "";
          };
        };
        systemd.user.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.raw;
          default = { };
        };
      };
    };

  # Test helper: Evaluate the modules a host would import, with mock config.
  # `wslHost` adds the WSL host module, as flake.nix does for the wsl host.
  evaluateModule =
    {
      username ? "testuser",
      homeDirectory ? "/home/testuser",
      isLinux ? true,
      isDarwin ? false,
      wslHost ? false,
    }:
    assert lib.assertMsg (username != "") "evaluateModule: username cannot be empty";
    assert lib.assertMsg (homeDirectory != "") "evaluateModule: homeDirectory cannot be empty";
    assert lib.assertMsg (lib.hasPrefix "/" homeDirectory)
      "evaluateModule: homeDirectory must be an absolute path starting with /";
    assert lib.assertMsg (
      !lib.hasSuffix "/" homeDirectory || homeDirectory == "/"
    ) "evaluateModule: homeDirectory should not end with / (except root)";
    assert lib.assertMsg (
      !(isLinux && isDarwin)
    ) "evaluateModule: Cannot have both isLinux=true and isDarwin=true (mutually exclusive platforms)";
    assert lib.assertMsg (
      !(wslHost && !isLinux)
    ) "evaluateModule: wslHost requires isLinux=true";
    let
      mockPkgs = pkgs // {
        stdenv = pkgs.stdenv // {
          hostPlatform = pkgs.stdenv.hostPlatform // {
            isLinux = isLinux;
            isDarwin = isDarwin;
          };
        };
      };
    in
    (hmLib.evalModules {
      modules = [
        stubOptions
        weztermModule
        {
          home.username = username;
          home.homeDirectory = homeDirectory;
        }
      ] ++ lib.optionals wslHost [
        wslWeztermModule
        wslWindowsUserModule
      ];
      specialArgs.pkgs = mockPkgs;
    }).config;

  # Test helper: Extract Lua config from module evaluation
  extractLuaConfig = moduleResult: moduleResult.programs.wezterm.extraConfig;

  # Test helper: Extract the copy-to-Windows activation entry, or null
  extractCopyActivation = moduleResult: moduleResult.home.activation.copyWeztermToWindows or null;

  # Test helper: Extract the Windows-profile resolver activation entry, or null
  extractResolveActivation = moduleResult: moduleResult.home.activation.resolveWindowsUser or null;

  # Test helper: Everything before the shared body, where a host fragment such
  # as the WSL one (mkOrder 600) lands.
  extractPreamble = luaConfig: builtins.head (lib.splitString "-- Auto-discover" luaConfig);

  # Test helper: Validate Lua syntax using lua interpreter
  validateLuaSyntax =
    luaCode:
    let
      luaFile = pkgs.writeText "wezterm-test.lua" luaCode;
    in
    pkgs.runCommand "validate-lua-syntax" { buildInputs = [ pkgs.lua ]; } ''
      if ! lua_error=$(${pkgs.lua}/bin/lua -e "assert(loadfile('${luaFile}'))" 2>&1); then
        echo "Lua syntax validation failed:"
        echo "----------------------------------------"
        echo "$lua_error"
        echo "----------------------------------------"
        echo ""
        echo "Generated Lua config (first 50 lines):"
        head -n 50 '${luaFile}'
        echo ""
        echo "Full config at: ${luaFile}"
        exit 1
      fi
      touch $out
    '';

  # Test 1: Basic module structure
  test-module-structure = pkgs.runCommand "test-wezterm-module-structure" { } ''
    ${
      if (evaluateModule { }).programs.wezterm.enable then
        "echo 'PASS: Module enables wezterm'"
      else
        "echo 'FAIL: Module does not enable wezterm' && exit 1"
    }
    ${
      if (extractLuaConfig (evaluateModule { })) != "" then
        "echo 'PASS: Module provides extraConfig'"
      else
        "echo 'FAIL: Module missing extraConfig' && exit 1"
    }
    touch $out
  '';

  # Test 2: WSL host configuration (shared module + WSL host module)
  test-linux-config =
    let
      result = evaluateModule {
        username = "linuxuser";
        homeDirectory = "/home/linuxuser";
        isLinux = true;
        isDarwin = false;
        wslHost = true;
      };
      luaConfig = extractLuaConfig result;
      # Everything before the shared body: must carry the WSL fragment. The
      # fragment's checks look only here, because the shared body also has
      # target_triple:find('windows'), wsl.exe, '/home/' and the username.
      preamble = extractPreamble luaConfig;
    in
    pkgs.runCommand "test-wezterm-linux-config" { } ''
      ${
        if
          lib.hasInfix "if wezterm.target_triple:find('windows') then\n  config.default_prog = { 'wsl.exe'" preamble
          && lib.hasInfix "config.default_gui_startup_args = { 'connect', 'wsl' }\nend\n" preamble
        then
          "echo 'PASS: WSL config guards default_prog with target_triple windows check'"
        else
          "echo 'FAIL: WSL config missing target_triple windows guard' && exit 1"
      }
      ${
        if lib.hasInfix "config.default_prog = { 'wsl.exe', '-d', 'NixOS'" preamble then
          "echo 'PASS: WSL config includes default_prog with wsl.exe'"
        else
          "echo 'FAIL: WSL config missing default_prog/wsl.exe' && exit 1"
      }
      ${
        if lib.hasInfix "'--cd', '/home/' .. \"linuxuser\"" preamble then
          "echo 'PASS: WSL config includes correct home directory'"
        else
          "echo 'FAIL: WSL config has wrong home directory' && exit 1"
      }
      ${
        if lib.hasInfix "config.default_gui_startup_args = { 'connect', 'wsl' }" preamble then
          "echo 'PASS: WSL config includes default_gui_startup_args to auto-connect to wsl mux'"
        else
          "echo 'FAIL: WSL config missing default_gui_startup_args for wsl mux auto-connect' && exit 1"
      }
      ${
        if lib.hasPrefix "local config = wezterm.config_builder()" luaConfig then
          "echo 'PASS: WSL config opens with config_builder()'"
        else
          "echo 'FAIL: WSL config does not open with config_builder()' && exit 1"
      }
      ${
        if lib.hasInfix "default_prog" preamble then
          "echo 'PASS: WSL fragment is ordered before the shared body'"
        else
          "echo 'FAIL: WSL fragment is not ordered before the shared body' && exit 1"
      }
      ${
        if lib.hasSuffix "return config\n" luaConfig then
          "echo 'PASS: WSL config ends with return config'"
        else
          "echo 'FAIL: WSL config does not end with return config' && exit 1"
      }
      ${
        if lib.hasInfix "native_macos_fullscreen_mode" luaConfig then
          "echo 'FAIL: WSL config should not include macOS settings' && exit 1"
        else
          "echo 'PASS: WSL config excludes macOS settings'"
      }
      ${
        if lib.hasInfix "ssh_domains" luaConfig then
          "echo 'PASS: WSL config includes ssh_domains'"
        else
          "echo 'FAIL: WSL config missing ssh_domains' && exit 1"
      }
      ${
        if lib.hasInfix "config.ssh_domains = ssh_domains" luaConfig then
          "echo 'PASS: WSL config assigns ssh_domains to config'"
        else
          "echo 'FAIL: WSL config missing config.ssh_domains assignment' && exit 1"
      }
      ${
        if lib.hasInfix "pcall" luaConfig then
          "echo 'PASS: WSL config wraps ssh_domains discovery in pcall'"
        else
          "echo 'FAIL: WSL config missing pcall wrapper for ssh_domains' && exit 1"
      }
      ${
        if lib.hasInfix "tailscale" luaConfig then
          "echo 'PASS: WSL config includes tailscale'"
        else
          "echo 'FAIL: WSL config missing tailscale' && exit 1"
      }
      ${
        if
          lib.hasInfix "tailscale_status_cmd = { 'wsl.exe', '-d', 'NixOS', '--', 'bash', '-lc', 'tailscale status --json' }" luaConfig
        then
          "echo 'PASS: WSL config calls tailscale via wsl.exe on Windows'"
        else
          "echo 'FAIL: WSL config missing wsl.exe tailscale invocation' && exit 1"
      }
      ${
        if lib.hasInfix "local tailscale_status_cmd = { 'tailscale', 'status', '--json' }" luaConfig then
          "echo 'PASS: WSL config runs tailscale from PATH outside Windows'"
        else
          "echo 'FAIL: WSL config should run tailscale from PATH outside Windows' && exit 1"
      }
      touch $out
    '';

  # Test 2b: Native Linux configuration (shared module only). The WSL pieces
  # used to be gated on stdenv.isLinux, which would have enabled them on a
  # native NixOS machine; host scoping must keep them out.
  test-native-linux-config =
    let
      result = evaluateModule {
        username = "linuxuser";
        homeDirectory = "/home/linuxuser";
        isLinux = true;
        isDarwin = false;
      };
      luaConfig = extractLuaConfig result;
    in
    pkgs.runCommand "test-wezterm-native-linux-config" { } ''
      ${
        if lib.hasInfix "default_prog" luaConfig then
          "echo 'FAIL: native Linux config should not include WSL default_prog' && exit 1"
        else
          "echo 'PASS: native Linux config excludes WSL default_prog'"
      }
      ${
        if lib.hasInfix "default_gui_startup_args" luaConfig then
          "echo 'FAIL: native Linux config should not auto-connect to the wsl mux' && exit 1"
        else
          "echo 'PASS: native Linux config excludes wsl mux auto-connect'"
      }
      ${
        if extractCopyActivation result == null then
          "echo 'PASS: native Linux config excludes Windows copy activation'"
        else
          "echo 'FAIL: native Linux config should not copy config to Windows' && exit 1"
      }
      ${
        if result.systemd.user.services ? wezterm-mux-server then
          "echo 'PASS: native Linux config runs the mux server service'"
        else
          "echo 'FAIL: native Linux config missing mux server service' && exit 1"
      }
      ${
        if lib.hasInfix "ssh_domains" luaConfig then
          "echo 'PASS: native Linux config includes ssh_domains'"
        else
          "echo 'FAIL: native Linux config missing ssh_domains' && exit 1"
      }
      touch $out
    '';

  # Test 3: macOS-specific configuration
  test-macos-config =
    let
      result = evaluateModule {
        username = "macuser";
        homeDirectory = "/Users/macuser";
        isLinux = false;
        isDarwin = true;
      };
      luaConfig = extractLuaConfig result;
    in
    pkgs.runCommand "test-wezterm-macos-config" { } ''
      ${
        if lib.hasInfix "native_macos_fullscreen_mode" luaConfig then
          "echo 'PASS: macOS config includes native_macos_fullscreen_mode'"
        else
          "echo 'FAIL: macOS config missing native_macos_fullscreen_mode' && exit 1"
      }
      ${
        if lib.hasInfix "default_prog" luaConfig then
          "echo 'FAIL: macOS config should not include WSL default_prog' && exit 1"
        else
          "echo 'PASS: macOS config excludes WSL default_prog'"
      }
      ${
        if lib.hasInfix "ssh_domains" luaConfig then
          "echo 'PASS: macOS config includes ssh_domains'"
        else
          "echo 'FAIL: macOS config missing ssh_domains' && exit 1"
      }
      ${
        if lib.hasInfix "pcall" luaConfig then
          "echo 'PASS: macOS config wraps ssh_domains discovery in pcall'"
        else
          "echo 'FAIL: macOS config missing pcall wrapper for ssh_domains' && exit 1"
      }
      ${
        if lib.hasInfix "tailscale" luaConfig then
          "echo 'PASS: macOS config includes tailscale'"
        else
          "echo 'FAIL: macOS config missing tailscale' && exit 1"
      }
      ${
        # A Dock-launched WezTerm.app has launchd's PATH, without nix-darwin's.
        if
          lib.hasInfix "local tailscale_status_cmd = { '/run/current-system/sw/bin/tailscale', 'status', '--json' }" luaConfig
        then
          "echo 'PASS: macOS config runs tailscale from the nix-darwin system profile'"
        else
          "echo 'FAIL: macOS config should run tailscale by its /run/current-system path' && exit 1"
      }
      touch $out
    '';

  # Test 4: Lua syntax validation for all platform/host combinations
  test-lua-syntax-linux =
    let
      luaConfig = extractLuaConfig (evaluateModule {
        isLinux = true;
        isDarwin = false;
        wslHost = true;
      });
    in
    validateLuaSyntax luaConfig;

  test-lua-syntax-native-linux =
    let
      luaConfig = extractLuaConfig (evaluateModule {
        isLinux = true;
        isDarwin = false;
      });
    in
    validateLuaSyntax luaConfig;

  test-lua-syntax-macos =
    let
      luaConfig = extractLuaConfig (evaluateModule {
        isLinux = false;
        isDarwin = true;
      });
    in
    validateLuaSyntax luaConfig;

  test-lua-syntax-generic =
    let
      luaConfig = extractLuaConfig (evaluateModule {
        isLinux = false;
        isDarwin = false;
      });
    in
    validateLuaSyntax luaConfig;

  # Test 5: Username interpolation
  test-username-interpolation =
    let
      testUsernames = [
        "alice"
        "bob-smith"
        "user_123"
      ];
      # Checked in the WSL fragment's --cd path: the shared body carries the
      # username too, so a match anywhere in the config proves nothing about it.
      results = lib.genAttrs testUsernames (
        username:
        let
          luaConfig = extractLuaConfig (evaluateModule {
            username = username;
            isLinux = true;
            wslHost = true;
          });
        in
        lib.hasInfix "'--cd', '/home/' .. ${builtins.toJSON username}" (extractPreamble luaConfig)
      );
    in
    pkgs.runCommand "test-wezterm-username-interpolation" { } ''
      ${lib.concatMapStringsSep "\n" (
        username:
        if results.${username} then
          "echo 'PASS: Username ${username} interpolated correctly'"
        else
          "echo 'FAIL: Username ${username} not found in config' && exit 1"
      ) testUsernames}
      touch $out
    '';

  # Test 6: Username with special characters causing Lua injection
  test-special-chars-username =
    let
      testCases = [
        {
          username = "o'brien";
          description = "single quote";
        }
        {
          username = "user\"name";
          description = "double quote";
        }
        {
          username = "user\\name";
          description = "backslash";
        }
        {
          username = "user]]name";
          description = "bracket close";
        }
        {
          username = "test$user";
          description = "dollar sign";
        }
      ];
      results = map (
        testCase:
        let
          luaConfig = extractLuaConfig (evaluateModule {
            username = testCase.username;
            isLinux = true;
            wslHost = true;
          });
        in
        {
          inherit (testCase) username description;
          configGenerated = luaConfig;
          syntaxValidation = validateLuaSyntax luaConfig;
        }
      ) testCases;
    in
    pkgs.runCommand "test-wezterm-special-chars-username"
      {
        buildInputs = map (r: r.syntaxValidation) results;
      }
      ''
        echo "Testing usernames with special characters"
        ${lib.concatMapStringsSep "\n" (testCase: "echo \"  - ${testCase.description}\"") testCases}
        echo "All special character tests passed (validated Lua syntax)"
        touch $out
      '';

  # Platforms/hosts every config-wide test runs against
  testPlatforms = [
    {
      name = "wsl";
      isLinux = true;
      isDarwin = false;
      wslHost = true;
    }
    {
      name = "linux";
      isLinux = true;
      isDarwin = false;
      wslHost = false;
    }
    {
      name = "macos";
      isLinux = false;
      isDarwin = true;
      wslHost = false;
    }
    {
      name = "generic";
      isLinux = false;
      isDarwin = false;
      wslHost = false;
    }
  ];

  # Test 9: Common configuration present in all platforms
  test-common-config =
    let
      # All platforms should have config_builder
      commonSettings = [
        "config_builder"
        "return config"
        "ssh_domains"
      ];
    in
    pkgs.runCommand "test-wezterm-common-config" { } ''
      ${lib.concatMapStringsSep "\n" (
        platform:
        let
          luaConfig = extractLuaConfig (evaluateModule {
            inherit (platform) isLinux isDarwin wslHost;
          });
        in
        lib.concatMapStringsSep "\n" (
          setting:
          if lib.hasInfix setting luaConfig then
            "echo 'PASS: ${platform.name} config includes ${setting}'"
          else
            "echo 'FAIL: ${platform.name} config missing ${setting}' && exit 1"
        ) commonSettings
      ) testPlatforms}
      touch $out
    '';

  # Test 11: Activation script runtime behavior. wezterm_test.sh runs the real
  # resolveWindowsUser + copyWeztermToWindows text below, as home-manager
  # generates it, against a temp tree standing in for /mnt/c.
  test-activation-script-runtime =
    pkgs.runCommand "test-wezterm-activation-script-runtime"
      {
        buildInputs = [ pkgs.bash ];
      }
      ''
        COPY_SCRIPT=${wslCopyScript} MOCK_HOME=${wslMockConfig.homeDirectory} \
          ${pkgs.bash}/bin/bash ${./wezterm_test.sh}
        touch $out
      '';

  # Test 13: Home Manager integration test — which host gets which pieces
  test-homemanager-integration =
    let
      wslResult = evaluateModule {
        isLinux = true;
        wslHost = true;
      };
      linuxResult = evaluateModule { isLinux = true; };
      macosResult = evaluateModule {
        username = "macuser";
        homeDirectory = "/Users/macuser";
        isLinux = false;
        isDarwin = true;
      };
    in
    pkgs.runCommand "test-homemanager-integration" { } ''
      ${lib.concatMapStringsSep "\n"
        (
          { name, result }:
          if result.programs.wezterm.enable then
            "echo 'PASS: ${name} config evaluates and enables wezterm'"
          else
            "echo 'FAIL: ${name} config evaluation failed or wezterm not enabled' && exit 1"
        )
        [
          {
            name = "WSL";
            result = wslResult;
          }
          {
            name = "native Linux";
            result = linuxResult;
          }
          {
            name = "macOS";
            result = macosResult;
          }
        ]
      }
      ${
        if extractCopyActivation wslResult != null then
          "echo 'PASS: WSL config includes activation script in DAG'"
        else
          "echo 'FAIL: WSL config missing activation script in DAG' && exit 1"
      }
      ${
        if extractResolveActivation wslResult != null then
          "echo 'PASS: WSL config includes the Windows-profile resolver in DAG'"
        else
          "echo 'FAIL: WSL config missing the Windows-profile resolver in DAG' && exit 1"
      }
      ${
        if extractCopyActivation macosResult == null then
          "echo 'PASS: macOS config excludes activation script'"
        else
          "echo 'FAIL: macOS config should not include activation script' && exit 1"
      }
      ${
        if extractResolveActivation linuxResult == null && extractResolveActivation macosResult == null then
          "echo 'PASS: native Linux and macOS configs exclude the Windows-profile resolver'"
        else
          "echo 'FAIL: only the WSL host should resolve a Windows profile' && exit 1"
      }
      ${
        if wslResult.systemd.user.services ? wezterm-mux-server then
          "echo 'PASS: WSL config runs the mux server service'"
        else
          "echo 'FAIL: WSL config missing mux server service' && exit 1"
      }
      ${
        if macosResult.systemd.user.services ? wezterm-mux-server then
          "echo 'FAIL: macOS config should not define a systemd mux service' && exit 1"
        else
          "echo 'PASS: macOS config excludes systemd mux service'"
      }

      echo ""
      echo "Home Manager integration test passed"
      touch $out
    '';

  # The WSL host's copy-to-Windows activation entry, shared by tests 11 and 14.
  wslMockConfig = {
    username = "testuser";
    homeDirectory = "/home/testuser";
  };
  wslResult = evaluateModule (
    wslMockConfig
    // {
      isLinux = true;
      wslHost = true;
    }
  );
  wslDagEntry = extractCopyActivation wslResult;
  wslScriptData = if wslDagEntry != null && wslDagEntry ? data then wslDagEntry.data else null;

  # The copy step as activation runs it: the resolver it is ordered after first,
  # in the same shell, since it reads the WINDOWS_USER the resolver sets.
  wslCopyScript = pkgs.writeText "copy-wezterm-to-windows.sh" ''
    ${(extractResolveActivation wslResult).data}
    ${wslScriptData}
  '';

  # Test 14: Activation script DAG execution and variable access
  test-activation-dag-execution =
    let
      dagEntry = wslDagEntry;
      scriptData = wslScriptData;
    in
    pkgs.runCommand "test-activation-dag-execution" { } ''
      ${
        if dagEntry != null then
          "echo 'PASS: Activation script exists on the WSL host'"
        else
          "echo 'FAIL: Activation script missing on the WSL host' && exit 1"
      }
      ${
        if dagEntry != null && (dagEntry._type or null) == "dagEntryAfter" then
          "echo 'PASS: Activation script is a proper DAG entry (type: dagEntryAfter)'"
        else
          "echo 'FAIL: Activation script is not a proper DAG entry' && exit 1"
      }
      ${
        if dagEntry != null && (builtins.elem "linkGeneration" (dagEntry.after or [ ])) then
          "echo 'PASS: Activation script depends on linkGeneration'"
        else
          "echo 'FAIL: Activation script missing linkGeneration dependency' && exit 1"
      }
      ${
        if dagEntry != null && (builtins.elem "resolveWindowsUser" (dagEntry.after or [ ])) then
          "echo 'PASS: Activation script runs after the Windows-profile resolver'"
        else
          "echo 'FAIL: Activation script missing resolveWindowsUser dependency' && exit 1"
      }
      ${
        if scriptData != null && builtins.isString scriptData then
          "echo 'PASS: Activation script contains shell script data'"
        else
          "echo 'FAIL: Activation script missing or invalid script data' && exit 1"
      }
      ${
        if scriptData != null && lib.hasInfix "DRY_RUN_CMD" scriptData then
          "echo 'PASS: Activation script references DRY_RUN_CMD variable'"
        else
          "echo 'FAIL: Activation script missing DRY_RUN_CMD variable reference' && exit 1"
      }
      ${
        if scriptData != null && lib.hasInfix "VERBOSE_ARG" scriptData then
          "echo 'PASS: Activation script references VERBOSE_ARG variable'"
        else
          "echo 'FAIL: Activation script missing VERBOSE_ARG variable reference' && exit 1"
      }
      ${
        if scriptData != null && lib.hasInfix wslMockConfig.homeDirectory scriptData then
          "echo 'PASS: Activation script uses interpolated homeDirectory value'"
        else
          "echo 'FAIL: Activation script missing homeDirectory value' && exit 1"
      }

      echo ""
      echo "Activation script DAG execution test passed"
      touch $out
    '';

  # Test: format-tab-title event handler
  test-format-tab-title = pkgs.runCommand "test-wezterm-format-tab-title" { } ''
    ${lib.concatMapStringsSep "\n" (
      platform:
      let
        luaConfig = extractLuaConfig (evaluateModule {
          inherit (platform) isLinux isDarwin wslHost;
        });
      in
      ''
        ${
          if lib.hasInfix "format-tab-title" luaConfig then
            "echo 'PASS: ${platform.name} config includes format-tab-title event handler'"
          else
            "echo 'FAIL: ${platform.name} config missing format-tab-title event handler' && exit 1"
        }
        ${
          if lib.hasInfix "user_vars.git_branch" luaConfig then
            "echo 'PASS: ${platform.name} config reads git_branch user variable'"
          else
            "echo 'FAIL: ${platform.name} config missing user_vars.git_branch' && exit 1"
        }
        ${
          if lib.hasInfix " > " luaConfig then
            "echo 'PASS: ${platform.name} config uses branch > title separator'"
          else
            "echo 'FAIL: ${platform.name} config missing branch > title separator' && exit 1"
        }
      ''
    ) testPlatforms}
    touch $out
  '';

  # Aggregate all tests into a test suite
  allTests = [
    test-module-structure
    test-linux-config
    test-native-linux-config
    test-macos-config
    test-lua-syntax-linux
    test-lua-syntax-native-linux
    test-lua-syntax-macos
    test-lua-syntax-generic
    test-username-interpolation
    test-special-chars-username
    test-common-config
    test-activation-script-runtime
    test-homemanager-integration
    test-activation-dag-execution
    test-format-tab-title
  ];

  wezterm-test-suite = pkgs.runCommand "wezterm-test-suite" { buildInputs = allTests; } ''
    echo "WezTerm Module Test Suite"
    echo ""
    ${lib.concatMapStringsSep "\n" (test: "echo \"  ${test.name}\"") allTests}
    echo ""
    echo "All WezTerm tests passed!"
    touch $out
  '';

in
{
  wezterm-tests = {
    inherit
      test-module-structure
      test-linux-config
      test-native-linux-config
      test-macos-config
      test-lua-syntax-linux
      test-lua-syntax-native-linux
      test-lua-syntax-macos
      test-lua-syntax-generic
      test-username-interpolation
      test-special-chars-username
      test-common-config
      test-activation-script-runtime
      test-homemanager-integration
      test-activation-dag-execution
      test-format-tab-title
      ;
  };

  inherit wezterm-test-suite;
}
