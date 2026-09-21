#!/usr/bin/env bash
# Refresh modules/home/wezterm-pin.nix to the current upstream WezTerm nightly,
# mirroring its Windows zip to a release on this repo.
#
# The Windows GUI (mux client) and the WSL wezterm-mux-server must be the same
# build or the mux handshake fails and the GUI window closes on connect. Upstream
# ships exactly ONE Windows nightly zip (overwritten in place), so a pinned build
# vanishes from upstream as soon as a newer nightly ships. This script captures
# the current nightly as a pin and uploads the zip to an immutable
# `wezterm-<version>` release on natb1/nix-config, which is where
# hosts/wsl/home/wezterm-windows.nix fetches it from.
#
# It derives the target from the distributed Windows binary itself — the zip's
# internal `WezTerm-windows-<date>-<time>-<shorthash>` directory name — NOT the
# upstream `nightly` git ref, which is frequently stale and points at a different
# commit than the published assets.
#
# Run from the repo root, then switch every host (from a NON-WezTerm shell — the
# mux restart drops the pane you launch it from). Requires network, nix, and an
# authenticated `gh` with write access to the mirror repo.
#
# Usage: scripts/sync-wezterm.sh
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
PIN_FILE="$REPO_ROOT/modules/home/wezterm-pin.nix"
ZIP_URL="https://github.com/wez/wezterm/releases/download/nightly/WezTerm-windows-nightly.zip"
MIRROR_REPO="natb1/nix-config"
FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

system=$(nix eval --impure --raw --expr 'builtins.currentSystem')

echo "==> Downloading current Windows nightly zip"
ZIP_PATH=$(nix-prefetch-url --print-path --type sha256 "$ZIP_URL" 2>/dev/null | tail -1)
WINDOWS_ZIP_HASH=$(nix hash file --sri --type sha256 "$ZIP_PATH")

echo "==> Reading version from the distributed binary"
# The zip's top-level directory is authoritative: WezTerm-windows-<version>.
VERSION=$(nix shell nixpkgs#unzip -c unzip -Z1 "$ZIP_PATH" \
  | grep -oE '^WezTerm-windows-[0-9]{8}-[0-9]{6}-[0-9a-f]+' \
  | head -1 | sed 's/^WezTerm-windows-//')
SHORT_SHA=${VERSION##*-}
echo "    version:   $VERSION"

echo "==> Resolving full commit for $SHORT_SHA"
REV=$(curl -fsSL "https://api.github.com/repos/wez/wezterm/commits/$SHORT_SHA" | jq -r '.sha')
echo "    rev:       $REV"

# Mirror the exact bytes just hashed. The asset name and tag carry the version,
# matching the URL wezterm-windows.nix builds from the pin.
TAG="wezterm-$VERSION"
ASSET="WezTerm-windows-$VERSION.zip"
echo "==> Mirroring $ASSET to $MIRROR_REPO release $TAG"
if gh release view "$TAG" -R "$MIRROR_REPO" >/dev/null 2>&1; then
  # Already mirrored (e.g. a re-run). Verify the published bytes, never replace
  # them: the release is the immutable record a past pin may still reference.
  MIRROR_DIR=$(mktemp -d)
  trap 'rm -rf "$MIRROR_DIR"' EXIT
  gh release download "$TAG" -R "$MIRROR_REPO" -p "$ASSET" -D "$MIRROR_DIR"
  MIRROR_HASH=$(nix hash file --sri --type sha256 "$MIRROR_DIR/$ASSET")
  if [ "$MIRROR_HASH" != "$WINDOWS_ZIP_HASH" ]; then
    echo "ERROR: $TAG already exists with different bytes" >&2
    echo "  mirrored: $MIRROR_HASH" >&2
    echo "  upstream: $WINDOWS_ZIP_HASH" >&2
    echo "  Upstream re-uploaded the same build. Investigate before touching the" >&2
    echo "  existing release; hosts may already be pinned to it." >&2
    exit 1
  fi
  echo "    already mirrored with matching bytes"
else
  MIRROR_DIR=$(mktemp -d)
  trap 'rm -rf "$MIRROR_DIR"' EXIT
  cp "$ZIP_PATH" "$MIRROR_DIR/$ASSET"
  gh release create "$TAG" "$MIRROR_DIR/$ASSET" -R "$MIRROR_REPO" --latest=false \
    --title "WezTerm $VERSION (Windows mirror)" \
    --notes "Unmodified mirror of upstream's WezTerm-windows-nightly.zip for build $VERSION (wez/wezterm@$REV). Upstream overwrites that asset in place; this copy is what modules/home/wezterm-pin.nix pins by hash. Created by scripts/sync-wezterm.sh."
fi

echo "==> Fetching source (fetchSubmodules) to compute srcHash — this is slow"
SRC_PATH=$(nix eval --impure --raw --expr \
  "builtins.fetchGit { url = \"https://github.com/wezterm/wezterm\"; rev = \"$REV\"; submodules = true; }")
SRC_HASH=$(nix hash path --sri --type sha256 "$SRC_PATH")
echo "    srcHash:   $SRC_HASH"

# Write the pin with the real srcHash and a placeholder cargoHash, then let a
# build surface the real vendor hash from the mismatch error.
write_pin() {
  cat > "$PIN_FILE" <<EOF
# Pinned WezTerm nightly — single source of truth.
#
# Both the WezTerm package (wezterm-package.nix, built from source at \`rev\`)
# and the Windows GUI binary (hosts/wsl/home/wezterm-windows.nix, the matching
# nightly zip) are pinned to the SAME upstream build here, so every mux client
# (Windows GUI, Mac GUI) and the WSL wezterm-mux-server speak the same PDU
# protocol version.
#
# \`version\` is authoritative and is read from the distributed Windows binary
# itself (the zip's internal \`WezTerm-windows-<version>\` directory name), NOT
# the upstream \`nightly\` git ref — that ref is frequently stale.
#
# Regenerate with:  scripts/sync-wezterm.sh  (do not hand-edit the hashes).
{
  version = "$VERSION";
  rev = "$REV";
  srcHash = "$SRC_HASH";
  cargoHash = "$1";

  # SHA-256 of the Windows zip, fetched from this repo's immutable mirror
  # release \`wezterm-<version>\` (upstream overwrites its nightly asset in place).
  windowsZipHash = "$WINDOWS_ZIP_HASH";
}
EOF
}

echo "==> Resolving cargoHash via a vendor build"
write_pin "$FAKE_HASH"
CARGO_HASH=$(nix build "$REPO_ROOT#packages.$system.wezterm" --no-link 2>&1 \
  | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1 || true)

if [ -z "$CARGO_HASH" ]; then
  echo "ERROR: could not extract cargoHash — the build may have succeeded with the" >&2
  echo "       fake hash (unexpected) or failed for another reason. Re-run manually:" >&2
  echo "       nix build $REPO_ROOT#packages.$system.wezterm" >&2
  exit 1
fi
echo "    cargoHash: $CARGO_HASH"

write_pin "$CARGO_HASH"

echo "==> Verifying the pinned package evaluates"
nix build "$REPO_ROOT#packages.$system.wezterm" --no-link --dry-run

echo
echo "Wrote $PIN_FILE for $VERSION."
echo "Next: switch the WSL host (close the Windows WezTerm GUI first — the install"
echo "can't overwrite a running binary) and the Mac, so all three load $VERSION."
