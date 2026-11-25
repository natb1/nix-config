# The mail spool's sender (wow-mail-spool.nix): sends each ready file in the
# spool to the recipient file's one address, then moves it to sent/. Every
# ready file leaves the spool on its first try: a file addressed elsewhere (or
# not a plain file) to rejected/, one msmtp refused, one over 90 seconds old
# or one found with no recipient file to failed/, unsent and never deleted.
# wow-plan counts an email as sent only from sent/, so for any other outcome
# its full run sends the deal by its own email.
{ lib, writeShellApplication, coreutils, gnused, gnugrep, msmtp, util-linux, libnotify
, spool, recipientFile, user, group }:

writeShellApplication {
  name = "wow-mail-spool-send";
  runtimeInputs = [ coreutils gnused gnugrep msmtp util-linux libnotify ];
  text = ''
    # [SPOOL [RECIPIENT FILE [MAX AGE S]]]: the unit passes none; the flake
    # check runs it on a scratch spool.
    spool=''${1:-${lib.escapeShellArg spool}}
    rcptf=''${2:-${lib.escapeShellArg recipientFile}}
    # Older than this and the full run may already count it as not sent
    # (wow-plan's deals_rp.py --spool-grace-min, 3 minutes): never sent late.
    max_age=''${3:-90}

    # A desktop pop-up in n8's session; best effort, as media.nix's alert.
    pop() {
      local uid
      uid=$(id -u ${user} 2>/dev/null) || return 0
      runuser -u ${user} -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        notify-send -u critical -a wow-mail-spool "Deal email not sent by desk" "$1; the next refresh emails it; journalctl -u wow-mail-spool" \
        >/dev/null 2>&1 || true
    }

    [ -e "$spool" ] || { echo "no spool at $spool; nothing to send"; exit 0; }
    # The spool is n8's: root follows no link in it.
    if [ -L "$spool" ] || ! [ -d "$spool" ]; then
      echo "$spool is a link or not a directory; nothing is sent" >&2
      exit 1
    fi
    for d in sent rejected failed; do
      if [ -L "$spool/$d" ]; then
        echo "$spool/$d is a link; nothing is sent" >&2
        pop "the mail spool's $d/ is a link"
        exit 1
      fi
      # tmpfiles makes them; this is for a spool made before them.
      if ! [ -d "$spool/$d" ]; then
        mkdir -m 0700 "$spool/$d"
        chown -h ${user}:${group} "$spool/$d" 2>/dev/null || true
      fi
    done

    # The value of a header field (before the first blank line), lowercase.
    header() {
      sed -e 's/\r$//' -e '/^$/q' "$2" | grep -i -m 1 "^$1:" | sed 's/^[^:]*:[ \t]*//' |
        tr '[:upper:]' '[:lower:]' || true
    }

    # Moves a file (or a link itself, never its target) into a subdirectory,
    # never over an existing one.
    file_to() {
      local dest
      dest="$spool/$1/$(basename "$2")"
      [ -e "$dest" ] || [ -L "$dest" ] && dest="$dest.$(date +%s%N)"
      mv -n -T -- "$2" "$dest" || echo "$(basename "$2"): could not move it to $1/" >&2
    }

    failed=0 sent=0 idle=0
    declare -A tried=()
    while :; do
      shopt -s nullglob
      ready=("$spool"/[!.]*.eml)
      shopt -u nullglob
      new=0
      for f in "''${ready[@]}"; do
        if [ -n "''${tried[$f]:-}" ]; then continue; fi
        tried[$f]=1 new=1
        name=$(basename "$f")
        if [ -L "$f" ] || ! [ -f "$f" ]; then
          echo "$name: a link or not a plain file; moved to rejected/" >&2
          file_to rejected "$f"; failed=1; pop "$name was rejected"
          continue
        fi
        if ! [ -s "$rcptf" ]; then
          echo "$name: $rcptf is missing or empty, so it is not sent; moved to failed/" >&2
          file_to failed "$f"; failed=1; pop "the mail spool has no recipient file"
          continue
        fi
        age=$(( $(date +%s) - $(stat -c %Y -- "$f") ))
        if [ "$age" -gt "$max_age" ]; then
          echo "$name: $age seconds old (over $max_age), too late to send; moved to failed/" >&2
          file_to failed "$f"; failed=1; pop "$name waited too long"
          continue
        fi
        to=$(head -n 1 "$rcptf" | tr -d '[:space:]')
        rcpt=$(header to "$f")
        rcpt=''${rcpt##*<} rcpt=''${rcpt%%>*}
        if [ "$rcpt" != "$(tr '[:upper:]' '[:lower:]' <<<"$to")" ] || [ -n "$(header cc "$f")" ] || [ -n "$(header bcc "$f")" ]; then
          echo "$name: its To is not the recipient file's address, or it has a Cc or Bcc; moved to rejected/" >&2
          file_to rejected "$f"; failed=1; pop "$name was rejected"
          continue
        fi
        # LF line endings for msmtp, which writes CRLF itself.
        if out=$(sed 's/\r$//' "$f" | timeout 60 msmtp -- "$to" 2>&1); then
          file_to sent "$f"
          sent=$((sent + 1))
          echo "$name: sent"
        else
          echo "$name: msmtp failed; moved to failed/: $out" >&2
          file_to failed "$f"; failed=1; pop "msmtp failed for $name"
        fi
      done
      # Once nothing new is listed, one more look after a second: a file
      # renamed in while this run listed (the path unit does not fire for
      # it while the service runs) is sent in this run.
      if [ "$new" = 1 ]; then idle=0; continue; fi
      [ "$idle" = 0 ] || break
      idle=1
      sleep 1
    done
    [ "$sent" = 0 ] || echo "sent $sent"
    exit "$failed"
  '';
}
