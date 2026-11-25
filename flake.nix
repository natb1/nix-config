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
    # hosts/desk/iphone.nix. Pinned to a rev in the URL, so the daily
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
      # google-chrome is desk's browser (hosts/desk/desktop.nix). Add names
      # here, not as a second allowUnfreePredicate in a host module: that
      # raises no error. nixpkgs.config definitions merge with recursiveUpdate,
      # so one predicate silently replaces the other, by module order, and the
      # losing side's packages fail with "has an unfree license". (A host that
      # wants its own names can set nixpkgs.config.allowUnfreePackages, a list
      # that does merge across modules and is ORed with this predicate.)
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

      # The platforms this repo actually targets: the WSL box and desk, the
      # native NixOS desktop (x86_64-linux), and the Apple Silicon Mac
      # (aarch64-darwin).
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
            extraModules = [
              ./hosts/mba/home.nix
              ./modules/home/claude-remote-control.nix
            ];
          })
        ];
      };

      packages = forAllSystems ({ pkgs, ... }: {
        # Media filing for /srv/media (docs/desktop-migration.md, "Layout on
        # the share"); `nix run .#media-stage -- --help`.
        media-stage = pkgs.callPackage ./pkgs/media-stage { };
        # Search and download into a staging batch; `nix run .#media-fetch -- --help`.
        media-fetch = pkgs.callPackage ./pkgs/media-fetch { };
        # The music server's playlists; `nix run .#media-playlist -- --help`.
        media-playlist = pkgs.callPackage ./pkgs/media-playlist { };
      });

      # Module regression tests. `nix flake check` is the gate before a switch.
      checks = forAllSystems ({ pkgs, ... }:
        let
          claudeDaemonTests = pkgs.callPackage ./tests/claude-daemon.test.nix { };
        in
        {
          claude-daemon-test-suite = claudeDaemonTests.claude-daemon-test-suite;
          # Its unit and pipeline tests run in the build.
          media-stage = pkgs.callPackage ./pkgs/media-stage { };
          media-fetch = pkgs.callPackage ./pkgs/media-fetch { };
          media-playlist = pkgs.callPackage ./pkgs/media-playlist { };
        }
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
          # desk's claude-remote-control units, every user's and every repo's.
          # Sessions get no root (see the module's "No root from a session"):
          # NoNewPrivileges must be set and PATH must leave out
          # /run/wrappers/bin. A store path in PATH would change the
          # unit on unrelated switches and restart rc, killing its sessions.
          # With stdout sent to null, stderr must name the journal, or it
          # follows stdout and rc's startup errors are lost too.
          claude-remote-control-unit =
            let
              lib = nixpkgs.lib;
              # "<user>/<unit>" for every claude-remote-control[-<name>] unit.
              units = lib.concatMapAttrs (user: u:
                lib.mapAttrs' (n: s: lib.nameValuePair "${user}/${n}" s)
                  (lib.filterAttrs (n: _: lib.hasPrefix "claude-remote-control" n)
                    u.systemd.user.services))
                self.nixosConfigurations.desk.config.home-manager.users;
              problems = lib.concatLists (lib.mapAttrsToList (user: s:
                let
                  env = lib.toList (s.Service.Environment or [ ]);
                  path = lib.findFirst (lib.hasPrefix "PATH=") "" env;
                in
                lib.optional ((s.Service.NoNewPrivileges or false) != true)
                  "${user}: NoNewPrivileges is not set"
                ++ lib.optional (lib.hasInfix "/run/wrappers" path)
                  "${user}: PATH has /run/wrappers: ${path}"
                ++ lib.optional (lib.hasInfix "/nix/store/" path)
                  "${user}: PATH has a store path: ${path}"
                ++ lib.optional ((s.Service.StandardOutput or null) == "null"
                  && (s.Service.StandardError or null) != "journal")
                  "${user}: StandardOutput is null but StandardError is not journal"
              ) units);
            in
            pkgs.runCommand "claude-remote-control-unit" { } ''
              ${lib.optionalString (units == { }) ''
                echo "no claude-remote-control unit on desk" >&2
                exit 1
              ''}
              ${lib.optionalString (problems != [ ]) ''
                printf '%s\n' ${lib.escapeShellArgs problems} >&2
                exit 1
              ''}
              echo "checked: ${lib.concatStringsSep " " (lib.attrNames units)}"
              touch "$out"
            '';
          # desk's WoW desk refresh (hosts/desk/home/wow-desk-refresh.nix):
          # an unattended Claude session, so it must never prompt, never skip
          # permission checks, load no user or repo settings, and get no
          # root, like the rc units. Checked on the rendered unit files, the
          # built script and the settings it passes, not on the .nix source.
          wow-desk-refresh-unit =
            let
              lib = nixpkgs.lib;
              hm = self.nixosConfigurations.desk.config.home-manager.users.n8;
              unit = n: hm.xdg.configFile."systemd/user/${n}".source;
              script = lib.head (lib.splitString " " (lib.head (lib.toList
                hm.systemd.user.services.wow-desk-refresh.Service.ExecStart)));
            in
            pkgs.runCommand "wow-desk-refresh-unit" { nativeBuildInputs = [ pkgs.jq ]; } ''
              fail() { echo "wow-desk-refresh: $*" >&2; exit 1; }
              svc=${unit "wow-desk-refresh.service"}
              timer=${unit "wow-desk-refresh.timer"}
              grep -qx 'NoNewPrivileges=true' "$svc" || fail "NoNewPrivileges is not set"
              grep '^Environment=PATH=' "$svc" | grep -q /run/wrappers && fail "PATH has /run/wrappers"
              grep -qx 'OnCalendar=\*-\*-\* \*:50:00' "$timer" || fail "the fallback timer is not at :50"
              grep -qx 'Persistent=true' "$timer" || fail "the fallback timer is not Persistent"
              grep -q '^PathChanged=.*/%I/SavedVariables/ForeverPlanLog.lua$' ${unit "wow-desk-refresh-sv@.path"} ||
                fail "no per-account path template"
              grep -q '^PathChanged=.*/\.local/state/wow-desk-refresh/snapshot$' ${unit "wow-desk-refresh-snapshot.path"} ||
                fail "the snapshot stamp does not trigger the refresh"
              grep -qx 'NoNewPrivileges=true' ${unit "wow-desk-refresh-snapshot.service"} || fail "the snapshot watcher has no NoNewPrivileges"
              grep -q 'state/snapshot' ${script} || fail "the snapshot stamp is not in the hashes"
              grep -q 'state/retry' ${script} || fail "the script does not go again on a retry"
              # The fast path: desk_refresh.py fast before the full session,
              # and its steps' session; on unless the unit says --no-fast.
              grep -qF 'python3 -I forever/t52p/desk_refresh.py fast' ${script} || fail "the script has no fast path"
              grep -qF 'desk refresh fast steps v1' ${script} || fail "the fast path does not check for its steps marker"
              grep -qF 'state/fast/steps.txt' ${script} || fail "the fast path's session is not started from fast/steps.txt"
              grep -q '^ExecStart=.*--no-fast' "$svc" && fail "the fast path is off"
              grep -qx 'TimeoutStartSec=250min' "$svc" || fail "TimeoutStartSec does not cover the fast path's sessions"

              # The session's command line, from the built script.
              s=${script}
              grep -qi -e dangerously -e bypassPermissions "$s" && fail "the script can skip permission checks"
              args=$(grep '^claude_args=(' "$s") || fail "no claude_args line in $s"
              grep -q '"''${claude_args\[@\]}"' "$s" || fail "the session is not started with claude_args"
              for want in "--bg " "--permission-mode dontAsk " "--setting-sources local " "--settings /nix/store/"; do
                case " ''${args#claude_args=(}" in *" $want"*) ;; *) fail "the session is not started with $want" ;; esac
              done

              # The settings it loads.
              set=$(sed -n "s|.*--settings \(/nix/store/[^ ]*\.json\).*|\1|p" <<<"$args")
              [ -f "$set" ] || fail "no settings file in claude_args"
              jq -e '.disableBypassPermissionsMode == "disable" and .permissions.defaultMode == "dontAsk"' "$set" >/dev/null ||
                fail "bypass mode is not disabled"
              jq -e '.permissions.allow | map(select(startswith("Bash("))) ==
                ["Bash(python3 -I forever/t52p/desk_refresh.py prepare:*)", "Bash(python3 -I forever/t52p/desk_refresh.py run:*)", "Bash(python3 -I forever/t52p/desk_refresh.py done:*)"]' "$set" >/dev/null ||
                fail "Bash is allowed more than the three desk_refresh.py steps"
              jq -e '.permissions.allow | map(select(test("^(Edit|Write)") and (test("wow-desk-refresh/\\*\\*\\)$|worktrees/desk-refresh/\\*\\*\\)$") | not))) == []' "$set" >/dev/null ||
                fail "writes are allowed outside the state dir and the worktree"
              jq -e '.permissions.deny | index("Bash(git:*)") and index("Bash(gh:*)")' "$set" >/dev/null ||
                fail "git and gh are not denied"
              jq -e '.permissions.deny | map(select(test("^(Edit|Write)\\(.*/wow-desk-refresh/mail-spool/\\*\\*\\)$"))) | length == 2' "$set" >/dev/null ||
                fail "the session may write into the mail spool"

              # The hook, run on sample calls.
              hook=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "^(Artifact|Bash)$") | .hooks[0].command' "$set")
              [ -x "$hook" ] || fail "no PreToolUse hook on Artifact and Bash"
              try() { local rc=0; printf '%s' "$2" | "$hook" 2>/dev/null || rc=$?; [ "$rc" = "$1" ] || fail "hook: expected exit $1, got $rc, for $2"; }
              try 0 '{"tool_name":"Bash","tool_input":{"command":"python3 -I forever/t52p/desk_refresh.py prepare"}}'
              try 2 '{"tool_name":"Bash","tool_input":{"command":"python3 -I forever/t52p/desk_refresh.py prepare; ls"}}'
              try 0 '{"tool_name":"Bash","tool_input":{"command":"python3 -I forever/t52p/desk_refresh.py run --out W/out"}}'
              try 0 '{"tool_name":"Bash","tool_input":{"command":"python3 -I forever/t52p/desk_refresh.py done --out W/out"}}'
              try 2 '{"tool_name":"Bash","tool_input":{"command":"git push"}}'
              try 2 '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
              try 2 '{"tool_name":"Bash","tool_input":{"command":"python3 -I forever/t52p/desk_refresh.py run; git push"}}'
              try 2 '{"tool_name":"Bash","tool_input":{"command":"python3 -I forever/t52p/desk_refresh.py run $(git push)"}}'
              try 2 '{"tool_name":"Bash","tool_input":{"command":"python3 -I forever/t52p/desk_refresh.py run\ngit push"}}'
              try 0 '{"tool_name":"Artifact","tool_input":{"url":"u","file_path":"f","asset":true}}'
              try 2 '{"tool_name":"Artifact","tool_input":{"action":"delete","url":"u"}}'
              try 2 '{"tool_name":"Artifact","tool_input":{"action":"delete","url":"u","path":"0123"}}'
              touch "$out"
            '';
          # The refresh script's control flow, run with stub claude and
          # python3 on a scratch repo, worktree and state dir: the fast path
          # runs before any session on a new snapshot, its steps start a
          # desk-refresh-fast session, the full session always follows (also
          # when fast fails), --no-fast skips it, and a snapshot the fast path
          # already ran on does not run it again.
          wow-desk-refresh-flow =
            let
              hm = self.nixosConfigurations.desk.config.home-manager.users.n8;
              script = nixpkgs.lib.head (nixpkgs.lib.splitString " " (nixpkgs.lib.head (nixpkgs.lib.toList
                hm.systemd.user.services.wow-desk-refresh.Service.ExecStart)));
              claudeStub = pkgs.writeShellScriptBin "claude" ''
                set -eu
                case "$*" in
                  "agents --json --all")
                    for f in "$STUB/sessions"/*; do
                      [ -e "$f" ] || continue
                      i=$(basename "$f"); n=$(cat "$f"); echo $((n + 1)) >"$f"
                      if [ "$n" = 0 ]; then st=busy; else st=idle; fi
                      printf '{"id":"%s","sessionId":"%s","status":"%s"}\n' "$i" "$i" "$st"
                    done | ${pkgs.jq}/bin/jq -s .
                    ;;
                  "agents --json") echo "[]" ;;
                  "stop "* | "rm "*) ;;
                  *)
                    name=""; prev=""
                    for a in "$@"; do [ "$prev" = -n ] && name=$a; prev=$a; done
                    k=$(ls "$STUB/sessions" | wc -l); id=$(printf 'a%x' $((k + 10)))
                    echo 0 >"$STUB/sessions/$id"
                    echo "session $name" >>"$STUB/log"
                    mkdir -p "$HOME/.claude/projects/p"
                    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}' >"$HOME/.claude/projects/p/$id.jsonl"
                    echo "backgrounded · $id · $name"
                    ;;
                esac
              '';
              pythonStub = pkgs.writeShellScriptBin "python3" ''
                echo "python3 $*" >>"$STUB/log"
                case "$*" in
                  *"desk_refresh.py fast"*)
                    case "$(cat "$STUB/fast-mode")" in
                      fail) exit 1 ;;
                      steps) mkdir -p "$WOW_DESK_REFRESH_STATE/fast"; echo "send it" >"$WOW_DESK_REFRESH_STATE/fast/steps.txt" ;;
                    esac
                    ;;
                esac
              '';
            in
            pkgs.runCommand "wow-desk-refresh-flow" { nativeBuildInputs = [ pkgs.git ]; } ''
              fail() { echo "wow-desk-refresh flow: $*" >&2; [ -f "$STUB/log" ] && cat "$STUB/log" >&2; exit 1; }
              export HOME=$TMPDIR/home XDG_RUNTIME_DIR=$TMPDIR STUB=$TMPDIR/stub
              export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
              export WOW_DESK_REFRESH_STATE=$TMPDIR/state WOW_DESK_REFRESH_REPO=$TMPDIR/repo WOW_DESK_REFRESH_WORKTREE=$TMPDIR/wt
              mkdir -p "$HOME" "$STUB/sessions" "$TMPDIR/src/forever/t52p" "$WOW_DESK_REFRESH_STATE"
              printf '## The desk refresh
' >"$TMPDIR/src/README.md"
              printf '# desk refresh steps v2
# desk refresh fast steps v1
' >"$TMPDIR/src/forever/t52p/desk_refresh.py"
              git -C "$TMPDIR/src" init -q -b main
              git -C "$TMPDIR/src" add -A
              git -C "$TMPDIR/src" commit -qm src
              git clone -q "$TMPDIR/src" "$WOW_DESK_REFRESH_REPO"
              export PATH=${claudeStub}/bin:${pythonStub}/bin:$PATH
              go() { : >"$STUB/log"; echo "$1" >"$STUB/fast-mode"; shift; ${script} "$@" >"$TMPDIR/out.txt" 2>&1 || fail "the script failed: $(cat "$TMPDIR/out.txt")"; }
              first() { grep -n -m 1 "$1" "$STUB/log" | cut -d: -f1; }

              # A new snapshot, a Deal email due: fast, then its session, then the full session.
              echo one >"$WOW_DESK_REFRESH_STATE/snapshot"
              go steps
              f=$(first 'desk_refresh.py fast') s=$(first '^session ')
              [ -n "$f" ] && [ -n "$s" ] && [ "$f" -lt "$s" ] || fail "fast did not run before the first session"
              [ "$(grep -c '^session ' "$STUB/log")" = 2 ] || fail "not two sessions (fast, then full)"
              grep '^session ' "$STUB/log" | head -1 | grep -q '^session desk-refresh-fast-' || fail "the first session is not the fast one"
              grep '^session ' "$STUB/log" | tail -1 | grep -q '^session desk-refresh-[0-9]' || fail "the full session did not follow"
              [ "$(grep -c 'desk_refresh.py fast' "$STUB/log")" = 1 ] || fail "fast ran more than once for one snapshot"
              [ ! -e "$WOW_DESK_REFRESH_STATE/fast/steps.txt" ] || fail "steps.txt was left behind"

              # Nothing changed: nothing runs.
              go steps
              [ ! -s "$STUB/log" ] || fail "an unchanged source ran something"

              # A new snapshot and a failing fast: the full session still runs.
              echo two >"$WOW_DESK_REFRESH_STATE/snapshot"
              go fail
              grep -q 'desk_refresh.py fast' "$STUB/log" || fail "fast did not run"
              [ "$(grep -c '^session desk-refresh-[0-9]' "$STUB/log")" = 1 ] || fail "a failing fast stopped the full session"

              # --force with the snapshot fast already ran on: no fast, the full session.
              go steps --force
              grep -q 'desk_refresh.py fast' "$STUB/log" && fail "fast ran again for a snapshot it already ran on"
              [ "$(grep -c '^session desk-refresh-[0-9]' "$STUB/log")" = 1 ] || fail "--force ran no full session"

              # --no-fast: a new snapshot, no fast, the full session.
              echo three >"$WOW_DESK_REFRESH_STATE/snapshot"
              go steps --no-fast
              grep -q 'desk_refresh.py fast' "$STUB/log" && fail "--no-fast ran fast"
              [ "$(grep -c '^session ' "$STUB/log")" = 1 ] || fail "--no-fast ran no full session"
              touch "$out"
            '';
          # desk's mail spool (hosts/desk/wow-mail-spool.nix): the sender run
          # on a scratch spool, and the system units as rendered: the path
          # unit watches the spool the desk refresh writes, which is n8's and
          # nobody else's, and the sender runs as root (msmtp's password).
          wow-mail-spool-test = pkgs.callPackage ./tests/wow-mail-spool.test.nix { };
          wow-mail-spool-unit =
            let
              lib = nixpkgs.lib;
              c = self.nixosConfigurations.desk.config;
              spool = "${c.users.users.n8.home}/.local/state/wow-desk-refresh/mail-spool";
              unitFile = n: "${c.systemd.units.${n}.unit}/${n}";
              hmSpool = "${c.home-manager.users.n8.xdg.stateHome}/wow-desk-refresh/mail-spool";
            in
            pkgs.runCommand "wow-mail-spool-unit" { } ''
              fail() { echo "wow-mail-spool: $*" >&2; exit 1; }
              [ ${lib.escapeShellArg hmSpool} = ${lib.escapeShellArg spool} ] || fail "the spool is not under the desk refresh's state dir"
              grep -qxF 'PathExistsGlob=${spool}/[!.]*.eml' ${unitFile "wow-mail-spool.path"} || fail "the path unit does not watch the spool's ready files"
              for p in PrivateDevices ProtectKernelTunables ProtectControlGroups NoNewPrivileges; do
                grep -qx "$p=true" ${unitFile "wow-mail-spool.service"} || fail "the sender has no $p"
              done
              grep -qxF 'Unit=wow-mail-spool.service' ${unitFile "wow-mail-spool.path"} || fail "the path unit starts another unit"
              grep -q '^User=' ${unitFile "wow-mail-spool.service"} && fail "the sender does not run as root"
              grep -qx 'ExecStart=/nix/store/[^ ]*/bin/wow-mail-spool-send' ${unitFile "wow-mail-spool.service"} ||
                fail "the sender is started with arguments"
              grep -q '^OnUnitInactiveSec=' ${unitFile "wow-mail-spool.timer"} || fail "no retry timer"
              ${lib.optionalString (!(builtins.elem "d ${spool} 0700 n8 users -" c.systemd.tmpfiles.rules)) ''
                fail "the spool is not made 0700 n8:users by tmpfiles"
              ''}
              ${lib.optionalString (!(builtins.elem "d ${spool}/failed 0700 n8 users -" c.systemd.tmpfiles.rules)) ''
                fail "the spool's failed/ is not made 0700 n8:users, with no cleanup, by tmpfiles"
              ''}
              touch "$out"
            '';
          # Zellij, as desk configures it. The shell integrations must stay
          # off (modules/home/zellij.nix). `setup --check` exits 0 whatever it
          # finds, but the config is loaded first, and a config.kdl that does
          # not parse fails there.
          zellij-config =
            let
              lib = nixpkgs.lib;
              hm = self.nixosConfigurations.desk.config.home-manager.users.n8;
              z = hm.programs.zellij;
              on = builtins.filter (n: z.${n})
                [ "enableZshIntegration" "enableBashIntegration" "enableFishIntegration" ];
            in
            pkgs.runCommand "zellij-config" { } ''
              ${lib.optionalString (on != [ ]) ''
                echo "zellij shell integrations are on: ${toString on}" >&2
                exit 1
              ''}
              export HOME=$TMPDIR
              ${z.package}/bin/zellij \
                --config ${hm.xdg.configFile."zellij/config.kdl".source} setup --check
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
            # An if, not `! grep`: set -e ignores a command negated with `!`,
            # so that form never failed the build. A binding that throws still
            # logs "Configuration Loaded", so this is the line that catches it.
            if grep -E "Failed to load configuration|TypeError|ReferenceError" qs.log; then
              echo "quickshell-config: QML errors in qs.log" >&2
              exit 1
            fi
            touch "$out"
          '';
        }
      );
    };
}
