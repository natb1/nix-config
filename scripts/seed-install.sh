#!/usr/bin/env bash
# seed-install.sh — copy the things a public repo cannot carry onto a freshly
# installed system, before its first boot.
#
#   Run AFTER `nixos-install`, BEFORE rebooting, from the live USB:
#     sudo bash scripts/seed-install.sh
#
# Without this, desk's first boot has no network (the Wi-Fi PSK is not in this
# repo, by design), no checkout of this repo (nixos-install copies the store
# closure, not the working tree), and no Claude or gh session. All of that is
# recoverable by hand — nmtui, git clone, two browser logins — but there is no
# reason to do it by hand when the live session already has every piece.
#
# NOTHING SECRET IS IN THIS FILE. It is a list of copy operations; the secrets
# are read from the running live session at the moment it runs, and written
# only to the target filesystem. That is the whole point: the credentials move
# from RAM to the new disk without ever passing through git.
#
# Idempotent: safe to re-run. Existing files at the destination are left alone
# unless FORCE=1.

set -euo pipefail

TARGET="${TARGET:-/mnt}"
USERNAME="${USERNAME:-n8}"
SRC_REPO="${SRC_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FORCE="${FORCE:-0}"

# The source home is the INVOKING user's, not root's. This script must run as
# root to write to the target, and under sudo $HOME is /root — where none of
# the credentials live. Getting this wrong is quiet rather than loud: every
# credential copy reports "not present" and the script exits 0 having seeded
# nothing, which is only discovered on the first boot with no network and no
# logins. Found by testing against a fake target rather than during the
# install.
if [ -z "${SRC_HOME:-}" ]; then
  if [ -n "${SUDO_USER:-}" ]; then
    SRC_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  else
    SRC_HOME="$HOME"
  fi
fi

die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m  --\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash $0"

# ---------------------------------------------------------------- pre-flight
mountpoint -q "$TARGET" || die "$TARGET is not a mountpoint. Run disko's mount step first."

# /etc/passwd on the target is the proof that nixos-install actually ran, and
# it is also where the user's real uid comes from. Do NOT assume 1000: NixOS
# allocates it during activation, and guessing it wrong produces a home
# directory the user cannot write to — which, with autologin straight into
# niri, is a confusing first boot rather than an obvious error.
[ -f "$TARGET/etc/passwd" ] || die "$TARGET/etc/passwd missing — has nixos-install finished?"

PW_LINE=$(grep "^${USERNAME}:" "$TARGET/etc/passwd") \
  || die "user '$USERNAME' not found in $TARGET/etc/passwd"
UID_N=$(printf '%s' "$PW_LINE" | cut -d: -f3)
GID_N=$(printf '%s' "$PW_LINE" | cut -d: -f4)
HOME_N=$(printf '%s' "$PW_LINE" | cut -d: -f6)

say "Target $TARGET, user $USERNAME (uid=$UID_N gid=$GID_N home=$HOME_N)"

install -d -o "$UID_N" -g "$GID_N" -m 700 "$TARGET$HOME_N"

# Copy a path into the target home, preserving mode, owned by the target user.
seed_home() {
  local src="$1" rel="$2" mode="${3:-}"
  local dst="$TARGET$HOME_N/$rel"
  [ -e "$src" ] || { skip "$rel — not present on this live session"; return 0; }
  if [ -e "$dst" ] && [ "$FORCE" != "1" ]; then
    skip "$rel — already at the destination (FORCE=1 to overwrite)"
    return 0
  fi
  # Create each missing parent separately. `install -d -o` gives the owner only
  # to the LAST component and leaves every intermediate directory root-owned;
  # seeding .config/gh/hosts.yml that way left ~/.config root:root, and the
  # first switch then failed in home-manager with "mkdir: cannot create
  # directory ~/.config/...: Permission denied".
  local d="$TARGET$HOME_N" part
  local IFS=/
  for part in $(dirname "$rel"); do
    [ "$part" = "." ] && continue
    d="$d/$part"
    [ -d "$d" ] || install -d -o "$UID_N" -g "$GID_N" "$d"
  done
  unset IFS
  cp -a "$src" "$dst"
  chown -R "$UID_N:$GID_N" "$dst"
  [ -n "$mode" ] && chmod "$mode" "$dst"
  ok "$rel"
}

