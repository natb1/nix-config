# The mail spool's sender (hosts/desk/wow-mail-spool-send.nix), run on a
# scratch spool with a fake msmtp that records its arguments and the mail.
# Only made-up addresses and bodies here.
{ runCommand, callPackage, writeShellScriptBin }:

let
  fakeMsmtp = writeShellScriptBin "msmtp" ''
    n=$(ls "$FAKE_LOG"/*.args 2>/dev/null | wc -l)
    printf '%s\n' "$@" >"$FAKE_LOG/$n.args"
    cat >"$FAKE_LOG/$n.mail"
    if grep -q FAILME "$FAKE_LOG/$n.mail"; then echo "fake msmtp: refused" >&2; exit 1; fi
  '';
  send = callPackage ../hosts/desk/wow-mail-spool-send.nix {
    msmtp = fakeMsmtp;
    spool = "/nonexistent/spool";
    recipientFile = "/nonexistent/recipient";
    user = "nobody-here";
    group = "nogroup";
  };
in
runCommand "wow-mail-spool-test" { } ''
  fail() { echo "wow-mail-spool: $*" >&2; exit 1; }
  s=$TMPDIR/spool r=$TMPDIR/recipient
  export FAKE_LOG=$TMPDIR/log
  mkdir -p "$s" "$FAKE_LOG"
  mail() { printf '%s\r\n' "To: $2" "Subject: Deal: test" "Date: Tue, 24 Nov 2026 12:00:00 +0000" ''${3:+"$3"} "" "body $4" >"$s/$1"; }

  # No recipient file: nothing is sent, nothing moves, the unit fails.
  mail a-deal.eml you@example.invalid "" one
  rc=0; ${send}/bin/wow-mail-spool-send "$s" "$r" || rc=$?
  [ "$rc" != 0 ] || fail "no recipient file, but it exited 0"
  [ -f "$s/a-deal.eml" ] || fail "no recipient file, and the mail moved"
  [ -z "$(ls "$FAKE_LOG")" ] || fail "no recipient file, and msmtp ran"

  echo you@example.invalid >"$r"
  mail b-deal.eml someone@example.invalid "" two
  mail c-deal.eml you@example.invalid "Bcc: someone@example.invalid" three
  mail d-deal.eml you@example.invalid "" FAILME
  mail .e-deal.eml.tmp you@example.invalid "" five
  mail f-deal.eml "You <YOU@example.invalid>" "" six
  rc=0; ${send}/bin/wow-mail-spool-send "$s" "$r" || rc=$?
  [ "$rc" = 1 ] || fail "a failure and two rejections, but it exited $rc"
  [ -f "$s/sent/a-deal.eml" ] && [ -f "$s/sent/f-deal.eml" ] || fail "the good mail is not in sent/"
  [ -f "$s/rejected/b-deal.eml" ] || fail "mail to another address is not in rejected/"
  [ -f "$s/rejected/c-deal.eml" ] || fail "mail with a Bcc is not in rejected/"
  [ -f "$s/d-deal.eml" ] || fail "the mail msmtp refused is not left in the spool"
  [ -f "$s/.e-deal.eml.tmp" ] || fail "a file still being written was touched"
  [ "$(ls "$FAKE_LOG"/*.args | wc -l)" = 3 ] || fail "msmtp ran $(ls "$FAKE_LOG"/*.args | wc -l) times, not 3 (a, d, f)"
  for a in "$FAKE_LOG"/*.args; do
    [ "$(cat "$a")" = "$(printf '%s\n' -- you@example.invalid)" ] || fail "msmtp was not given only the recipient: $(cat "$a")"
  done
  grep -l 'body one' "$FAKE_LOG"/*.mail | head -1 | xargs grep -q $'\r' && fail "the mail reached msmtp with CR line ends"
  grep -q '^Subject: Deal: test$' "$FAKE_LOG/0.mail" || fail "the headers did not reach msmtp"

  # The retry: the refused mail goes once msmtp takes it; an empty run is 0.
  sed -i 's/FAILME/four/' "$s/d-deal.eml"
  ${send}/bin/wow-mail-spool-send "$s" "$r" || fail "the retry failed"
  [ -f "$s/sent/d-deal.eml" ] || fail "the retried mail is not in sent/"
  ${send}/bin/wow-mail-spool-send "$s" "$r" || fail "an empty spool failed"

  # A name already in sent/ is kept, not overwritten.
  mail a-deal.eml you@example.invalid "" again
  ${send}/bin/wow-mail-spool-send "$s" "$r" || fail "a repeated name failed"
  [ "$(ls "$s/sent" | grep -c '^a-deal.eml')" = 2 ] || fail "a repeated name overwrote sent/"
  touch "$out"
''
