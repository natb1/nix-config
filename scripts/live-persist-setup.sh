#!/usr/bin/env bash
# live-persist-setup.sh — add an encrypted persistence partition to the NixOS
# live USB, in the space the ISO does not use.
#
# RUN ONCE, per stick. After that, scripts/live-bootstrap.sh finds it.
#
# What it is for: the three things a public repo cannot carry —
#   ~/.claude                    Claude Code's session, so no browser login per boot
#   ssh/id_ed25519               a push credential, so `gh auth login` is never needed
#   NetworkManager connections   the Wi-Fi PSK
#
# --------------------------------------------------------------------------
# THE HAZARD, which is not the one you would guess.
#
# A NixOS ISO written raw is an "isohybrid" image, and its MBR looks like this:
#
#   /dev/sda1  Boot  Start 0  End 7594751  Id 00  Empty
#
# Partition 1 starts at SECTOR 0 — it overlaps the MBR that describes it. That
# is legal for isohybrid and intentional, but most partition editors regard it
# as corruption and silently "repair" it by moving the start to 2048. That
# repair breaks the boot.
#
# So this script only ever uses `sfdisk --append`, which adds one entry and
# rewrites nothing else, and `partx -a`, which tells the kernel about the new
# partition without re-reading the table of a device that is currently mounted.
# It never calls parted, gdisk, fdisk, or `sfdisk` without --append.
#
# If this still makes you nervous: put persistence on a SECOND USB stick
# instead. Same script, DEV=/dev/sdb, and zero risk to the thing that boots.
# --------------------------------------------------------------------------
#
# THE ORIGINAL TABLE, recorded here because it is the only durable copy.
#
# The script backs sector 0 up with dd before writing, but on a live USB that
# backup lands in tmpfs and is gone on the next boot — i.e. gone exactly when
# a broken stick would make you want it. These four lines are enough to
# rebuild the table from scratch, and they live in git:
#
#   label: dos
#   label-id: 0x9fb6382f
#   /dev/sda1 : start=0,   size=7594752, type=0,  bootable
#   /dev/sda2 : start=284, size=6144,    type=ef
#
# Measured 2026-09-24 from the 32 GB ASolid stick carrying
# nixos-graphical-26.05.10478.1bc55b9def81-x86_64-linux.iso. Restore with
# `sfdisk /dev/sda` fed that text — note that rewriting the whole table is
# only correct as a REPAIR, never as a way to add a partition.
# --------------------------------------------------------------------------

set -euo pipefail

DEV="${DEV:-/dev/sda}"
LABEL="${LABEL:-persist}"
MOUNT="${MOUNT:-/run/persist}"
# cryptsetup's default KDF is argon2id, which sizes its memory cost against
# free RAM. On a live USB that is already running something large it will
# either fail or evict what is running, so cap it. 256 MiB is still a strong
# KDF for a stick that never leaves the house.
PBKDF_MEMORY="${PBKDF_MEMORY:-262144}"

die() { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo -E $0)"
command -v cryptsetup >/dev/null || die "cryptsetup not on PATH (nix-shell -p cryptsetup)"
command -v sfdisk >/dev/null     || die "sfdisk not on PATH (nix-shell -p util-linux)"

# ---------------------------------------------------------------- pre-flight
say "Current layout of $DEV:"
sfdisk -l "$DEV"
echo

# Refuse to run against anything that is not obviously the live stick. The
# whole point of this script is to not write to the wrong device, and on this
# machine the two NVMe drives are one typo away.
if [ ! "$(lsblk -ndo TRAN "$DEV")" = "usb" ]; then
  die "$DEV is not a USB device. Refusing. (Both NVMe drives are off limits.)"
fi

# Find the first free sector: one past the end of the last existing partition,
# rounded up to a 2048-sector boundary.
#
# Parsed with match() rather than by field, because `sfdisk -d` pads its
# columns — the line reads "start=           0," so "start=" and its number
# are DIFFERENT awk fields. Splitting on whitespace yields an empty start, a
# computed start of 2048, and a partition laid straight over the ISO. Found
# by dry-running this on 2026-09-24; the guards below exist so that class of
# bug cannot reach sfdisk.
LAST_END=$(sfdisk -d "$DEV" | awk '
  /^\/dev\// {
    line = $0; s = ""; z = ""
    if (match(line, /start=[ \t]*[0-9]+/)) { s = substr(line, RSTART, RLENGTH); sub(/start=[ \t]*/, "", s) }
    if (match(line, /size=[ \t]*[0-9]+/))  { z = substr(line, RSTART, RLENGTH); sub(/size=[ \t]*/,  "", z) }
    if (s != "" && z != "") { e = s + z - 1; if (e > m) m = e }
  }
  END { print m+0 }')

