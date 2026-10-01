# Kavita: books/ and rpg/ as a reading server.
#
# EPUB and PDF (and CBZ) in a web reader that keeps each book's place, for
# every device on the tailnet, without mounting SMB. It also serves OPDS, so
# e-reader apps (KOReader, and on the iPhone Panels or Chunky) can browse and
# download from it: the OPDS URL is per user, under the user's settings,
# "3rd Party Clients". Since 0.8.7 KOReader can also sync reading progress
# with it both ways (KOReader's progress sync, pointed at Kavita).
#
# Libraries, as set up from http://desk:5000 after the first login (they are
# Kavita's database, not this file), both of type "Book":
#   Books   /srv/media/books   (books/<author>/<series>/<title>.<ext>)
#   RPG     /srv/media/rpg     (rpg/<game or line>/<title> (<variant>).<ext>),
#           with the exclude pattern **/extras/* (library settings), which
#           leaves out each game's extras/: what Kavita can't show
# Each folder above is one Kavita series: media-stage writes the series,
# volume and title into every file, since Kavita takes them from a file's
# metadata (docs/desktop-migration.md, "Books and RPGs in Kavita").
# Kavita reads, never writes: covers and progress stay in /var/lib/kavita.
# Both libraries watch their folders, but the watcher scans only minutes
# after a change, so media-stage asks for a scan as soon as it has filed,
# with the admin's auth key in /etc/kavita/api-key (below).
#
# Tailnet and home Wi-Fi, unlike Navidrome and Jellyfin, which are
# tailnet-only. It listens on every interface; tailscale0 is trusted
# (modules/nixos/tailscale.nix), and port 5000 alone is opened on wlp14s0 for
# the Kobo, which cannot join the tailnet. From the LAN it is
# http://<desk's LAN address>:5000: the Kobo cannot resolve MagicDNS's
# "desk", so it uses a fixed address. The T-Mobile gateway has no DHCP
# reservations, so that is a second address, 192.168.12.250, added by hand to
# the Wi-Fi's NetworkManager profile beside the DHCP one (README, "Kobo
# (once)"). Anyone on the Wi-Fi reaches Kavita's login page. Beyond it, the
# LAN reaches only what is open on every interface: mDNS (5353/udp, avahi's)
# and Tailscale's WireGuard port (41641/udp). SSH is tailnet-only
# (default.nix).
#
# Not managed by this repo: Kavita's accounts and libraries. The first visit
# to http://desk:5000 creates the admin. State is in /var/lib/kavita
# (accounts, libraries, reading progress). The token key below is state too,
# but a disposable one: it only signs logins. And /etc/kavita/api-key, written
# by hand (README, step 4): the admin's auth key, the one the OPDS URL in
# Kavita's user settings ends in, on one line. One key for everyone who
# files: the media group reads it (hosts/desk/media-group.nix), as it does
# slskd's and itch.io's, and with it is the admin to Kavita.

{ pkgs, ... }:

let
  tokenKeyFile = "/etc/kavita/token-key";
  apiKeyFile = "/etc/kavita/api-key";
in
{
  services.kavita = {
    enable = true;
    inherit tokenKeyFile;
    settings.Port = 5000;
  };

  # The key Kavita signs its logins with. Made on the first start rather than
  # hand-provisioned: nothing else needs it, and losing it only logs everyone
  # out. Root's; the unit reads it through LoadCredential.
  systemd.services.kavita-token-key = {
    description = "Generate Kavita's token key";
    before = [ "kavita.service" ];
    requiredBy = [ "kavita.service" ];
    unitConfig.ConditionPathExists = "!${tokenKeyFile}";
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.coreutils}/bin/install -d -m 0755 "$(dirname ${tokenKeyFile})"
      umask 077
      ${pkgs.coreutils}/bin/head -c 64 /dev/urandom \
        | ${pkgs.coreutils}/bin/base64 --wrap=0 > ${tokenKeyFile}
    '';
  };

  # The same footgun as the other servers: without the bulk SSD, Kavita
  # would scan empty folders and drop every book, reading progress with it.
  systemd.services.kavita = {
    after = [ "srv-media.mount" ];
    requires = [ "srv-media.mount" ];
  };

  # The Kobo's way in; see the header.
  networking.firewall.interfaces.wlp14s0.allowedTCPPorts = [ 5000 ];

  systemd.tmpfiles.rules = [
    # Traversable, so the media group can reach api-key; token-key stays 0600
    # root. `d` also fixes the mode of a directory that already exists.
    "d /etc/kavita 0755 root root -"
    "z ${apiKeyFile} 0440 n8 media -"
    # A library needs its folder to exist; media-stage would otherwise create
    # them only on the first batch that files there.
    # 0775, not 0755: the group bits are the media group's ACL mask
    # (hosts/desk/media-group.nix), and `d` reapplies the mode on every
    # switch, so 0755 took the group's write away. Only the ACL's media
    # entry gains it; the owning group's own entry stays r-x.
    "d /srv/media/books 0775 n8 users -"
    "d /srv/media/rpg 0775 n8 users -"
  ];
}
