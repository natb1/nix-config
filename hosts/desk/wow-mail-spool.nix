# The WoW desk refresh's mail spool: a Deal email the fast path wrote, sent
# within seconds by root, with no Claude session in between.
#
# n8's desk refresh (home/wow-desk-refresh.nix) runs wow-plan's
# `desk_refresh.py fast` on each new auction snapshot. When the spool
# directory below exists, `fast` writes a due Deal email there as an RFC 822
# file (To, Subject, Date, Message-ID, body; atomically: a hidden temp file,
# then a rename to <UTC time>-deal.eml) instead of starting a session to send
# it. Sending needs root, since msmtp's app password (mail.nix) is root-only
# and sessions get no sudo; so this unit, not the user's, sends it.
#
# The spool is ~/.local/state/wow-desk-refresh/mail-spool, made here by
# tmpfiles, 0700 n8: n8 writes, root reads, nobody else sees the mail.
# Creating it is what turns the spool on (`fast` uses it only when it
# exists), so the sender and the spool arrive in the same switch.
#
# ── What happens to a file ────────────────────────────────────────────────────
#
# Every ready file leaves the spool on its first try, and none is deleted:
# - sent/ (kept 30 days): msmtp took it;
# - failed/: msmtp refused it, the recipient file is missing, or the file
#   waited over 90 seconds (the sender was not running), so it is never sent
#   late, after the refresh has given up on it;
# - rejected/: addressed to anyone else, or not a plain file (see below).
# wow-plan counts a spooled email as sent only once it is in sent/ (n8 can
# read it there: the spool and its subdirectories are n8's). Failed or
# rejected, or still in the spool after 3 minutes, its deal stays due and the
# full refresh's own email (Gmail, from the session) sends it. So a broken
# sender costs minutes, never a deal; and `fast` stops using the spool while
# its last file is in failed/ or rejected/ or a file has waited 3 minutes.
#
# ── Who it mails ──────────────────────────────────────────────────────────────
#
# The spool is n8-writable, so anything running as n8 (the unattended session
# included) could drop a file in it. So root never takes a file's word for its
# recipients: it sends only to the one address in /etc/wow-mail-spool/recipient
# (root 0600, made by hand, not in this public repo: the same line as the
# desk refresh's own recipient file), with that address on msmtp's command
# line, not `-t`. A file whose To is any other address, or that has a Cc or
# Bcc, moves to rejected/ and is logged. Root follows no link: a link in the
# spool is moved (the link itself) to rejected/, and a spool or subdirectory
# that is a link stops the sender.
#
# ── When it runs ──────────────────────────────────────────────────────────────
#
# wow-mail-spool.path fires while a ready file (a name not starting with a
# dot, ending .eml) is in the spool; the writer's hidden temp file does not
# count, and the path is checked again whenever the service ends, so a file
# that landed during a run starts another. The service also lists once more a
# second after it finds nothing new. The 5-minute timer is the backstop; a run
# with nothing ready does nothing and exits 0.
#
# Failures: `journalctl -u wow-mail-spool`, plus a desktop pop-up when n8 is
# logged in (as media.nix's alerts). The unit fails when any file failed.
#
# Nothing about the plan (its gold, prices, items or the recipient) is in
# this file; the mail lives only in the spool.

{ config, lib, pkgs, ... }:

let
  user = "n8";
  group = config.users.users.${user}.group;
  home = config.users.users.${user}.home;
  spool = "${home}/.local/state/wow-desk-refresh/mail-spool";
  recipientFile = "/etc/wow-mail-spool/recipient";

  send = pkgs.callPackage ./wow-mail-spool-send.nix { inherit spool recipientFile user group; };
in
{
  systemd.tmpfiles.rules = [
    "d ${spool} 0700 ${user} ${group} -"
    "d ${spool}/sent 0700 ${user} ${group} 30d"
    "d ${spool}/rejected 0700 ${user} ${group} -"
    "d ${spool}/failed 0700 ${user} ${group} -"
  ];

  systemd.services.wow-mail-spool = {
    description = "Send the WoW desk refresh's spooled Deal emails";
    after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = [ home ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${send}/bin/wow-mail-spool-send";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ spool ];
      TimeoutStartSec = "15min";
    };
  };

  systemd.paths.wow-mail-spool = {
    description = "Watch the WoW desk refresh's mail spool";
    wantedBy = [ "paths.target" ];
    pathConfig = {
      PathExistsGlob = "${spool}/[!.]*.eml";
      Unit = "wow-mail-spool.service";
    };
  };

  systemd.timers.wow-mail-spool = {
    description = "Retry the WoW desk refresh's mail spool";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitInactiveSec = "5min";
    };
  };
}
