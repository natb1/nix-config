# The desktop session — system half. The user half is home/desktop.nix.
#
# niri, assembled a la carte: no prebuilt shell, no display manager, no screen
# locker. Decided 2026-09-23; the reasoning is in docs/desktop-migration.md,
# "The desktop session".
#
# Host-scoped rather than in modules/nixos/, per the README's rule: a module
# lives in modules/ only if it evaluates correctly on every host, and
# modules/nixos/ is imported unconditionally by the WSL box, which wants none
# of this. Promote it the day a second machine does.

{ pkgs, ... }:

{
  # The compositor. nixpkgs' module is enough — no new flake input — and it
  # wires the xdg portals (gnome + gtk) that screen sharing and file pickers
  # need.
  programs.niri.enable = true;

  # Autologin on tty1, and no screen lock anywhere. The security story is not
  # "the session is locked"; it is that anything sensitive sits behind its own
  # encryption — gnome-keyring below, holding Chrome's secrets under a
  # password of its own.
  #
  # autologinOnce confines it to the first login of each boot: log out and you
  # get a login prompt rather than an immediate re-login loop.
  services.getty.autologinUser = "n8";
  services.getty.autologinOnce = true;

  # Secret Service, which is what Chrome and most apps expect. Autologin has no
  # password to unlock it with, so it starts locked and asks for its own
  # password on first use each boot. That is the intended behaviour, not a
  # misconfiguration.
  services.gnome.gnome-keyring.enable = true;

  # Audio. PipeWire replaces PulseAudio wholesale; the compat shim keeps
  # PulseAudio clients working.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Fonts. Without this a fresh install renders boxes in waybar and the
  # terminal, which reads as a broken session rather than a missing package.
  fonts = {
    enableDefaultPackages = true;
    packages = with pkgs; [
      noto-fonts
      noto-fonts-color-emoji
      nerd-fonts.jetbrains-mono
    ];
  };

  environment.systemPackages = with pkgs; [
    # niri has no built-in Xwayland; it starts this on demand. Steam needs it.
    xwayland-satellite
    fuzzel
    wl-clipboard
    pwvucontrol

    # notify-send. swaync is the daemon, but nothing shipped the client, so
    # the plan's own `notify-send test` was an unrunnable check until
    # 2026-09-24 — and any script wanting to reach the desktop had no way to.
    libnotify

    # Chrome must be told where the keyring is. It picks its password store by
    # guessing the desktop from XDG_CURRENT_DESKTOP, does not recognise
    # "niri", and falls back to `basic` — which keeps saved passwords and
    # cookie keys on disk under a hard-coded key. That would quietly defeat
    # the secondary encryption this no-lock setup depends on.
    (google-chrome.override {
      commandLineArgs = "--password-store=gnome-libsecret";
    })
  ];

  # google-chrome is unfree, and it is allowed by name in flake.nix's
  # unfreePredicate — not here. nixpkgs.config is defined once, by the flake's
  # `home` helper, so a second definition in this file conflicts with that one
  # rather than adding to it.
}
