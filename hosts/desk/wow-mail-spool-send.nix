# The mail spool's sender (wow-mail-spool.nix): sends each ready file in the
# spool to the recipient file's one address, then moves it to sent/; a file
# addressed elsewhere moves to rejected/; a failure stays for the next try.
{ lib, writeShellApplication, coreutils, gnused, gnugrep, msmtp, util-linux, libnotify
, spool, recipientFile, user, group }:

writeShellApplication {
  name = "wow-mail-spool-send";
  runtimeInputs = [ coreutils gnused gnugrep msmtp util-linux libnotify ];
  text = ''
    # [SPOOL [RECIPIENT FILE]]: the unit passes neither; the flake check
    # runs it on a scratch spool.
    spool=''${1:-${lib.escapeShellArg spool}}
    rcptf=''${2:-${lib.escapeShellArg recipientFile}}

    # A desktop pop-up in n8's session; best effort, as media.nix's alert.
    pop() {
      local uid
      uid=$(id -u ${user} 2>/dev/null) || return 0
      runuser -u ${user} -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        notify-send -u critical -a wow-mail-spool "Deal email not sent" "$1; journalctl -u wow-mail-spool" \
        >/dev/null 2>&1 || true
    }

    [ -d "$spool" ] || { echo "no spool at $spool; nothing to send"; exit 0; }
    if ! [ -s "$rcptf" ]; then
      echo "$rcptf is missing or empty: nothing is sent; the spooled mail stays in $spool" >&2
      pop "the mail spool has no recipient file"
      exit 1
    fi
    to=$(head -n 1 "$rcptf" | tr -d '[:space:]')
    # tmpfiles makes both; this is for a spool made before them.
    for d in sent rejected; do [ -d "$spool/$d" ] || mkdir -m 0700 "$spool/$d"; done
    chown ${user}:${group} "$spool/sent" "$spool/rejected" 2>/dev/null || true

    # The value of a header field (before the first blank line), lowercase.
    header() {
      sed -e 's/\r$//' -e '/^$/q' "$2" | grep -i -m 1 "^$1:" | sed 's/^[^:]*:[ \t]*//' |
        tr '[:upper:]' '[:lower:]' || true
    }

    # Moves a file into a subdirectory, never over an existing one.
    file_to() {
      local dest
      dest="$spool/$1/$(basename "$2")"
      [ -e "$dest" ] && dest="$dest.$(date +%s%N)"
      mv -n "$2" "$dest"
    }

    failed=0 sent=0
    declare -A tried=()
    while :; do
      shopt -s nullglob
      ready=("$spool"/[!.]*.eml)
      shopt -u nullglob
      new=0
      for f in "''${ready[@]}"; do
        if ! [ -f "$f" ] || [ -n "''${tried[$f]:-}" ]; then continue; fi
        tried[$f]=1 new=1
        name=$(basename "$f")
        rcpt=$(header to "$f")
        rcpt=''${rcpt##*<} rcpt=''${rcpt%%>*}
        if [ "$rcpt" != "$(tr '[:upper:]' '[:lower:]' <<<"$to")" ] || [ -n "$(header cc "$f")" ] || [ -n "$(header bcc "$f")" ]; then
          echo "$name: its To is not the recipient file's address, or it has a Cc or Bcc; moved to rejected/" >&2
          file_to rejected "$f"
          failed=1
          pop "$name was rejected"
          continue
        fi
        # LF line endings for msmtp, which writes CRLF itself.
        if out=$(sed 's/\r$//' "$f" | timeout 120 msmtp -- "$to" 2>&1); then
          file_to sent "$f"
          sent=$((sent + 1))
          echo "$name: sent"
        else
          echo "$name: msmtp failed; left in the spool for the next try: $out" >&2
          failed=1
          pop "msmtp failed for $name"
        fi
      done
      [ "$new" = 1 ] || break
    done
    [ "$sent" = 0 ] || echo "sent $sent"
    exit "$failed"
  '';
}
