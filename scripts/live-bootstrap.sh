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
# only needed to PUSH. Keeping it off the critical path is most of why this
# script exists; authenticate by hand on the rare occasion you push from here.
#
# No secrets, by construction. Nothing here reads a credential, and nothing
# could: the repo this fetches from is public.

set -eu

REPO_URL="${REPO_URL:-https://github.com/natb1/nix-config.git}"
REPO_DIR="${REPO_DIR:-$HOME/nix-config}"
BRANCH="${BRANCH:-claude/sweet-hypatia-03wf7f}"
GIT_NAME="${GIT_NAME:-Nathan Buesgens}"
GIT_EMAIL="${GIT_EMAIL:-nathan@natb1.com}"


say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

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


# ------------------------------------------------------------------- tools
# One shell with everything this repo's live-USB work needs: git/gh, the
# Phase 0 inventory set, and claude-code. On a stock ISO these download on
# every boot. That is accepted: after Phase 2 this stick is a recovery tool,
# not a daily driver.
say "Entering the tool shell (cwd: $REPO_DIR)"
cd "$REPO_DIR"

export NIXPKGS_ALLOW_UNFREE=1
exec nix-shell -p \
  git gh \
  pciutils usbutils hwloc fio smartmontools dmidecode iw lm_sensors nvme-cli \
  stressapptest \
  --run "cd '$REPO_DIR'; exec \
    nix --extra-experimental-features 'nix-command flakes' \
      run --impure nixpkgs#claude-code"
