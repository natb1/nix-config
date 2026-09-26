# Kavita: books/ and rpg/ as a reading server.
#
# EPUB and PDF (and CBZ) in a web reader that keeps each book's place, for
# every device on the tailnet, without mounting SMB. It also serves OPDS, so
# e-reader apps (KOReader, and on the iPhone Panels or Chunky) can browse and
# download from it: the OPDS URL is per user, under the user's settings,
# "3rd Party Clients".
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
# Tailnet-only, like Navidrome and Jellyfin: it listens on every interface,
# the firewall opens nothing for it, and tailscale0 is trusted
# (modules/nixos/tailscale.nix).
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

  # A library needs its folder to exist; media-stage would otherwise create
  # them only on the first batch that files there.
  systemd.tmpfiles.rules = [
    "d /srv/media/books 0755 n8 users -"
    "d /srv/media/rpg 0755 n8 users -"
  ];
}