case "$LAST_END" in
  ''|*[!0-9]*) die "could not parse partition ends from sfdisk -d (got '$LAST_END')" ;;
esac
[ "$LAST_END" -gt 0 ] || die "last used sector parsed as $LAST_END — refusing to guess"

TOTAL=$(blockdev --getsz "$DEV")
START=$(( ((LAST_END + 1 + 2047) / 2048) * 2048 ))
# Align the size down too, so the partition both starts and ends on a
# 2048-sector boundary.
SIZE=$(( ((TOTAL - START) / 2048) * 2048 ))

[ "$START" -gt "$LAST_END" ] || die "computed start $START is not past the last used sector $LAST_END"
[ "$SIZE" -gt $((2 * 1024 * 1024)) ] || die "only $SIZE sectors free — not worth it"
[ $((START + SIZE)) -le "$TOTAL" ] || die "computed partition runs past the end of $DEV"

# Belt and braces: assert the new range overlaps no existing partition. The
# arithmetic above should guarantee it; this catches the case where it does
# not, which is the only failure mode that destroys the stick.
sfdisk -d "$DEV" | awk -v ns="$START" -v ne="$((START + SIZE - 1))" '
  /^\/dev\// {
    line = $0
    if (match(line, /start=[ \t]*[0-9]+/)) { s = substr(line, RSTART, RLENGTH); sub(/start=[ \t]*/, "", s) }
    if (match(line, /size=[ \t]*[0-9]+/))  { z = substr(line, RSTART, RLENGTH); sub(/size=[ \t]*/,  "", z) }
    e = s + z - 1
    if (ns <= e && s <= ne) { printf "OVERLAP with %s (%d-%d)\n", $1, s, e; bad = 1 }
  }
  END { exit bad ? 1 : 0 }' || die "new partition would overlap an existing one — refusing"

say "Last used sector: $LAST_END"
say "New partition:    start $START, size $SIZE sectors ($((SIZE / 2 / 1024 / 1024)) GiB)"
echo
read -rp "Append this partition to $DEV? [type YES] " ok
[ "$ok" = "YES" ] || die "aborted"

# ------------------------------------------------------------- the partition
# Back up sector 0 before touching it. This is what makes the whole operation
# reversible: the only write to existing data is 16 bytes of partition-table
# entry, and `dd if=$MBR_BAK of=$DEV bs=512 count=1` puts it back exactly.
MBR_BAK="${MBR_BAK:-/tmp/$(basename "$DEV")-mbr-$(date +%Y%m%d%H%M%S).bak}"
dd if="$DEV" of="$MBR_BAK" bs=512 count=1 status=none
say "Sector 0 backed up to $MBR_BAK — restore with:"
say "  sudo dd if=$MBR_BAK of=$DEV bs=512 count=1"

# --append is the whole safety argument: it adds an entry and leaves the
# sector-0 partition 1 exactly as it is. Verified with --no-act on
# 2026-09-24: sda1 came back as "start 0, bootable" unchanged.
#
# --wipe never is NOT optional. sfdisk notices the iso9660 signature on the
# device and offers to wipe it; wiping it would destroy the live image. The
# default for an existing label is not to wipe, but this is far too important
# to leave to a default.
# --no-reread, because we are booted from this disk. sfdisk's "checking that
# no-one is using this disk" test fails outright on the live stick, and the
# check it is really guarding is the BLKRRPART re-read afterwards, which
# cannot succeed while /iso is mounted. We do not want that re-read: `partx -a`
# below tells the kernel about exactly the one new partition instead.
#
# Deliberately NOT --force. sfdisk suggests it, and it would work, but it
# overrules *all* checks including the overlap tests that are the main thing
# standing between this script and the ISO. --no-reread disables one check;
# --force disables the ones worth keeping.
say "Appending partition (sfdisk --append --wipe never --no-reread)"
printf 'start=%s, size=%s, type=83\n' "$START" "$SIZE" \
  | sfdisk --append --wipe never --no-reread "$DEV"

