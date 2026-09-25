# `eco on` / `eco off` / `eco status`: AMD's Eco Mode power limits, switched
# from NixOS while running, instead of in firmware setup
# (docs/desktop-migration.md, Fan control, "Less heat beats any curve").
#
# Eco Mode is only three limits, and the CPU's SMU takes them at runtime:
#   PPT (package power)  88 W   vs stock 142 W
#   TDC (sustained amps) 75 A   vs stock 110 A
#   EDC (peak amps)      150 A  vs stock 170 A
# They only bind under many-core load, so single-thread boost is untouched —
# unlike capping frequency or turning boost off.
#
# The mechanism is ryzen_smu, an out-of-tree driver that exposes the SMU's
# mailbox. The command IDs are Zen 4's RSMU ones, taken from ZenStates-Core
# (Hardware/Smu/Settings/Zen4Settings.cs: SetFastLimit 0x56 — what its
# SetPPTLimit sends — SetTDCVDDLimit 0x57, SetEDCVDDLimit 0x58; arguments in
# mW/mA). Not ryzen_smu's own README numbers, which are Zen 3's. The only
# values this script ever sends are the two sets above, both AMD's own.
#
# Limits set this way do not survive a reboot or, possibly, a suspend; the
# chosen mode is kept in /var/lib/eco/mode and re-applied at boot and resume.
# No file means "never chosen": nothing is sent and the firmware's limits stand.

{ pkgs, ... }:

let
  eco = pkgs.writeShellApplication {
    name = "eco";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      drv=/sys/kernel/ryzen_smu_drv
      state=/var/lib/eco/mode

      if [ "$(id -u)" -ne 0 ]; then
        exec /run/wrappers/bin/sudo "$0" "$@"
      fi

      # Six little-endian 32-bit words, written in one write() as the driver
      # requires: the value, then five zeros.
      args() {
        local v=$1 word pad
        word=$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
          $((v & 255)) $((v >> 8 & 255)) $((v >> 16 & 255)) $((v >> 24 & 255)))
        pad=$(printf '\\x00%.0s' {1..20})
        printf '%b' "$word$pad"
      }

      send() { # <name> <rsmu command byte> <value>
        args "$3" >"$drv/smu_args"
        printf '%b' "\\x$2" >"$drv/rsmu_cmd"
        local rc
        rc=$(od -An -tu4 -N4 "$drv/rsmu_cmd" | tr -d ' ')
        if [ "$rc" != 1 ]; then
          echo "eco: $1 rejected by the SMU (status $rc)" >&2
          return 1
        fi
      }

      limits() { # <ppt mW> <tdc mA> <edc mA>
        send PPT 56 "$1" && send TDC 57 "$2" && send EDC 58 "$3"
      }

      apply() {
        case "$1" in
          on) limits 88000 75000 150000 ;;
          off) limits 142000 110000 170000 ;;
          *) echo "eco: unknown mode '$1'" >&2; return 1 ;;
        esac
      }

      # The PM table's first words, as the SMU reports them. Layout assumed
      # from Zen 3/4 tables (PPT limit/value, TDC limit/value, …, EDC at 8/9);
      # the limits reading 142/110/170 at stock is what confirms it.
      status() {
        echo "mode: $(cat "$state" 2>/dev/null || echo 'firmware default (never set)')"
        od -An -tf4 -N40 "$drv/pm_table" | tr -s ' \n' ' ' | {
          read -r ppt_l ppt tdc_l tdc _ _ _ _ edc_l edc
          printf 'PPT %6.1f W of %6.1f W\n' "$ppt" "$ppt_l"
          printf 'TDC %6.1f A of %6.1f A\n' "$tdc" "$tdc_l"
          printf 'EDC %6.1f A of %6.1f A\n' "$edc" "$edc_l"
        }
      }

      if [ ! -e "$drv/rsmu_cmd" ]; then
        echo "eco: ryzen_smu is not loaded ($drv missing)" >&2
        exit 1
      fi

      case "''${1:-status}" in
        on | off)
          apply "$1"
          mkdir -p "$(dirname "$state")"
          echo "$1" >"$state"
          status
          ;;
        restore)
          if [ -e "$state" ]; then apply "$(cat "$state")"; fi
          ;;
        status) status ;;
        *)
          echo "usage: eco [on|off|status]" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  hardware.cpu.amd.ryzen-smu.enable = true;

  environment.systemPackages = [ eco ];

  systemd.services.eco-restore = {
    description = "Re-apply the chosen Eco Mode power limits";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${eco}/bin/eco restore";
    };
  };
  powerManagement.resumeCommands = "${eco}/bin/eco restore";
}
