# Host: wsl — tailscaled rebind watcher.
#
# WSL-only: it keys on the WSL2 NAT adapter's eth0, so it lives here rather
# than in modules/nixos/tailscale.nix, which every Linux host imports. A native
# host would inherit an idle watcher that fires on anything named eth0.

{ pkgs, ... }:

{
  # Rebind tailscaled when the WSL2 NAT IP rotates under it.
  #
  # WSL2 runs eth0 behind a NAT-mode virtual adapter whose IP can change while
  # the daemon is already running. When that happens, tailscaled's magicsock
  # socket and DERP receive path stay bound to the OLD eth0 IP: outbound keeps
  # working (fresh NAT mappings still open, host-initiated `tailscale ping`
  # pongs), but cold INBOUND is dead — a peer's `tailscale ping <host>` times
  # out over both direct and DERP, so SSH to the host hangs. A `systemctl
  # restart tailscaled` re-runs endpoint discovery and re-homes DERP on the
  # current eth0 IP, reclaiming the same Tailscale IP.
  #
  # This watcher automates that: it tails address-change events and restarts
  # tailscaled whenever eth0 gains an address. `ip monitor` has no per-device
  # filter, so we match "eth0" in the event text; the delete half of a rotation
  # is ignored, and tailscale0's own up/down churn is filtered out (we only act
  # on eth0), so a restart cannot feed back into another restart.
  systemd.services.tailscaled-wsl-rebind = {
    description = "Restart tailscaled when the WSL2 eth0 NAT IP rotates under it";
    after = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.iproute2 ];
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
    script = ''
      ip monitor address | while read -r line; do
        case "$line" in
          Deleted*) ;;                       # ignore the delete half of a rotation
          *eth0*"inet "*) systemctl restart tailscaled ;;
        esac
      done
    '';
  };
}
