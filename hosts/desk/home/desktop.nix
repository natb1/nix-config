# The desktop session — user half. The system half is ../desktop.nix.
#
# The Quickshell panel and launcher and swayidle, plus the shell hook that
# starts niri.
# docs/desktop-migration.md, "The desktop session", is the design.

{ pkgs, lib, ... }:

let
  # Built on desk, not in the store (see ./knights-wallpaper.nix). The file
  # name carries the script's store hash, so a changed recipe builds afresh.
  knightsWallpaper = pkgs.callPackage ./knights-wallpaper.nix { };
  wallpaper = "%h/.cache/desk/wallpaper-${
    builtins.substring 11 8 (builtins.unsafeDiscardStringContext "${knightsWallpaper}")
  }.png";
in
{
  # Start niri from the login shell on tty1 only. SSH logins and tty2 get a
  # plain shell, which is what makes a broken session recoverable: niri
  # crashing drops tty1 to a prompt rather than to nothing, and the Mac can
  # still ssh in (its key is in modules/home/default.nix).
  #
  # `-l` is load-bearing. Called with no arguments, niri-session assumes it was
  # started by a display manager and re-execs itself through a *login* shell to
  # pick up the profile — which sources this file again, hits this same block,
  # and execs niri-session with no arguments once more. That is an unbreakable
  # loop: tty1 spins at 50% CPU on a dead login prompt and niri.service is
  # never reached. `-l` says "already a login shell", so niri-session skips the
  # re-exec and goes straight to `systemctl --user start niri.service`.
  #
  # Two guards, because the loop leaves the machine unusable and is awkward to
  # recover from. WAYLAND_DISPLAY stops a terminal *inside* the session from
  # starting a second one; NIRI_SESSION_STARTED survives an exec, so it breaks
  # the loop by itself if niri-session ever stops honouring `-l`.
  programs.zsh.profileExtra = ''
    if [ -z "$WAYLAND_DISPLAY" ] && [ "$XDG_VTNR" = 1 ] && [ -z "$NIRI_SESSION_STARTED" ]; then
      export NIRI_SESSION_STARTED=1
      exec niri-session -l
    fi
  '';

  xdg.configFile."niri/config.kdl".source = ./niri.kdl;

  # The desktop's terminal. WezTerm stays installed (modules/home/wezterm.nix)
  # as the mux client for the WSL box; Ghostty is what opens locally. Its
  # defaults — bundled JetBrains Mono with Nerd Font symbols — need no
  # settings. Which terminal is "the" terminal is decided once, system-side,
  # by xdg-terminal-exec (../desktop.nix); niri's Mod+Return and the
  # launcher's Terminal=true apps both go through it.
  programs.ghostty.enable = true;

  # The desktop shell, one Quickshell config (./quickshell): the wallpaper,
  # notification pop-ups and history, and a panel on Mod+Shift+N with the clock, status
  # (Tailscale, Bluetooth, Wi-Fi, CPU/memory), volume, what is playing and any
  # tray icons. There is no bar. It is also the notification daemon, which
  # the phone relies on once it forwards everything over ANCS — a stream of
  # transient pop-ups with no backlog would be useless.
  #
  # The unit, not a niri spawn-at-startup line, owns it (see niri.kdl).
  programs.quickshell = {
    enable = true;
    configs.desk = ./quickshell;
    activeConfig = "desk";
    systemd.enable = true;
  };
  systemd.user.services.quickshell = {
    Unit = {
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
      # Restart on a config change. That clears the notification history,
      # but a hot reload through the store symlink is not something to rely
      # on.
      X-Restart-Triggers = [ "${./quickshell}" ];
    };
    # Icons named by notifications and tray items (notify-send -i phone)
    # come from a theme, and desk had only hicolor, so most had no icon.
    #
    # The wallpaper is five Mythic Bastionland knights, built before the
    # shell starts. `-`: if it cannot be built (the share is missing), the
    # shell still starts, on a plain background.
    Service.ExecStartPre = "-${lib.getExe knightsWallpaper} ${wallpaper}";
    Service.Environment = [
      "QS_ICON_THEME=Adwaita"
      "DESK_WALLPAPER=${wallpaper}"
    ];
  };
  home.packages = [ pkgs.adwaita-icon-theme ];

  # Dark mode. color-scheme is what the settings portal
  # (xdg-desktop-portal-gnome) reports, which Chrome and libadwaita apps
  # follow; GTK 3 apps read only their theme name, so they get Adwaita-dark.
  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";
  gtk = {
    enable = true;
    theme.name = "Adwaita-dark";
    gtk4.theme = null;
  };

  # A macOS-style cursor. With no theme installed, niri fell back to its
  # built-in one — a single arrow, drawn large, for every context. A full
  # xcursor theme gives the I-beam over text, the hand over links, resize
  # arrows on edges, and so on. home.pointerCursor also points GTK, X11 apps
  # (via xwayland-satellite) and the XCURSOR_* variables at it; niri reads
  # its own copy of the name and size from niri.kdl's cursor block, so keep
  # the two in step.
  home.pointerCursor = {
    package = pkgs.apple-cursor;
    name = "macOS";
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  services.swayidle = {
    enable = true;
    timeouts = [
      {
        timeout = 600;
        command = "${lib.getExe pkgs.niri} msg action power-off-monitors";
      }
      # Suspend is deliberately NOT wired up yet. Wake-on-WLAN cleared its
      # capability check on 2026-09-24 (`iw phy` lists "wake up on magic
      # packet"), but that says the feature exists, not that this card, this
      # firmware and AM5's s2idle resume cleanly together. Phase 8 sets the
      # bar: 10/10 clean suspend/resume cycles and 5/5 magic-packet wakes.
      # And a second gate (2026-09-25): a LAN-side wake relay (the ESP8266)
      # that wakes desk from the phone on cellular, 5/5 — a LAN-only wake
      # strands the share exactly when it is wanted, away from home.
      # Until both pass, screens off is the whole idle behaviour — a desktop
      # that will not wake is worse than one that never sleeps, and this box
      # is also a server.
    ];
  };
}
