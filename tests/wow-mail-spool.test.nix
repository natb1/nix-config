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
  runs() { find "$FAKE_LOG" -name "*.args" | wc -l; }

  # An empty spool with no recipient file: nothing to do, exit 0.
  ${send}/bin/wow-mail-spool-send "$s" "$r" || fail "an empty spool with no recipient file failed"
  [ -d "$s/failed" ] && [ -d "$s/sent" ] && [ -d "$s/rejected" ] || fail "the subdirectories were not made"

  # A ready file with no recipient file: not sent, moved to failed/ (never
  # deleted), the unit fails.
  mail a-deal.eml you@example.invalid "" one
  rc=0; ${send}/bin/wow-mail-spool-send "$s" "$r" || rc=$?
  [ "$rc" != 0 ] || fail "no recipient file, but it exited 0"
  [ -f "$s/failed/a-deal.eml" ] || fail "no recipient file, and the mail is not in failed/"
  [ "$(runs)" = 0 ] || fail "no recipient file, and msmtp ran"

  echo you@example.invalid >"$r"
  mail a-deal.eml you@example.invalid "" one
  mail b-deal.eml someone@example.invalid "" two
  mail c-deal.eml you@example.invalid "Bcc: someone@example.invalid" three
  mail d-deal.eml you@example.invalid "" FAILME
  mail .e-deal.eml.tmp you@example.invalid "" five
  mail f-deal.eml "You <YOU@example.invalid>" "" six
  mail h-deal.eml you@example.invalid "" late
  touch -d '-200 seconds' "$s/h-deal.eml"
  mail target.txt you@example.invalid "" target
  ln -s "$s/target.txt" "$s/g-deal.eml"
  rc=0; ${send}/bin/wow-mail-spool-send "$s" "$r" || rc=$?
  [ "$rc" = 1 ] || fail "failures and rejections, but it exited $rc"
  [ -f "$s/sent/a-deal.eml" ] && [ -f "$s/sent/f-deal.eml" ] || fail "the good mail is not in sent/"
  [ -f "$s/rejected/b-deal.eml" ] || fail "mail to another address is not in rejected/"
  [ -f "$s/rejected/c-deal.eml" ] || fail "mail with a Bcc is not in rejected/"
  [ -f "$s/failed/d-deal.eml" ] || fail "the mail msmtp refused is not in failed/"
  [ -f "$s/failed/h-deal.eml" ] || fail "the mail that waited too long is not in failed/"
  [ -L "$s/rejected/g-deal.eml" ] && [ -f "$s/target.txt" ] || fail "a link was not moved itself to rejected/"
  [ -f "$s/.e-deal.eml.tmp" ] || fail "a file still being written was touched"
  [ "$(runs)" = 3 ] || fail "msmtp ran $(runs) times, not 3 (a, d, f)"
  for a in "$FAKE_LOG"/*.args; do
    [ "$(cat "$a")" = "$(printf '%s\n' -- you@example.invalid)" ] || fail "msmtp was not given only the recipient: $(cat "$a")"
  done
  grep -l 'body one' "$FAKE_LOG"/*.mail | head -1 | xargs grep -q $'\r' && fail "the mail reached msmtp with CR line ends"
  grep -q '^Subject: Deal: test$' "$FAKE_LOG/0.mail" || fail "the headers did not reach msmtp"
  grep -q 'body target' "$FAKE_LOG"/*.mail && fail "the link's target was sent"

  # An empty run is 0; a name already in sent/ is kept, not overwritten.
  ${send}/bin/wow-mail-spool-send "$s" "$r" || fail "an empty spool failed"
  mail a-deal.eml you@example.invalid "" again
  ${send}/bin/wow-mail-spool-send "$s" "$r" || fail "a repeated name failed"
  [ "$(ls "$s/sent" | grep -c '^a-deal.eml')" = 2 ] || fail "a repeated name overwrote sent/"

  # A subdirectory that is a link: nothing is sent, nothing moves.
  mkdir "$TMPDIR/elsewhere"
  rmdir "$s/sent" 2>/dev/null || mv "$s/sent" "$TMPDIR/sent-kept"
  ln -s "$TMPDIR/elsewhere" "$s/sent"
  mail k-deal.eml you@example.invalid "" linked
  n0=$(runs)
  rc=0; ${send}/bin/wow-mail-spool-send "$s" "$r" || rc=$?
  [ "$rc" != 0 ] || fail "sent/ is a link, but it exited 0"
  [ -f "$s/k-deal.eml" ] && [ "$(runs)" = "$n0" ] && [ -z "$(ls "$TMPDIR/elsewhere")" ] || fail "sent/ is a link, and it sent or moved"
  touch "$out"
''