say "Telling the kernel about it (partx -a; the device is mounted, so no full re-read)"
partx -a "$DEV" || true

# Identify what we just made by MATCHING ITS START SECTOR, not by taking the
# highest-numbered or last-listed partition. Those are assumptions about
# ordering; this is the actual identity, and the next step formats it.
PART=$(sfdisk -d "$DEV" | awk -v want="$START" '
  /^\/dev\// {
    line = $0
    if (match(line, /start=[ \t]*[0-9]+/)) { s = substr(line, RSTART, RLENGTH); sub(/start=[ \t]*/, "", s) }
    if (s + 0 == want + 0) { print $1; exit }
  }')

[ -n "$PART" ] || die "could not find a partition starting at $START after --append"
[ -b "$PART" ] || die "$PART is not a block device (did partx -a fail?)"

# Last check before the first destructive command: whatever we are about to
# format must be empty. If it has a filesystem, we got the wrong partition.
if blkid "$PART" >/dev/null 2>&1; then
  die "$PART already holds a filesystem ($(blkid -o value -s TYPE "$PART")). Refusing to format."
fi

say "New partition is $PART (start $START) — empty, as expected"

# --------------------------------------------------------------------- LUKS
say "Formatting $PART as LUKS2 (you will set a passphrase)"
cryptsetup luksFormat --type luks2 --pbkdf-memory "$PBKDF_MEMORY" --label "$LABEL" "$PART"

say "Opening it"
cryptsetup open "$PART" "$LABEL"

say "Making an ext4 filesystem"
mkfs.ext4 -q -L "$LABEL" "/dev/mapper/$LABEL"

mkdir -p "$MOUNT"
mount "/dev/mapper/$LABEL" "$MOUNT"

# ------------------------------------------------------------------ populate
# Layout that scripts/live-bootstrap.sh expects.
install -d -m 700 "$MOUNT/claude" "$MOUNT/ssh" "$MOUNT/nm"
# The live user is uid 1000; make the tree usable without sudo after unlock.
chown -R 1000:100 "$MOUNT/claude" "$MOUNT/ssh" "$MOUNT/nm"
chmod 700 "$MOUNT" 2>/dev/null || true

cat > "$MOUNT/README" <<'TXT'
Persistence for the NixOS live USB. See docs/desktop-migration.md,
"Bootstrapping the live USB", in natb1/nix-config.

  claude/   -> symlinked to ~/.claude by scripts/live-bootstrap.sh
  ssh/      -> id_ed25519 (+ .pub) installed to ~/.ssh; push remote set to SSH
  nm/       -> NetworkManager system-connections, copied in by hand:
               sudo cp nm/*.nmconnection /etc/NetworkManager/system-connections/
               sudo chmod 600 /etc/NetworkManager/system-connections/*
               sudo systemctl restart NetworkManager

Everything here is a credential. That is why the partition is LUKS.
TXT

say "Done. Mounted at $MOUNT"
echo
cat <<TXT
Next, to fill it (none of this is automatic, because it is all secret):

  # Claude's session, from the machine you are on now
  cp -a ~/.claude/. $MOUNT/claude/

  # A push key. Add the PUBLIC half as a deploy key with write access at
  # https://github.com/natb1/nix-config/settings/keys
  ssh-keygen -t ed25519 -f $MOUNT/ssh/id_ed25519 -C 'live-usb@desk' -N ''
  cat $MOUNT/ssh/id_ed25519.pub

  # The Wi-Fi connection, so nmtui is not a per-boot step
  sudo cp /etc/NetworkManager/system-connections/*.nmconnection $MOUNT/nm/

On later boots:
  sudo cryptsetup open /dev/disk/by-partlabel/$LABEL $LABEL   # or by device
  sudo mkdir -p $MOUNT && sudo mount /dev/mapper/$LABEL $MOUNT
  curl -sL https://raw.githubusercontent.com/natb1/nix-config/main/scripts/live-bootstrap.sh | sh
TXT
