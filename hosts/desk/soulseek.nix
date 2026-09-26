# slskd: a Soulseek client for finding music (and books) to file.
#
# Headless, with a web UI at http://desk:5030 for searching and picking by
# hand, and an HTTP API (same port, /api/v0, X-API-Key header) that
# media-fetch (pkgs/media-fetch) drives: its slskd backend, behind an
# interface that names no network, is what an agent uses. One client, one
# login: Soulseek disconnects the older session when an account logs in
# twice, so a second client (Nicotine+, sldl) on the same account would
# fight this one. Use media-fetch instead.
#
# Downloads land in /srv/media/staging/soulseek, not the library, one
# folder per media-fetch job. The media-fetch service below (`media-fetch
# pump`) asks each source for one file at a time, as earlier ones finish, and
# moves each finished job into its staging/<batch>, which is then filed like
# any other (media-share skill). One file at a time: six albums queued at
# once from one peer were all refused, "Overwhelmed with requests".
# slskd runs as n8, like the Samba shares' `force user`, so media-fetch can
# move what it downloaded; the module's sandbox still limits it to its state, the two
# directories below (read-write) and the share (read-only).
#
# Shares music/, read-only. Soulseek expects a share back, and many peers
# refuse users who share nothing. music/ is beets-tagged and nothing in it is
# private. Uploads are capped so a busy peer cannot saturate the Wi-Fi.
#
# The web UI and API are tailnet-only, like the other servers: the firewall
# opens nothing for 5030, and tailscale0 is trusted
# (modules/nixos/tailscale.nix). The Soulseek listen port is not opened:
# desk is on T-Mobile Home Internet, behind carrier-grade NAT, so no router
# forward can reach it. slskd still works, only with the peers that can be
# reached. A VPN with a forwarded port fixes that and hides the home IP from
# peers (docs/desktop-migration.md, "Finding music: Soulseek").
#
# Not managed by this repo: /etc/slskd/credentials (root, 0600), the
# Soulseek account and the web UI's login:
#   SLSKD_SLSK_USERNAME=…   SLSKD_SLSK_PASSWORD=…
#   SLSKD_USERNAME=…        SLSKD_PASSWORD=…
# The API key, /etc/slskd/api.env, is generated on first start, like
# Kavita's token key; deleting it and restarting slskd makes a new one.
# State is in /var/lib/slskd (search and transfer history, disposable).

{ lib, pkgs, ... }:

let
  credentials = "/etc/slskd/credentials";
  apiEnv = "/etc/slskd/api.env";
  downloads = "/srv/media/staging/soulseek";
  media-fetch = pkgs.callPackage ../../pkgs/media-fetch { stateDir = "/var/lib/media-fetch"; };
in
{
  services.slskd = {
    enable = true;
    user = "n8";
    group = "users";
    environmentFile = credentials;
    settings = {
      directories = {
        inherit downloads;
        # On the bulk SSD beside the downloads, so finishing a file is a
        # rename, and a stalled album cannot fill the root disk.
        incomplete = "/srv/media/staging/.soulseek-incomplete";
      };
      shares = {
        directories = [ "/srv/media/music" ];
        filters = [ "\\.DS_Store$" "/\\._" "\\.ini$" "Thumbs\\.db$" ];
      };
      soulseek.description = "desk";
      transfers.upload = {
        slots = 3;
        speed_limit = 2048; # KiB/s
      };
    };
  };

  # Two environment files: the hand-provisioned login and the generated API
  # key. The module takes one; systemd takes a list.
  systemd.services.slskd = {
    after = [ "srv-media.mount" ];
    # Without the bulk SSD, slskd would download onto the root filesystem
    # and share an empty music/.
    requires = [ "srv-media.mount" ];
    serviceConfig.EnvironmentFile = lib.mkForce [ credentials apiEnv ];
  };

  # Readable by the media group (hosts/desk/media-group.nix) so an agent on
  # desk (or over ssh desk) can call the API.
  # Root writes it; slskd reads it through systemd, not itself.
  systemd.services.slskd-api-key = {
    description = "Generate slskd's API key";
    before = [ "slskd.service" ];
    requiredBy = [ "slskd.service" ];
    unitConfig.ConditionPathExists = "!${apiEnv}";
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.coreutils}/bin/install -d -m 0755 "$(dirname ${apiEnv})"
      umask 077
      key=$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 --wrap=0 | ${pkgs.coreutils}/bin/tr '+/' '-_' | ${pkgs.coreutils}/bin/tr -d =)
      echo "SLSKD_API_KEY=$key" > ${apiEnv}
      chown n8:media ${apiEnv}
      chmod 0440 ${apiEnv}
    '';
  };

  # media-fetch's scheduler, so a download moves with no `media-fetch`
  # command running. As n8, on the media group's shared state (the package's
  # stateDir, /var/lib/media-fetch): the jobs any agent starts with `get` are
  # the ones it serves. A loop, not a timer, so the journal gets a line only
  # when a job is delivered or a round fails.
  systemd.services.media-fetch = {
    description = "media-fetch: ask sources for queued files, deliver finished downloads";
    wantedBy = [ "multi-user.target" ];
    requires = [ "slskd.service" ];
    after = [ "slskd.service" ];
    serviceConfig = {
      User = "n8";
      Group = "users";
      ExecStart = "${media-fetch}/bin/media-fetch pump --every 15";
      Restart = "always";
      RestartSec = 30;
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };

  systemd.tmpfiles.rules = [
    # Traversable, so n8 can reach api.env; credentials stays 0600 root.
    # `d` also fixes the mode of a directory that already exists; 0775 so
    # it keeps the media group's ACL mask (hosts/desk/media-group.nix).
    "d /etc/slskd 0755 root root -"
    "d ${downloads} 0775 n8 users -"
    "d /srv/media/staging/.soulseek-incomplete 0775 n8 users -"
    # A key generated before the media group was n8's alone.
    "z ${apiEnv} 0440 n8 media -"
  ];
}
