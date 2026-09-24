#!/usr/bin/env bash
# live-bootstrap.sh — get a NixOS live USB from "just booted" to "working on
# this repo" in one command.
#
#   curl -sL https://raw.githubusercontent.com/natb1/nix-config/main/scripts/live-bootstrap.sh | sh
#
# A live USB keeps everything in RAM, so this has to be re-run on every boot.
# It is idempotent: safe to run twice, and safe to run over an existing
# checkout (it fetches rather than re-clones).
#
# What it deliberately does NOT do: `gh auth login`. This repo is public, so
# the clone below needs no credentials at all — that browser device flow is
# only needed to PUSH, and this script sets up an SSH remote for that instead
# (see "Pushing" below). Removing it from the critical path is most of why
# this script exists.
#
# Secrets are never fetched from the repo — it is public. The optional
# persistence partition (see docs/desktop-migration.md, "Bootstrapping the
# live USB") is where credentials come from, if it exists.

set -eu

REPO_URL="${REPO_URL:-https://github.com/natb1/nix-config.git}"
REPO_DIR="${REPO_DIR:-$HOME/nix-config}"
BRANCH="${BRANCH:-claude/sweet-hypatia-03wf7f}"
GIT_NAME="${GIT_NAME:-Nathan Buesgens}"
GIT_EMAIL="${GIT_EMAIL:-nathan@natb1.com}"

# The persistence partition, if one is present and already unlocked. Holds the
# things a public repo cannot: ~/.claude, an SSH key for pushes, and the
# NetworkManager connection carrying the Wi-Fi PSK.
PERSIST="${PERSIST:-/run/persist}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------- the repo
# Cloned over HTTPS with no credentials, because the repo is public.
if [ -d "$REPO_DIR/.git" ]; then
  say "Repo already at $REPO_DIR — fetching"
  git -C "$REPO_DIR" fetch --all --prune
else
  say "Cloning $REPO_URL into $REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
fi

git -C "$REPO_DIR" switch "$BRANCH" 2>/dev/null \
  || git -C "$REPO_DIR" switch -c "$BRANCH" "origin/$BRANCH"

git -C "$REPO_DIR" config user.name "$GIT_NAME"
git -C "$REPO_DIR" config user.email "$GIT_EMAIL"

# ------------------------------------------------------------- credentials
# Everything below is optional. Without the persistence partition the shell
# still comes up usable; you just re-authenticate by hand, as before.
if [ -d "$PERSIST" ]; then
  say "Persistence found at $PERSIST"

  # Claude Code's session, so it does not need a browser login per boot.
  if [ -d "$PERSIST/claude" ] && [ ! -e "$HOME/.claude" ]; then
    ln -sfn "$PERSIST/claude" "$HOME/.claude"
    say "  ~/.claude -> $PERSIST/claude"
  fi

  # A push credential. An SSH deploy key avoids `gh` entirely: clone stays
  # anonymous over HTTPS, pushes go over SSH.
  if [ -f "$PERSIST/ssh/id_ed25519" ]; then
    mkdir -p "$HOME/.ssh"
    install -m 600 "$PERSIST/ssh/id_ed25519" "$HOME/.ssh/id_ed25519"
    [ -f "$PERSIST/ssh/id_ed25519.pub" ] \
      && install -m 644 "$PERSIST/ssh/id_ed25519.pub" "$HOME/.ssh/id_ed25519.pub"
    git -C "$REPO_DIR" remote set-url --push origin \
      "git@github.com:natb1/nix-config.git"
    say "  push remote -> SSH, key installed"
  fi
else
  warn "No persistence at $PERSIST — ~/.claude and the push key are not set up."
  warn "Pushes will prompt. See docs/desktop-migration.md, \"Bootstrapping the live USB\"."
fi

# ------------------------------------------------------------------- tools
# One shell with everything this repo's live-USB work needs: git/gh, the
# Phase 0 inventory set, and claude-code. On a stock ISO these download on
# every boot; the custom ISO (Tier 2, same doc section) bakes them in so this
# step becomes instant.
say "Entering the tool shell (cwd: $REPO_DIR)"
cd "$REPO_DIR"

export NIXPKGS_ALLOW_UNFREE=1
exec nix-shell -p \
  git gh \
  pciutils usbutils hwloc fio smartmontools dmidecode iw lm_sensors nvme-cli \
  stressapptest cryptsetup \
  --run "cd '$REPO_DIR'; exec \
    nix --extra-experimental-features 'nix-command flakes' \
      run --impure nixpkgs#claude-code"
