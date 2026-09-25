# DIMM temperatures in `sensors`, which BIOS tuning's hot run needs ("DIMMs
# under ~55 °C", docs/desktop-migration.md).
#
# DDR5 DIMMs carry an SPD hub with a temperature sensor (the kernel's
# spd5118), reached over the chipset's SMBus (i2c_piix4, PCI 00:14.0). On
# this board i2c_piix4 does not bind: the firmware's ACPI declares the same
# ports, SystemIO 0xB00–0xB0F as \GSA1.SMBI, and the kernel refuses a driver
# whose ports ACPI claims ("ACPI: OSL: Resource conflict", 2026-09-25).
#
# That declaration was checked before overriding it, from the decompiled
# SSDT1 (2026-09-25). \GSA1 is Gigabyte's WMI device, and SMBI is only used
# by a generic SMBus pass-through behind WMI function numbers that Gigabyte's
# Windows tools call. Nothing on Linux calls them: the gigabyte_wmi driver
# asks only for function 0x125 (temperatures), which reads the Super I/O
# through \GSA1.SIO0, not the SMBus, and the sleep/wake hooks into \GSA1 are
# empty. So the kernel's driver would be the bus's only user, and
# acpi_enforce_resources=lax lets it bind.
#
# The contrast with the fans: the out-of-tree it87 would share the Super I/O
# with ACPI code that *does* run under Linux (that same gigabyte_wmi read), so
# it stays off. lax applies to every driver that checks ACPI claims; it87 is
# the only one of those this board would load, and it is not configured.

#
# The second DIMM needs a hand. The kernel instantiates SPD sensors itself,
# but only at 0x50 + slot index for the slots DMI reports (two, so 0x50 and
# 0x51), and this board wires channel B's DIMM at 0x52 — a read-only
# `i2cdetect -r` found 0x50 and 0x52 on port 0 and nothing else (2026-09-25).
# So register 0x52 by hand at boot; spd5118 checks the device type before
# binding, and it read 48 °C there beside channel A's 47 °C.

{ pkgs, ... }:

{
  boot.kernelParams = [ "acpi_enforce_resources=lax" ];
  boot.kernelModules = [ "spd5118" ];
  environment.systemPackages = [ pkgs.lm_sensors ];

  systemd.services.spd5118-channel-b = {
    description = "DDR5 temperature sensor for the channel B DIMM (SMBus 0x52)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig.Type = "oneshot";
    # The PIIX4 adapter is found by name, not bus number, which can move; it
    # appears once udev has loaded i2c_piix4, so wait for it briefly.
    script = ''
      for _ in $(seq 30); do
        for a in /sys/bus/i2c/devices/i2c-*; do
          if [ "$(cat "$a/name")" = "SMBus PIIX4 adapter port 0 at 0b00" ]; then
            bus=''${a##*/i2c-}
            [ -e "$a/$bus-0052" ] || echo "spd5118 0x52" > "$a/new_device"
            exit 0
          fi
        done
        sleep 1
      done
      echo "SMBus PIIX4 port 0 did not appear" >&2
      exit 1
    '';
  };
}
