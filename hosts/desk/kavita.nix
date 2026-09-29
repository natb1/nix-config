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
#   RPG     /srv/media/rpg     (rpg/<game or line>/<title> (<variant>).<ext>)
# Each folder above is one Kavita series: media-stage writes the series,
# volume and title into every file, since Kavita takes them from a file's
# metadata (docs/desktop-migration.md, "Books and RPGs in Kavita").
# Kavita reads, never writes: covers and progress stay in /var/lib/kavita.
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
# LAN reaches only what is open on every interface: SSH (22, keys only;
# openssh's openFirewall default), mDNS (5353/udp, avahi's) and Tailscale's
# WireGuard port (41641/udp).
#
# Not managed by this repo: Kavita's accounts and libraries. The first visit
# to http://desk:5000 creates the admin. State is in /var/lib/kavita
# (accounts, libraries, reading progress). The token key below is state too,
# but a disposable one: it only signs logins.

{ pkgs, ... }:

let
  tokenKeyFile = "/etc/kavita/token-key";
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
      umask 077
      mkdir -p "$(dirname ${tokenKeyFile})"
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

  # A library needs its folder to exist; media-stage would otherwise create
  # them only on the first batch that files there.
  systemd.tmpfiles.rules = [
    # 0775, not 0755: the group bits are the media group's ACL mask
    # (hosts/desk/media-group.nix), and `d` reapplies the mode on every
    # switch, so 0755 took the group's write away. Only the ACL's media
    # entry gains it; the owning group's own entry stays r-x.
    "d /srv/media/books 0775 n8 users -"
    "d /srv/media/rpg 0775 n8 users -"
  ];
}