# ------------------------------------------------------------------- Wi-Fi
# NetworkManager keeps connection profiles as mutable state under /etc, not as
# anything Nix generates, so copying the files across is the whole job. The
# profile carries interface-name=wlp14s0, which is the same NIC on the target
# — same machine, same card.
say "Wi-Fi (NetworkManager connection profiles)"
NM_SRC=/etc/NetworkManager/system-connections
NM_DST="$TARGET/etc/NetworkManager/system-connections"
if compgen -G "$NM_SRC/*.nmconnection" >/dev/null; then
  install -d -m 700 "$NM_DST"
  for f in "$NM_SRC"/*.nmconnection; do
    if [ -e "$NM_DST/$(basename "$f")" ] && [ "$FORCE" != "1" ]; then
      skip "$(basename "$f") — already there"
    else
      # 600 root:root, or NetworkManager refuses to load it.
      install -m 600 -o root -g root "$f" "$NM_DST/"
      ok "$(basename "$f")"
    fi
  done
else
  skip "no .nmconnection files on this live session — connect with nmtui first"
fi

# -------------------------------------------------------------------- repo
# The working tree, not a fresh clone: it carries the branch, the git identity
# and anything not yet pushed, and it means the first boot needs no network to
# start working.
say "This repo"
seed_home "$SRC_REPO" "natb1/nix-config"

# ------------------------------------------------------------------ Claude
# Not managed by home-manager (checked: ~/.claude appears nowhere in
# home.file), so these are ours to place and nothing will contest them.
say "Claude Code session"
seed_home "$SRC_HOME/.claude"      ".claude"      700
seed_home "$SRC_HOME/.claude.json" ".claude.json" 600

# ---------------------------------------------------------------------- gh
# ONLY hosts.yml, which holds the token. config.yml IS managed by
# home-manager (modules/home/gh.nix), so copying it would just be backed up
# and replaced on the first switch — noise, and a .backup file to explain.
say "gh authentication"
seed_home "$SRC_HOME/.config/gh/hosts.yml" ".config/gh/hosts.yml" 600

# A credential that was not found is almost always a mistake, not a choice, and
# the cost of not noticing is a first boot with no network and no logins. Say
# so at the end, where it cannot scroll past unread.
MISSING=""
[ -e "$TARGET$HOME_N/.claude" ]               || MISSING="$MISSING ~/.claude"
[ -e "$TARGET$HOME_N/.config/gh/hosts.yml" ]  || MISSING="$MISSING ~/.config/gh/hosts.yml"
compgen -G "$NM_DST/*.nmconnection" >/dev/null || MISSING="$MISSING wifi-profile"

if [ -n "$MISSING" ]; then
  echo
  printf '\033[1;33mWARNING\033[0m nothing seeded for:%s\n' "$MISSING" >&2
  printf '        SRC_HOME was %s — is that the right home directory?\n' "$SRC_HOME" >&2
  printf '        Under sudo without SUDO_USER set it can resolve to /root.\n' >&2
  printf '        Re-run with SRC_HOME=/home/<user> to fix.\n' >&2
fi

echo
say "Seeded. After the reboot, expect:"
cat <<TXT
  - Wi-Fi to associate on its own, with no nmtui step
  - the repo at $HOME_N/natb1/nix-config, on its branch
  - claude-code and gh already authenticated

  First thing to run there:
    cd ~/natb1/nix-config && sudo nixos-rebuild switch --flake .#desk

  If Wi-Fi does not come up, the profile is at
  /etc/NetworkManager/system-connections/ — check it is 600 and root-owned,
  then: sudo systemctl restart NetworkManager
TXT
