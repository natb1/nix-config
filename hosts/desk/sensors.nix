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

{ pkgs, ... }:

{
  boot.kernelParams = [ "acpi_enforce_resources=lax" ];
  boot.kernelModules = [ "spd5118" ];
  environment.systemPackages = [ pkgs.lm_sensors ];
}
