# desk's shared printer and media share, as this Mac uses them. The server
# side is hosts/desk/printing.nix and hosts/desk/media.nix; both are
# tailnet-only, so everything here goes through Tailscale (modules/darwin)
# and the MagicDNS short name `desk`.
#
# Not managed here: the Samba password. It lives in the login keychain,
# saved the first time the share is mounted with "Remember this password".

{ pkgs, ... }:

let
  queue = "desk_brother";
  printerUri = "ipp://desk/printers/brother";
in
{
  # The printer queue, re-asserted on every darwin-rebuild switch (as root).
  #
  # From lpadmin, not the Add Printer window: its IP tab never offers
  # "AirPrint" for this queue, even though curl, ipptool and lpadmin all reach
  # it from this Mac (docs/desktop-migration.md, Printer sharing). `-m
  # everywhere` is what that choice does anyway — build the queue from the
  # printer's own IPP attributes — which is why creating it needs desk up.
  # A switch while desk is down (bare-metal Windows) warns rather than fails.
  system.activationScripts.postActivation.text = ''
    if /usr/bin/lpstat -p ${queue} >/dev/null 2>&1; then
      /usr/sbin/lpadmin -p ${queue} -v ${printerUri}
    elif /usr/sbin/lpadmin -p ${queue} -D "Brother (desk)" -L desk -E \
        -v ${printerUri} -m everywhere; then
      echo "added printer ${queue}"
    else
      echo "warning: printer ${queue} not added; is desk up? Switch again when it is." >&2
    fi
  '';

  # smb://desk/media, mounted at login and remounted after sleep or a
  # dropped connection. osascript's `mount volume` is the Finder path, so it
  # finds the password in the login keychain, and asks once if it is not
  # there yet. The port check first keeps a desk that is off (or booted into
  # Windows) from raising a "problem connecting to the server" dialog every
  # five minutes.
  # media-stage, for filing a batch from this Mac (its Downloads, say) into
  # the share: staged under /Volumes/media/staging/, then scanned, drafted,
  # checked and applied in place — docs/desktop-migration.md, "Filing a batch".
  home-manager.users.n8.home.packages = [ (pkgs.callPackage ../../pkgs/media-stage { }) ];

  home-manager.users.n8.launchd.agents.desk-media = {
    enable = true;
    config = {
      ProgramArguments = [
        "/bin/sh"
        "-c"
        ''
          /sbin/mount | /usr/bin/grep -q '@desk/media on ' && exit 0
          /usr/bin/nc -z -G 3 desk 445 >/dev/null 2>&1 || exit 0
          /usr/bin/osascript -e 'mount volume "smb://n8@desk/media"'
        ''
      ];
      RunAtLoad = true;
      StartInterval = 300;
    };
  };
}
