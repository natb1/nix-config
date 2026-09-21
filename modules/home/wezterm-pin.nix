# Pinned WezTerm nightly — single source of truth.
#
# Both the WezTerm package (wezterm-package.nix, built from source at `rev`)
# and the Windows GUI binary (hosts/wsl/home/wezterm-windows.nix, the matching
# nightly zip) are pinned to the SAME upstream build here, so every mux client
# (Windows GUI, Mac GUI) and the WSL wezterm-mux-server speak the same PDU
# protocol version.
#
# `version` is authoritative and is read from the distributed Windows binary
# itself (the zip's internal `WezTerm-windows-<version>` directory name), NOT
# the upstream `nightly` git ref — that ref is frequently stale.
#
# Regenerate with:  scripts/sync-wezterm.sh  (do not hand-edit the hashes).
{
  version = "20260917-114457-b09b56c2";
  rev = "b09b56c29c1e367e598b60ca266e2cc9038751e0";
  srcHash = "sha256-wVK9IcPezoEWeTlDkD/foGyRH2tnwEHX3ZgChpIX3Vw=";
  cargoHash = "sha256-GiHuJkkcPKoQpzVKDlbI2eZVj+5Fns/CHKxRtBw39WU=";

  # SHA-256 of the Windows zip, fetched from this repo's immutable mirror
  # release `wezterm-<version>` (upstream overwrites its nightly asset in place).
  windowsZipHash = "sha256-ZdjeQjl6B2RkfExKRv50qWgbn9BKY5eQGxtyTgsK6Lk=";
}
