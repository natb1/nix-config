# The desktop session — user half. The system half is ../desktop.nix.
#
# waybar, swaync, fuzzel and swayidle, plus the shell hook that starts niri.
# docs/desktop-migration.md, "The desktop session", is the design.

{ pkgs, lib, ... }:

{
  # Start niri from the login shell on tty1 only. SSH logins and tty2 get a
  # plain shell, which is what makes a broken session recoverable: niri
  # crashing drops tty1 to a prompt rather than to nothing, and the Mac can
  # still ssh in (its key is in modules/home/default.nix).
  #
  # The WAYLAND_DISPLAY guard stops a nested re-exec if a terminal inside the
  # session ever sources the profile again.
  programs.zsh.profileExtra = ''
    if [ -z "$WAYLAND_DISPLAY" ] && [ "$XDG_VTNR" = 1 ]; then
      exec niri-session
    fi
  '';

  xdg.configFile."niri/config.kdl".source = ./niri.kdl;

  programs.waybar = {
    enable = true;
    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 30;
      modules-left = [ "niri/workspaces" ];
      modules-center = [ "clock" ];
      modules-right = [ "tray" "pulseaudio" "network" "cpu" "memory" ];

      clock.format = "{:%a %d %b  %H:%M}";
      cpu.format = "cpu {usage}%";
      memory.format = "mem {percentage}%";
      # wlp14s0 is the only link — the I225-V port is not cabled. See the
      # Phase 0 Linux-side table.
      network = {
        format-wifi = "{essid} {signalStrength}%";
        format-disconnected = "offline";
      };
      pulseaudio = {
        format = "vol {volume}%";
        format-muted = "muted";
        on-click = "pwvucontrol";
      };
      tray.spacing = 8;
    };
  };

  # Notifications, with a history panel and do-not-disturb. The panel is what
  # matters once the phone starts forwarding everything over ANCS — a stream
  # of transient pop-ups with no backlog would be useless.
  services.swaync.enable = true;

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
      # Until it passes, screens off is the whole idle behaviour — a desktop
      # that will not wake is worse than one that never sleeps, and this box
      # is also a server.
    ];
  };
}
