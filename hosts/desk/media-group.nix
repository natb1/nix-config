# The `media` group: everyone who searches, downloads and files media on
# desk runs the same tools as themselves, on the same state. Today n8 and
# drlindsey (hosts/desk/drlindsey.nix).
#
# What the group shares, read-write:
#   /srv/media            staging and the library (hosts/desk/media.nix)
#   /var/lib/media-fetch  media-fetch's results and jobs, which its pump
#                         service (hosts/desk/soulseek.nix) serves
#   /var/lib/beets        beets' library database and import log
#                         (hosts/desk/home/beets.nix)
# and, read-only, slskd's API key (/etc/slskd/api.env, 0440 n8:media).
#
# Owners stay what they were — each file is its creator's — and POSIX ACLs
# give the group the rest: `g:media:rwX` on what is there, and a default ACL
# (`d:g:media:rwX`) that every new file and folder inherits, whoever makes
# it and whatever their umask. So the library's "files enter only through
# media-stage" rule is the skill's and media-stage's locks, as it already was
# for n8 on desk; the Mac still sees the library read-only over SMB.
#
# Keeping the ACLs: on a file with an ACL the group mode bits are its mask,
# so anything that sets a mode narrows the group's access. The tools that
# rewrite a file (media-stage's tagging, SQLite's journal) copy the old
# file's mode, mask included, so they keep it; the tmpfiles modes here and in
# media.nix / soulseek.nix are 0775 / 0770 so a boot doesn't take write away.
# What does narrow it — rsync -a of a 0644 source, say — the service below
# fixes at the next boot (or `systemctl restart media-acl`); until then the
# group can still read the file, and move it, which needs only the folder.

{ pkgs, ... }:

let
  shared = [ "/srv/media" "/var/lib/media-fetch" "/var/lib/beets" ];
in
{
  users.groups.media = { };
  users.users.n8.extraGroups = [ "media" ];

  systemd.tmpfiles.rules = [
    "d /var/lib/media-fetch 0770 n8 media -"
    "d /var/lib/beets 0770 n8 media -"
  ];

  # Once: before these were shared they were n8's, in n8's home. Copied only
  # into an empty new directory, and the old one renamed, not deleted, so a
  # rerun does nothing and nothing is lost.
  systemd.services.media-state-move = {
    description = "Move media-fetch's and beets' state out of n8's home";
    after = [ "systemd-tmpfiles-setup.service" ];
    before = [ "media-acl.service" "media-fetch.service" ];
    requiredBy = [ "media-acl.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils ];
    script = ''
      move() {  # move OLD NEW FILE...: FILEs of OLD into NEW, if NEW is empty
        old=$1 new=$2; shift 2
        [ -d "$old" ] && [ -z "$(ls -A "$new")" ] || return 0
        for f in "$@"; do
          if [ -e "$old/$f" ]; then cp -a "$old/$f" "$new/"; fi
        done
        mv "$old" "$old.moved-to-$(basename "$new")"
        echo "moved $old to $new"
      }
      move /home/n8/.local/state/media-fetch /var/lib/media-fetch results jobs
      move /home/n8/.local/share/beets /var/lib/beets library.db import.log
    '';
  };

  systemd.services.media-acl = {
    description = "Give the media group read-write access to the media state";
    after = [ "srv-media.mount" "systemd-tmpfiles-setup.service" ];
    requires = [ "srv-media.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.acl}/bin/setfacl -R -m g:media:rwX,d:g:media:rwX ${toString shared}
    '';
  };
}
