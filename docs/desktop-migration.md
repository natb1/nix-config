# Plan — WSL → native NixOS, with one Windows that boots bare metal or virtualized

Written 2026-09-20. This is the *second* migration this repo tracks: [TODO.md](../TODO.md)
is about finishing the move off `commons.systems`. This one is about the desktop
stopping being a Windows box that hosts NixOS, and becoming a machine that runs
NixOS natively and can start the *existing* Windows install as a
GPU-passthrough guest — the same install that still boots bare metal when a game
demands it.

**There is exactly one Windows.** It is not reinstalled, not repartitioned, and
not duplicated. It keeps the whole fast NVMe, and that drive's controller is
handed to the guest by VFIO, so the guest sees the same disk, on the same
hardware path, as bare metal does. NixOS moves entirely to the bulk drive.

That single decision is what makes the rest small:

| Because there is one install… | …this goes away |
| --- | --- |
| Windows' disk is touched once, by 1 GB | The big shrink, the ESP sharing, the drive image, the restore-from-backup risk |
| Disko never meets a Windows partition | Hand-partitioning, hand-written `fileSystems`, `configurationLimit = 3` |
| One install means one license | The unactivated second copy, and the rule against signing into it |
| Metal and guest are the same C:\ | Two config profiles, the drift between them, the answer file, the image build |

What it costs, stated up front rather than discovered in Phase 4: **NixOS root
lands on the bulk drive**, activation needs the guest to
[impersonate the host's hardware](#keeping-activation-stable-across-the-crossing),
and the fast NVMe controller must sit in a clean IOMMU group — a second gate
alongside the GPU's.

Sequencing: **finish TODO.md §1–§3 first.** Switching the WSL host onto this
repo is the cheap, reversible change that proves the repo works. Repurposing the
desktop's drives is neither. Do not stack them.

---

## Decisions locked in

| Question | Answer | What it rules out |
| --- | --- | --- |
| GPU topology | dGPU → guest, AMD iGPU → NixOS | Single-GPU teardown hooks; the host never goes headless |
| How many Windows installs | **One.** The existing one, booted bare metal *or* as a guest | A separate VM image; an unactivated second copy; two config profiles |
| How the guest gets its disk | **VFIO the whole fast NVMe controller** | Repartitioning Windows; a `qcow2`; virtio storage drivers |
| Where NixOS lives | Entirely on the bulk drive, which disko owns outright | Disko ever meeting a Windows partition |
| Anti-cheat | Boot bare metal for it | Hypervisor hiding; giving up those titles |
| Windows config rigor | One Nix-rendered WinGet DSC profile in this repo, applied to the one install | Per-boot-mode divergence; hand-clicking |
| Drift repair | Converge; in-place repair install as the last resort | Rebuilding — there is nothing disposable left |

Four consequences worth stating up front:

1. **Windows' disk is modified exactly once, by 1 GB.** Phase 0 found Windows'
   ESP on the *other* drive, so it needs one of its own first — see
   [The ESP is on the wrong drive](#the-esp-is-on-the-wrong-drive). After that
   the fast NVMe stays exactly as it is. Every step that made the previous version of this plan dangerous —
   shrinking `C:`, sharing an ESP, hand-editing a partition table with the
   license behind it — is simply gone. The riskiest remaining operation is
   installing NixOS onto a drive that, once Windows boots from its own ESP, holds nothing that matters.
2. **Bare metal and guest are the same installation.** Not "kept in sync" — the
   same `C:\`. A package installed in the guest is installed on bare metal,
   because there is no distinction to maintain. This is the strongest possible
   version of the consistent-management requirement, and it is why
   [Phase 6](#phase-6--managing-the-one-windows-install) is short.
3. **The two boot modes are mutually exclusive, and the sharp edge moved.** They
   still cannot run at once. But the failure mode is no longer "two installs
   drift"; it is **booting bare metal while the guest is saved rather than shut
   down**, which corrupts the filesystem. See [Risks](#risks-ranked) 1.
4. **Do not hide the hypervisor.** The `<kvm><hidden state='on'/></kvm>` +
   spoofed `vendor_id` trick exists to dodge anti-cheat and *costs* performance,
   because it disables the Hyper-V enlightenments Windows uses to run fast under
   KVM. Anti-cheat titles boot bare metal, where they are supported. Skip the
   trick and take the enlightenments.

Note that consequence 4 is now cheap in a way it was not before: "boot bare
metal for it" means rebooting into the install you already have, with the games
already installed, because it is the same install.

### Phase 0, Windows side — measured 2026-09-21

Collected from the bare-metal Windows install (non-elevated). Everything below
that Windows can see is settled; what needs Linux or an elevated prompt is in
[Still unknown](#still-unknown).

| Item | Measured | Consequence for this plan |
| --- | --- | --- |
| Board / BIOS | Gigabyte **B650I AORUS ULTRA** (mini-ITX), AMI BIOS **F9d** (2023-09) | Mini-ITX has **one** x16 slot: "move the card to another slot" is not an IOMMU-gate fallback here. The BIOS is old; updating AGESA before Phase 0's Linux pass is cheap and can only improve the groups |
| CPU / RAM | Ryzen 5 **7600X**, 6C/12T, **one CCD**; **32 GB** RAM; SVM enabled in firmware | No cross-CCD concern. Phase 5's numbers were written for a 16-core/64 GB box and are now corrected — guest 4C/8T + 16 GiB, host 2C/4T |
| dGPU | **Radeon RX 6600 XT** (Navi 23, RDNA2) `1002:73ff` + HDMI audio `1002:ab28`, Windows PCI bus 3 fn 0/1 | RDNA2: **no `vendor-reset`**. Both IDs are unique on this box, so `vfio-pci.ids` is safe *for the GPU* |
| iGPU | Raphael `1002:164e` | Host graphics; different ID from the dGPU, so the `vfio-pci.ids` match cannot catch it |
| SSDs | **Both SK hynix Platinum P41** (`SHPP41-1000GM`, `SHPP41-2000GM`), both NVMe, controller ID **`1c5c:1959` on both** | (1) There is no fast/bulk split — same drive family, same performance, so the `fio` worry and [Risk 7](#risks-ranked) evaporate. (2) **[Risk 3](#risks-ranked) is confirmed**: `vfio-pci.ids` would take both controllers. Bind by PCI address — [Phase 4](#phase-4--vfio-and-the-libvirt-host) |
| Windows' drive | `C:` is the **2 TB** P41 (Windows disk 1, CPU-attached controller), 1862 GB NTFS, **89 GB free**. Its partitions: MSR, `C:`, WinRE — **no ESP** | Steam is on `C:` (`C:\Program Files (x86)\Steam`, the only library) and stays. 89 GB free is thin but not a blocker |
| The other drive | The **1 TB** P41 (Windows disk 0, chipset controller) is **not empty**: a 1 GB ESP marked System, plus five Linux-filesystem partitions (31 + 244 + 585 + 39 + 31 GB) | **Two plan-breaking facts** — see [The ESP is on the wrong drive](#the-esp-is-on-the-wrong-drive). Those five partitions are an old Linux install — **disposable, no backup needed** (confirmed 2026-09-21) |
| Windows' RTC | `RealTimeIsUniversal = 1` — Windows already keeps the RTC in **UTC** | `time.hardwareClockInLocalTime = true` would *create* the clock fight it was meant to prevent. Removed from `disko.nix`; NixOS's UTC default is correct |
| Fast Startup | Was **on**; `powercfg /h off` run 2026-09-21, `powercfg /a` now reports hibernation not enabled and Fast Startup unavailable | Done. Re-check after feature updates — [Risk 6](#risks-ranked) |
| BitLocker | `manage-bde -status`: C: **Fully Decrypted**, no key protectors | Nothing to do; the guest will boot without a recovery prompt. Watch for Device Encryption re-enabling itself — [Risk 8](#risks-ranked) |
| Secure Boot | `Confirm-SecureBootUEFI` → **False** | Already off. systemd-boot installs without lanzaboote |
| SMBIOS | system/board manufacturer `Gigabyte Technology Co., Ltd.`, product `B650I AORUS ULTRA`, serials `Default string`, UUID `03560274-043C-0547-E806-FF0700080009` | The `<sysinfo>` block in the licensing section can be filled from this (confirm against `dmidecode` in Phase 0 — Windows byte-swaps the first three UUID fields on some firmware) |
| Network | Windows runs on **Wi-Fi** (MediaTek RZ616 / MT7922, MAC `F0:A6:54:14:9B:0D`); the Intel I225-V wired port (`74:56:3C:47:E8:FF`) is **disconnected** | Guest `<mac>` for activation = the Wi-Fi MAC. And a Wi-Fi-only host cannot bridge the guest onto the LAN — NAT it, or plug in the cable. Samba's `<FILL_ME_LAN_IF>` is whichever of these NixOS uses |
| WSL | Still hostname `nixos`, generation `nixos-system-nixos-26.11.20260831`; `/etc/nixos` stubs still present | [TODO.md](../TODO.md) §1–§3 have **not** been applied yet |

### Still unknown

- **IOMMU groups** for the dGPU (bus 3) and the **2 TB** NVMe controller. Still
  the hard gate, and still only answerable from Linux. The CPU-attached slot is
  the likelier of the two to be cleanly grouped, which is the good news.
- **SMART wear** on both P41s (`smartctl -a`, or elevated
  `Get-PhysicalDisk | Get-StorageReliabilityCounter`).
- Linux CPU numbering for pinning — Phase 5 assumes the usual Ryzen layout
  (SMT sibling of CPU *n* is *n*+6); `lscpu -e` confirms it.

---

## What this buys the repo

Not just a new host — it deletes a whole category of complexity. Four of this
repo's gnarliest modules exist *only* because NixOS is a guest under Windows:

| Module | Lines of "why this is weird" | Fate |
| --- | --- | --- |
| `hosts/wsl/mounts.nix` | drvfs + autofs ELOOP trap, boot-order poll, stale-mount healer timer | **Deleted.** Replaced by rclone (§3) |
| `modules/home/wezterm.nix` copy-to-Windows activation | three-tier Windows-username detection, five error codes, ~500 lines of shell test | **Deleted** |
| `hosts/wsl/home/wezterm-windows.nix` | content-pinned nightly zip against a rolling URL, currently inert | **Deleted** — and this retires [TODO.md §6](../TODO.md)'s pin problem outright |
| `hosts/wsl/home/claude-in-chrome.nix` | `.bat` shim, HKCU registry write, extension-dir symlink across `/mnt/c` | **Deleted.** Native Chrome needs none of it |

It also forces [TODO.md §5](../TODO.md) (the WSL-only split) to happen, because
the `pkgs.stdenv.isLinux` guards in `modules/home/wezterm.nix` become *actively
wrong* the moment a second Linux host exists — which is exactly what the
module's own comment predicts.

---

## Phase 0 — Inventory and the go/no-go gate

**Nothing is destroyed in this phase, and — unlike every earlier draft of this
plan — nothing is destroyed in Phase 2 either.** Windows keeps its drive
untouched. WSL2 does not expose the PCI bus, so this still has to be done from a
NixOS live USB. Boot it, run the following, and save the output somewhere off
this machine (the Mac, or the Drive folder).

```sh
# 1. Confirm AMD-Vi is actually on. Empty output = IOMMU disabled in BIOS.
dmesg | grep -i -e AMD-Vi -e IOMMU

# 2. Both GPUs, their PCI addresses, vendor:device IDs, and current drivers.
lspci -nnk | grep -A3 -E 'VGA|3D|Display|Audio device'

# 3. Both NVMe controllers, and which drive hangs off which.
lspci -nnk -d ::0108
ls -l /sys/block/nvme*n1/device/device     # controller PCI address per drive

# 4. IOMMU groups. THIS IS THE GATE — and it is now a two-part gate.
for g in /sys/kernel/iommu_groups/*/devices/*; do
  n=${g#*/iommu_groups/}; n=${n%%/*}
  printf 'group %3s  ' "$n"; lspci -nns "${g##*/}"
done | sort -h

# 5. Core topology, for pinning later.
lscpu -e
lstopo-no-graphics --of txt   # pkgs.hwloc — shows CCD/L3 boundaries

# 6. OPTIONAL now: both drives are the same P41 model, so this only confirms
#    the 1 TB is not degraded relative to the 2 TB.
fio --name=r --rw=randread --bs=4k --iodepth=32 --numjobs=4 --size=2G \
    --runtime=30 --time_based --group_reporting --filename=/dev/<BULK>
```

**The gate, part 1 — the dGPU.** The card and its HDMI-audio function must sit
in an IOMMU group containing nothing else the host needs.

**The gate, part 2 — the fast NVMe controller.** New, and specific to this
layout: the guest gets that controller by VFIO, so it must also sit in a group
containing nothing the host needs. This is usually fine — chipset-attached and
CPU-attached NVMe slots are commonly their own groups — but it is not
guaranteed, and it is not a detail you can discover later.

- Both clean → proceed.
- Dirty group → try moving the card (or the drive) to a different slot first.
  Failing that, `pcie_acs_override=downstream,multifunction` splits groups but
  requires a patched kernel and **defeats the isolation IOMMU exists to
  provide**. Treat it as a last resort you accept knowingly, not a default.
- **The NVMe group is dirty and cannot be fixed** → this layout is out. The
  fallback is block-device passthrough of the Windows partitions instead of
  VFIO of the controller: same single install, same everything else, but the
  guest sees a virtio or SATA controller, which means installing those drivers
  from bare metal first and accepting a storage-driver difference between the
  two boot modes. Worse, not fatal.
- No IOMMU at all → enable SVM + IOMMU in BIOS and re-run. If the board truly
  has neither, the guest half of this plan is dead; bare-metal Windows is
  unaffected, since it is simply the machine as it is today.

Also in Phase 0:

- [ ] `nixos-generate-config --no-filesystems --show-hardware-config` from the
      live USB → this is `hosts/desk/hardware-configuration.nix`
- [ ] Record `/dev/disk/by-id/` names for every drive (by-id, not `/dev/nvme0n1` —
      by-id is stable across reboots and is what disko should reference)
- [ ] `smartctl -a` each SSD: model, capacity, and the wear indicator
      (`Percentage Used` on NVMe). The bulk drive now holds NixOS root as well
      as the media volume, so its wear matters more than it used to
- [ ] Inventory the game library: which titles, and what ProtonDB says about
      each. Every title that runs native under Proton is a title neither boot
      mode has to serve
- [x] Record how much free space the fast drive has — *89 GB free on the 2 TB
      `C:`; Steam's only library is on `C:` and stays there*
- [ ] **Give Windows its own ESP on the 2 TB drive** and prove it boots —
      [The ESP is on the wrong drive](#the-esp-is-on-the-wrong-drive). Hard
      precondition for Phase 2
- [x] Identify what is on the 1 TB drive's five Linux partitions — *an old
      Linux install; disposable, no backup needed*
- [x] **`powercfg /h off`** from an elevated prompt — *done 2026-09-21*. Disables hibernation and
      with it Fast Startup. Non-negotiable here: Fast Startup means "shutdown"
      leaves the NTFS dirty and the volume mid-flight, and the whole premise of
      this plan is that the *same* filesystem gets mounted by two different
      Windows boots
- [x] **BitLocker: `manage-bde -status`** — *off: Fully Decrypted, no protectors*. If it is on, it must be disabled or
      moved to a password protector before the guest will boot. A TPM-sealed
      key is sealed against the host's measurements; the guest presents a
      different (virtual) TPM and different firmware, so the key will not
      unseal and every guest boot lands in recovery. Save the recovery key off
      this machine before changing anything
- [x] **Secure Boot off** in firmware — *already off* (or lanzaboote later). Do this *after*
      BitLocker is handled, not before
- [x] Record the SMBIOS values the guest will need to impersonate — *from
      Windows, in the table above; cross-check with `dmidecode`* — see [below](#keeping-activation-stable-across-the-crossing)
- [x] Settle the licensing question below — **resolved: RETAIL, digital
      license, linked to the Microsoft account, and there is only one install,
      so it simply keeps it.** No wipe, no second copy, nothing to time

### Windows licensing — resolved

**Answer for this machine: RETAIL, digital license, already linked to the
Microsoft account — and there is only one install, so it simply keeps it.**
Nothing in this plan touches activation state, and there is no key to protect.

Measured on the pre-migration install:

| Field | Value | Consequence |
| --- | --- | --- |
| `ProductKeyChannel` | `Retail` | The virtualization clause below applies |
| `LicenseFamily` | `Professional` | Pro edition — and Pro is what the guest needs anyway, since Home lacks the Hyper-V-adjacent bits some setups want |
| `PartialProductKey` | `3V66T` | The tail of `VK7JG-NPHTM-C97JM-9MPGT-3V66T`, Microsoft's published generic Pro key — *not* a per-machine key |
| `OA3xOriginalProductKey` | empty | No MSDM table, so not an OEM preinstall |
| Activation panel | *"activated with a digital license linked to your Microsoft account"* | Already linked; this install keeps the entitlement |

The two facts that matter downstream: **there is no key string to recover or
keep out of git** — the entitlement lives on the Microsoft account, and the key
installed today is a public placeholder — and **activation travels through that
account**, which is what makes it recoverable if the guest ever does look like
new hardware.

#### One install, one license — which is the cleanest reading available

The clause everyone quotes is *"**instead of** using the software directly on
the licensed device, you may install and use the software within **only one**
virtual (or otherwise emulated) hardware system on the licensed device."*
"Instead of" is substitution, and "only one" bounds it.

With one installation booted two ways, that is satisfied without argument:

- There is **one** copy of the software, on **one** licensed device.
- It is used **either** directly on the device **or** inside **one** VM, never
  both, because they cannot run simultaneously.

This is worth dwelling on because the earlier two-install plan did *not* have
this property. That plan ran a second, unactivated copy — permitted to run,
but not licensed — and papered over it with a rule about never signing in.
Collapsing to one install removes the compromise rather than managing it. **The
"never sign into the guest" rule is gone.** Sign in freely; it is the same
Windows, the same account, the same license.

#### Keeping activation stable across the crossing

The remaining risk is mechanical, not legal. Windows derives a hardware hash
from several identifiers, and a guest that presents different ones looks like a
hardware change. In the worst case you land on "Windows is not activated" and
have to run the Activation Troubleshooter, which Microsoft rate-limits.

**The fix is to make the guest present the host's identity.** Configure this
once in the domain XML and the crossing is uneventful:

```xml
<!-- Match the metal. Values come from Phase 0's dmidecode. -->
<sysinfo type='smbios'>
  <system>
    <entry name='manufacturer'>[host's SMBIOS system manufacturer]</entry>
    <entry name='product'>[host's product name]</entry>
    <entry name='serial'>[host's system serial]</entry>
    <entry name='uuid'>[host's system UUID]</entry>
  </system>
  <baseBoard>
    <entry name='manufacturer'>[host's board manufacturer]</entry>
    <entry name='product'>[host's board product]</entry>
    <entry name='serial'>[host's board serial]</entry>
  </baseBoard>
</sysinfo>
<os><smbios mode='sysinfo'/></os>
<cpu mode='host-passthrough' check='none' migratable='off'/>
```

Collect the values from the live USB in Phase 0 — after NixOS is installed is
fine too, they do not change:

```sh
dmidecode -t system -t baseboard
ip link show          # note the MAC of the NIC Windows uses on bare metal
```

Then give the guest's virtual NIC that same MAC (`<mac address='…'/>`), and
pass the dGPU through in both modes, which happens anyway.

Two honest caveats. Microsoft does not publish which components the hash weights
or by how much, so this is community practice that works rather than a
documented contract — expect it to hold, verify it in
[Phase 8](#phase-8--cutover-qa), and do not be shocked by one Troubleshooter run
while tuning. And a digital license linked to a Microsoft account is exactly the
kind that recovers gracefully when it does slip: sign in, "I changed hardware on
this device recently", done. That link, already in place, is the safety net that
makes this whole approach low-stakes.

#### How the above was determined

Kept because it is the procedure for any future machine, not just this one. From
the Windows install, before it is destroyed:

```powershell
# Channel and edition. Look for RETAIL vs OEM_DM / OEM_COA_* in Description.
Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" |
  Select-Object Name, Description, PartialProductKey,
                ProductKeyChannel, LicenseFamily

# The OEM key embedded in the board's firmware, if there is one. Empty means
# there is no MSDM table, i.e. this was not an OEM preinstall.
# (`wmic` is removed by default on Windows 11 24H2+ — use the CIM call.)
(Get-CimInstance -ClassName SoftwareLicensingService).OA3xOriginalProductKey
```

Then **Settings → System → Activation**, and read the wording exactly: *"digital
license linked to your Microsoft account"* is the good case; *"digital license"*
without *"linked"* means the link is still to be made, and that is the step that
cannot be done after a reinstall — which this plan never performs, but which is
why it was worth confirming early.

A firmware key, where one exists, is also readable from Linux once NixOS is
installed — not useful on this machine, since there is no MSDM table:

```sh
strings /sys/firmware/acpi/tables/MSDM | grep -Eo '[A-Z0-9]{5}(-[A-Z0-9]{5}){4}'
```

**Why RETAIL settles it** is [above](#one-install-one-license--which-is-the-cleanest-reading-available)
— the "Use with Virtualization Technologies" clause, and why one install booted
two ways satisfies it without argument.

**The OEM branch, not taken, kept for the reasoning.** Had the channel been OEM
(`OEM_DM` — preinstalled by the vendor, key in the MSDM table), Microsoft's
stated position is that OEM keys cover physical instances only and carry no
virtualization rights. The VM presents a different hardware hash, so it would
not auto-activate. It *can* be made to activate by passing the host's own MSDM
ACPI table and SMBIOS strings through to the guest
(`-acpitable file=/sys/firmware/acpi/tables/MSDM` plus libvirt `<sysinfo>`), a
well-documented technique — but note what that does and does not do: it makes
the guest activate, it does not change the license terms. The empty
`OA3xOriginalProductKey` above retires this path. Note the family resemblance to
the SMBIOS impersonation this plan *does* use: same mechanism, but here it
keeps one licensed install recognising its own machine rather than making an
unlicensed one pass for licensed.

#### Remaining licensing checklist

- [x] The license is linked to the Microsoft account — *the Activation panel
      confirms it.* This was the one irreversible step in earlier drafts of this
      plan, done before it was needed, and it is now the safety net rather than
      a prerequisite.
- [x] Record the channel and the key — *the table above is that record. There is
      no key beyond the generic one.*
- [ ] Confirm this PC is listed at `account.microsoft.com/devices` and note the
      name it appears under — that is how you identify it in the Activation
      Troubleshooter if the guest ever fails to activate.
- [x] ~~Budget for a second Windows license~~ — not needed. One install, one
      license, no line item.

---


## Phase 1 — Land `hosts/desk` in the flake

**Do this from the WSL box, before the wipe.** It evaluates and builds without
touching hardware, so a broken config is found while there is still a working
machine to fix it from.

### Naming

Per the README's own rule, `networking.hostName` is simultaneously the Tailscale
node name, what avahi publishes, and the wezterm mux domain — they move
together. Proposal: **`desk`**. It is a new Tailscale node, not a rename of
`wsl`; the `wsl` node gets removed from the admin panel at the end (§9).

The libvirt domain for the guest is **`win`** throughout this document — the
performance hook keys on that name, so pick it once.

### New flake inputs

```nix
disko = {
  url = "github:nix-community/disko";
  inputs.nixpkgs.follows = "nixpkgs";
};
NixVirt = {
  url = "https://flakehub.com/f/AshleyYakeley/NixVirt/*.tar.gz";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

`inputs.nixpkgs.follows` on both, matching how every existing input in this
flake is wired.

### New host output

```nix
nixosConfigurations.desk = nixpkgs.lib.nixosSystem {
  specialArgs = { inherit inputs; };
  modules = [
    disko.nixosModules.disko
    inputs.NixVirt.nixosModules.default
    ./hosts/desk
    home-manager.nixosModules.home-manager
    (home {
      hostPlatform = "x86_64-linux";
      homeDirectory = "/home/n8";
      extraModules = [ ./hosts/desk/home ];
    })
  ];
};
```

### Where the desktop config goes — and why not `modules/nixos/`

The README's rule: *"A module lives in `modules/` only if it evaluates correctly
on every host."* `modules/nixos/default.nix` is imported unconditionally by
every Linux host, so a display manager, PipeWire, Steam and libvirtd cannot go
there — WSL would get all of it.

So the desktop stack starts **host-scoped** under `hosts/desk/`:

```
hosts/desk/
  default.nix                 # hostname, stateVersion, imports, user extraGroups
  hardware-configuration.nix  # from Phase 0
  disko.nix                   # partitioning — the BULK DRIVE ONLY
  desktop.nix                 # display manager, PipeWire, fonts, browser
  gaming.nix                  # steam, gamemode, mangohud, native-Proton side
  vfio.nix                    # IOMMU, vfio-pci binding (dGPU + fast NVMe), kvmfr
  libvirt.nix                 # libvirtd, OVMF, swtpm, the NixVirt domain
  perf-hook.nix               # the while-the-VM-runs tuning (§5)
  windows/                    # the DSC profile Windows pulls and applies (§6)
  home/                       # host-only home modules
```

Promote a file to `modules/nixos/` the day a *second* machine wants it — not
before. That is the same discipline `hosts/wsl/home/` already follows.

### The one landmine in the shared modules

`modules/nixos/tailscale.nix` defines `systemd.services.tailscaled-wsl-rebind`,
which runs `ip monitor address` forever and restarts `tailscaled` whenever
`eth0` gains an address. That is a workaround for **the WSL2 NAT adapter
rotating its IP**, documented as such in the module's own comment — and
`modules/nixos/` is imported by every Linux host, so `desk` would inherit it.

On a native box with predictable interface naming (`enp*`/`eno*`) it would
never match and would sit idle, but it is still a WSL artifact shipped to a
non-WSL host, and it is a live footgun if anything ever names an interface
`eth0`.

- [ ] Move `tailscaled-wsl-rebind` out of `modules/nixos/tailscale.nix` and into
      `hosts/wsl/`. Do it as its own commit, before adding `desk`, so the diff
      that adds the host is not also a refactor.

Also host-scoped, because the group does not exist on WSL and listing a
nonexistent group fails activation:

```nix
# hosts/desk/default.nix
users.users.n8.extraGroups = [ "libvirtd" "kvm" "input" ];
```

### Disk layout — one drive each

The clean split that makes everything else work:

| Drive | Owner | Contents | Touched by this plan? |
| --- | --- | --- | --- |
| **2 TB P41** ("fast" below) | Windows, entirely | MSR, `C:`, WinRE as they are today, **plus a new ESP** carved from `C:` — see below. Steam library stays on `C:` | **Once**, before anything else: a ~1 GB shrink of `C:` and a new ESP. Then never again |
| **1 TB P41** ("bulk" below) | NixOS, entirely | ESP, `/`, `/srv/media` | Yes — disko formats the whole thing, **after** Windows stops booting from it |

Phase 0 found the two drives are the same model, so "fast" and "bulk" are now
just names for "Windows' drive" and "NixOS' drive"; they are kept below so the
rest of this document still reads.

#### The ESP is on the wrong drive

Phase 0's biggest finding. **Windows' bootloader does not live on Windows'
drive.** The 2 TB drive holds MSR, `C:` and WinRE and no ESP; the only ESP is
on the 1 TB drive — the one this plan hands to disko. Two consequences, each
fatal on its own:

1. Disko formatting the 1 TB drive deletes `bootmgfw.efi` and the BCD. Bare-metal
   Windows stops booting.
2. The guest only gets the 2 TB drive's controller. OVMF finds no ESP on it and
   has nothing to boot.

This is the classic result of installing Windows with another drive present:
setup puts the ESP on whichever disk the firmware enumerates first. **The fix is
to give Windows its own ESP on its own drive, from bare metal, before Phase 2**:

```powershell
# Elevated. Shrinks C: by 1 GB (89 GB free, so plenty) and makes an ESP from it.
$c = Get-Partition -DriveLetter C
Resize-Partition -DriveLetter C -Size ($c.Size - 1GB)
$esp = New-Partition -DiskNumber $c.DiskNumber -Size 1020MB `
         -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
Format-Volume -Partition $esp -FileSystem FAT32 -NewFileSystemLabel SYSTEM
$esp | Add-PartitionAccessPath -AccessPath S:
bcdboot C:\Windows /s S: /f UEFI       # writes bootmgfw.efi + a fresh BCD, adds an NVRAM entry
$esp | Remove-PartitionAccessPath -AccessPath S:
```

Then reboot into the **new** entry from the firmware boot menu (the drive-2
"Windows Boot Manager"), confirm Windows starts and is still activated, and only
then treat the 1 TB drive's ESP as disposable. The shrink can fail if an
unmovable file sits at the end of `C:` — WinRE sits *after* `C:`, so this
usually succeeds; if it does not, `reagentc /disable` + retry, then re-enable.

This is the one place the plan touches Windows' drive after all, and it is
worth being exact about why it is acceptable: it is a 1 GB shrink with a
backstop — the old ESP stays bootable until the new one is proven, so there is
never a moment when nothing boots.

The WinRE partition sitting after `C:` means Windows' own recovery stays wired
to the old BCD; `reagentc /info` after the move should point at the new one
(`reagentc /disable` then `/enable` re-registers it).

**Disko gets a whole drive again, and the awkwardness of the previous draft
disappears with it.** No hand-partitioning, no hand-written `fileSystems`, no
100 MB ESP shared with Windows, no `configurationLimit = 3`. NixOS gets a 1 GiB
ESP of its own and as many generations as it likes, because nothing else is
competing for the space.

The fast drive is absent from `disko.nix` for the same reason it was before —
disko would recreate its table — but the danger is much lower now: there is no
partial description of it anywhere, and nothing about the install procedure
brings it near a formatting tool.

```nix
# hosts/desk/disko.nix — the BULK DRIVE ONLY.
#
# The fast NVMe is deliberately absent. It belongs to Windows, and this host
# never mounts it: its controller is bound to vfio-pci at boot (see Phase 4)
# and handed to the guest whole. Adding it here for "completeness" would
# destroy the Windows install.
{
  disko.devices.disk.bulk = {
    device = "/dev/disk/by-id/nvme-<FILL_ME_BULK>";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem"; format = "vfat";
            mountpoint = "/boot"; mountOptions = [ "umask=0077" ];
          };
        };

        root = {
          size = "<FILL_ME>G";
          content = { type = "filesystem"; format = "ext4"; mountpoint = "/"; };
        };

        # OPTIONAL — only if Phase 0 finds the fast drive too full for the
        # Steam library. Deliberately no `content`: disko creates the partition
        # and stops. Windows formats it NTFS once and uses it in both boot
        # modes; the host never mounts it. See "Where the Steam library lives".
        # games.size = "<FILL_ME>G";

        media = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-L" "media" ];
            subvolumes."/media" = {
              mountpoint = "/srv/media";
              mountOptions = [ "noatime" ];
            };
          };
        };
      };
    };
  };

  # NOT time.hardwareClockInLocalTime. Phase 0 found this Windows already has
  # RealTimeIsUniversal = 1, i.e. keeps the RTC in UTC — NixOS's default.
  # Setting localtime here would create the clock fight, not prevent it.
}
```

#### Where the Steam library lives

**Default: leave it on the fast drive, wherever it is today.** Windows owns
that whole disk and the guest gets the whole controller, so the library comes
along in both boot modes with no configuration whatsoever. This is the option
with zero moving parts, and it is available exactly because the drive is not
being carved up.

**Fallback, if Phase 0 finds the fast drive too full:** a dedicated partition on
the bulk drive, formatted NTFS by Windows, handed to the guest as a raw block
device and mounted by drive letter on bare metal. That works, but it reintroduces
a seam — the guest now has one disk by VFIO and one by block passthrough, and
the host must never mount the NTFS. Take it only if capacity forces it.

Note what is *not* an option: putting the library on `/srv/media` and reaching
it over SMB. Loading times over a network share are not worth discussing.

#### Two ESPs, and the boot menu

Each drive has its own ESP, which is tidy but has one visible consequence:
**systemd-boot will not list Windows.** It auto-discovers `bootmgfw.efi` only on
the ESP it booted from, and Windows' ESP is on the other drive.

Options, in increasing order of effort:

1. **Use the firmware's boot menu** (F8/F11/F12, board-dependent) to pick
   Windows. Both ESPs have NVRAM entries, so both are listed. Zero
   configuration, one extra keypress on the rare occasions you boot bare metal.
2. `efibootmgr -o <order>` from NixOS to put systemd-boot first permanently, so
   the default is NixOS and Windows is the deliberate choice. Worth doing
   regardless — see the note in [Phase 2](#phase-2--install-nixos-on-the-bulk-drive).

Given that booting bare metal is the exception rather than the routine — the
guest handles everything except kernel anti-cheat — option 1 is the right
default and option 2 is the polish.

#### Why btrfs for media and ext4 for root

The media volume's job is holding files nobody opens for months, which is
exactly the condition under which silent corruption goes unnoticed — and restic
will faithfully back up a corrupted file without complaint. btrfs checksums
every block, so a monthly `services.btrfs.autoScrub` turns bit rot into an alert
instead of a surprise in 2029. Snapshots come along for free and cover the
likelier loss: an accidental delete you want undone in seconds rather than
restored from Hetzner.

No compression — the payload is already-compressed video, so btrfs would decline
the extents anyway and the CPU is better spent elsewhere.

Root stays ext4: boring, fast, and nothing about `/` wants snapshots badly
enough to pay for them.

**Once this drive holds media, `disko --mode disko` is a destructive command.**
It is only meant to run at install, but it is sitting right there in Phase 2's
copy-pasteable block and it wipes every disk it manages — which, now that root
lives there too, means the whole NixOS side. Post-install, the only disko mode
that should ever touch this machine is `--mode mount`. The Hetzner backup is
what makes that a bad afternoon rather than a permanent loss, which is the
clearest argument for doing Step 2 early rather than "once there's something
worth backing up".

The one consolation: Windows is on the other drive, and this command cannot
reach it.

---

## Phase 2 — Install NixOS on the bulk drive

**An ordinary clean NixOS install on an empty disk.** The fast drive is not
mentioned, not mounted, and not passed to any command in this section. Read
[Disk layout](#disk-layout--one-drive-each) first.

Preconditions from Phase 0: both IOMMU gates pass, **Windows boots from its own
ESP on the 2 TB drive**, Fast Startup is off, BitLocker is off or on a
password protector, and Secure Boot is off.

```sh
# The bulk drive is disko's, and it is empty, so the destructive mode is
# correct here — exactly once, and never again. Double-check the by-id name in
# disko.nix before running this: it is the one line standing between you and
# the wrong disk.
nix --extra-experimental-features 'nix-command flakes' \
  run github:nix-community/disko -- --mode disko \
  --flake /path/to/nix-config#desk

nixos-install --flake /path/to/nix-config#desk
```

That is the whole install. No hand-partitioning, no PARTUUID transcription, no
`blkid` round trip — disko generated the `fileSystems` entries from the same
declaration it partitioned with.

Then reboot and **verify both boot paths before going further**, while the live
USB is still plugged in:

- [ ] NixOS boots from the bulk drive
- [ ] Windows still boots bare metal from the firmware boot menu, and is still
      activated (Settings → System → Activation). Nothing should have changed —
      confirming that is the point
- [ ] Clocks agree after crossing between them — both sides keeping the RTC in
      UTC (`RealTimeIsUniversal = 1` on Windows, the default on NixOS)
- [ ] `efibootmgr -o` puts systemd-boot first, so NixOS is the default and
      Windows is the deliberate choice

Then `sudo tailscale up`, `git clone` the repo to `~/natb1/nix-config`, and from
there it is the same `nixos-rebuild switch --flake .#desk` loop as every other
host.

- [ ] Add a `desk` row to the README's host table with its rebuild command

**Windows updates will sometimes reassert themselves as the default boot
entry.** Normal, not a failure: `efibootmgr -o` puts systemd-boot back in front.
Worth knowing before it happens at an inconvenient moment.

---


## Phase 3 — Re-home what WSL was doing

### Google Drive (`/mnt/g`)

`hosts/wsl/mounts.nix` mounts `G:` via drvfs, which only works because Google
Drive for desktop is running on the Windows host. Native NixOS has no such host.

**Recommendation: rclone.** A systemd *user* unit mounting the Drive remote,
with `--vfs-cache-mode full` so writes behave. The boot-ordering gymnastics and
the stale-mount healer timer both disappear — rclone retries internally and the
mount is not gated on another OS booting first.

What carries over from the old module is the *lesson*, not the code: a network
mount that can vanish mid-session needs its failure to be loud, not silent.
Keep `RemainAfterExit` off and let systemd restart it.

Do **not** put Drive in the Windows VM. The VM is not always on, and making a
file sync depend on a guest being booted rebuilds the exact coupling this
migration removes.

### WezTerm

This is [TODO.md §5](../TODO.md), now mandatory. On `desk`, WezTerm is just a
GUI app:

- `default_prog = { 'wsl.exe', ... }` and
  `default_gui_startup_args = { 'connect', 'wsl' }` — **delete**. There is no
  `wsl.exe`.
- `home.activation.copyWeztermToWindows` — **delete**. Nothing to copy to.
- `wezterm-mux-server` — **keep**. It is still how the Mac gets a persistent
  remote session into this box. Its `lib.mkIf pkgs.stdenv.isLinux` guard becomes
  correct-by-accident rather than correct-by-design; make it explicit.
- The Tailscale `ssh_domains` auto-discovery — **keep**, unchanged. It picks up
  `desk` for free.
- `//wsl$/NixOS/...` identity-file paths — **delete** with the Windows branch.

The blocker TODO.md names is real: `tests/wezterm.test.nix` asserts the *guard
structure* (`_type == "if"`), and `tests/wezterm_test.sh` is ~500 lines
exercising the Windows-username fallback chain. That shell suite tests code that
is being deleted, so it goes with it — but read it first for anything it covers
that is not WSL-specific. **Do the test deletion in its own commit**, separate
from the module change, so `git log` shows the coverage loss was deliberate.

### Claude in Chrome

`hosts/wsl/home/claude-in-chrome.nix` exists purely to bridge Chrome-on-Windows
to `claude`-in-WSL through a `.bat` shim and an HKCU registry write. On native
NixOS, install Chrome and let Claude Code register its own native-messaging
host the normal way. **Delete the module**; do not port it.

### WezTerm's Windows GUI pin

`hosts/wsl/home/wezterm-windows.nix` and `windowsInstallEnabled` in
`modules/home/wezterm-pin.nix` go away with the WSL host. That closes
[TODO.md §6](../TODO.md)'s first bullet — the rolling-URL pin problem — without
needing the fix it proposes. Worth noting *why* it dies rather than gets fixed,
so the reasoning is recoverable.

Keep the lesson, though. It still applies to the one Windows artifact this plan
does pin: **`pkgs.virtio-win`**, hash-pinned in nixpkgs, for the NIC and balloon
drivers ([Phase 4](#phase-4--vfio-and-the-libvirt-host)). Pin immutable sources;
never a rolling URL.

---

## Media storage

Off the phase sequence deliberately. This needs Phases 1–2 (the box exists and
boots) and **nothing in the VM track depends on it**, so it can land the week the
machine is installed, months before any passthrough work.

The desktop has **two SSDs with different jobs**, and keeping them straight is
what the rest of this section rests on:

| Drive | Chosen for | Holds |
| --- | --- | --- |
| **fast** | latency | Windows, entirely — `C:` and, by default, the Steam library. NixOS never mounts it |
| **bulk** | capacity | NixOS `/`, `/srv/media`, and the Steam library only if the fast drive is too full — [Disk layout](#disk-layout--one-drive-each) decides |

This section is about the bulk drive's media volume. Note that `/` is now its
neighbour, which raises the stakes on the `disko --mode disko` warning below:
the destructive mode takes the operating system with the media now, not just
the media.

Two steps, in this order. The share is useful on day one; the backup is what
makes the share safe to depend on.

### Step 1 — `/srv/media` as a network share

**SMB, not NFS.** The clients are the MacBook and Windows — in either boot
mode, since bare metal reaches the share over the LAN like any other client and
the guest reaches it over the virtual network. NFS on macOS is a long-standing
disappointment — Finder integration,
locking, and UID mapping all fight you — and Windows needs SMB regardless. One
protocol both speak well beats two they each speak badly.

```nix
# hosts/desk/media.nix
{
  services.samba = {
    enable = true;
    openFirewall = false;              # opened per-interface below instead
    settings = {
      global = {
        "server string" = "desk";
        "workgroup" = "WORKGROUP";
        # LAN + tailnet only. Never bind this to a default-route interface.
        "interfaces" = "lo <FILL_ME_LAN_IF> tailscale0";
        "bind interfaces only" = "yes";
        "hosts allow" = "127.0.0.1 192.168.0.0/16 100.64.0.0/10";  # /10 = tailnet CGNAT
        "hosts deny" = "0.0.0.0/0";
        "server min protocol" = "SMB3";
        # macOS: resource forks and xattrs without littering ._ files everywhere.
        "vfs objects" = "catia fruit streams_xattr";
        "fruit:metadata" = "stream";
        "fruit:posix_rename" = "yes";
      };
      media = {
        path = "/srv/media";
        browseable = "yes";
        "read only" = "no";
        "valid users" = "n8";
        "force user" = "n8";
        "create mask" = "0644";
        "directory mask" = "0755";
      };
    };
  };

  # Discovery: mDNS for Finder, WS-Discovery for the Windows guest.
  services.samba-wsdd.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = { enable = true; userServices = true; };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 445 5357 ];
  networking.firewall.interfaces."<FILL_ME_LAN_IF>" = {
    allowedTCPPorts = [ 445 5357 ];
    allowedUDPPorts = [ 3702 ];
  };

  # Bit rot on a volume nobody reads for months is the failure you find out
  # about from a restore. Make it an alert instead.
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/srv/media" ];
  };

  # THE footgun. Without this, a bulk SSD that fails to mount leaves Samba
  # serving an empty /srv/media *on the root filesystem* — and clients cheerfully
  # write into it. Silent, and you find out when the root disk fills.
  systemd.services.samba-smbd = {
    after = [ "srv-media.mount" ];
    requires = [ "srv-media.mount" ];
  };
}
```

**Not managed by this repo:** Samba keeps its own password database, separate
from Unix accounts, so `smbpasswd -a n8` is hand-provisioned state. Add it to
the README's "State this repo does not manage" list (Phase 9 already touches
that list).

### Step 2 — backup, for when the bulk SSD dies

**`restic` → a Hetzner Storage Box.**

This is the one place in the repo where restic is unambiguously the right tool,
and the reason is worth recording: *the remote is never browsed.* `/srv/media`
is the browsable copy and always will be. A restic repository is opaque — a tree
of encrypted, content-addressed pack files with no filenames in it — which is
disqualifying for an archive you want to open and costs nothing at all for a
copy you only ever restore from. Use restic when the remote is write-only; use
`rclone` when a human has to read it.

Dedup, restic's headline feature, buys approximately nothing here — H.265 is
already compressed, so chunks do not repeat. What it does buy on this data:

- **client-side encryption**, mandatory — Hetzner holds ciphertext it cannot read
- **snapshots**, so a deletion in March is still recoverable in June
- **integrity checking**, so "is the backup readable" is a command, not a hope

#### Sizing and cost

| Target | Cost | Covers | Still exposed to |
| --- | --- | --- | --- |
| **Hetzner BX21** (5 TB) | **€10.90/mo** ≈ $142/yr | drive death, `rm -rf`, fire, theft, ransomware | Hetzner itself — RAID on one array in one building, [not mirrored to other servers](https://docs.hetzner.com/storage/storage-box/) |
| Hetzner BX31 (10 TB) | €20.80/mo | same | same |
| A local HDD (~6 TB) | ~$130 once | drive death **only** | anything that takes the whole machine, or the room it sits in |

Pick by whether the library is replaceable. Re-rippable or re-downloadable media
→ the HDD is sufficient and roughly $580 cheaper over five years. Irreplaceable
media → Hetzner, because the failure modes it adds coverage for (theft,
ransomware, an `rm -rf` nobody notices for a year) are each more likely than the
SSD death that prompted this.

**Start with Hetzner**, sized to the **media subvolume** rather than the whole
bulk drive. `/` is not in scope — it is declarative and rebuilt from this repo —
and if the games partition ends up on this drive at all, the host never mounts
it, so nothing on it can be swept into a backup either.
Adding a local HDD later as a fast-restore tier is additive — same restic
invocation, second repository — not a migration.

#### The unit

```nix
# hosts/desk/media.nix, continued
{
  services.restic.backups.media = {
    initialize = true;
    paths = [ "/srv/media" ];
    repository = "sftp:u<FILL_ME>@u<FILL_ME>.your-storagebox.de:/restic/media";
    passwordFile = "/etc/restic/media.password";        # 0600, hand-provisioned
    extraOptions = [
      "sftp.command='ssh -p 23 -i /etc/restic/id_ed25519 u<FILL_ME>@u<FILL_ME>.your-storagebox.de -s sftp'"
    ];
    extraBackupArgs = [ "--exclude-caches" "--one-file-system" ];
    pruneOpts = [ "--keep-daily 7" "--keep-weekly 5" "--keep-monthly 12" ];
    runCheck = true;
    checkOpts = [ "--read-data-subset=2%" ];            # samples, not a full download
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "2h";
      Persistent = true;                                # catch up after downtime
    };
  };

  # A backup whose failures are silent is not a backup. This repo has no
  # alerting yet; until it does, at minimum make the failure visible.
  systemd.services.restic-backups-media.unitConfig.OnFailure = "<FILL_ME_notify_unit>";
}
```

Verify the `services.restic.backups` option names against the pinned nixpkgs
before committing — that module has churned, and the flake tracks
`nixos-unstable`.

#### Three Hetzner specifics that are otherwise an evening

1. **SSH is on port 23, not 22.** Port 22 gives SFTP/SCP and no shell at all;
   port 23 is a restricted shell whitelisting `rsync`, `restic`, `rclone` and a
   few others. The backup tooling below needs 23.
2. **Key format differs by port.** Port 22 wants RFC4716
   (`---- BEGIN SSH2 PUBLIC KEY ----`); port 23 wants an ordinary one-line
   OpenSSH key. Use port 23 and a normal `ssh-ed25519 AAAA…` line.
3. **10 concurrent connections, account-wide.** Exceeding it surfaces as md5
   checksum errors mid-upload, which reads like corruption and is not. Pass
   `--checkers 4` (anything under 8) if it bites.

#### Worth doing: make the repository append-only

Hetzner's port-23 shell can run `rclone serve restic --stdio`, which means the
forced command in the Storage Box's `authorized_keys` can pin the desktop's key
to **append-only**:

```
command="rclone serve restic --stdio --append-only restic/media",restrict ssh-ed25519 AAAA… desk-restic
```

with restic pointed at that channel instead of the SFTP backend:

```nix
    repository = "rclone:";
    extraOptions = [
      "rclone.program='ssh -p 23 -i /etc/restic/id_ed25519 u<FILL_ME>@u<FILL_ME>.your-storagebox.de'"
    ];
```

The desktop can then add snapshots and cannot delete or rewrite them. A machine
that gets ransomwared, or a `restic forget` run against the wrong repository,
cannot take the backup down with it — which is the single largest upgrade
available here, and it is free.

The cost: pruning needs a second, unrestricted key that does not live on `desk`.
Keep it offline and run retention deliberately, a few times a year. That is the
correct trade — automatic pruning is also automatic deletion.

Which means **adopting append-only also means dropping `pruneOpts` from the unit
above.** Leave it in and every run fails at the forget step. Retention becomes a
manual job run from elsewhere with the unrestricted key; decide that consciously
rather than discovering it from a red timer.

#### Prove it works

A backup is a claim until it is restored. All four, before trusting it:

- [ ] `restic snapshots` **from the MacBook**, not from `desk` — proves the repo
      opens with only the password and key, and does not depend on the machine
      that made it
- [ ] Restore one large file to `/tmp` and `cmp` it byte-for-byte against the original
- [ ] Simulate the real failure: unplug the bulk SSD, boot, and confirm Samba
      refuses to serve rather than exposing an empty share — then restore into a
      fresh filesystem and time it
- [ ] `systemctl list-timers restic-backups-media` after a week, and confirm a
      deliberately broken run is actually noticed

#### Checklist

- [ ] Bulk drive partitioned as btrfs by disko (§1), with `autoScrub` enabled
- [ ] `hosts/desk/media.nix`, imported from `hosts/desk/default.nix`
- [ ] `smbpasswd -a n8`; mount from the Mac over both LAN and tailnet
- [ ] Order the Storage Box sized to the bulk drive; generate a dedicated
      ed25519 key for it
- [ ] `/etc/restic/media.password` and `/etc/restic/id_ed25519`, both 0600,
      added to the README's unmanaged-state list
- [ ] Append-only forced command, plus the offline prune key recorded somewhere
      that is not this machine
- [ ] The four restore proofs above

---

## Phase 4 — VFIO and the libvirt host

**Two devices go to the guest, not one:** the dGPU (plus its HDMI-audio
function) and **the fast NVMe controller**. The second is what makes the guest
boot the real Windows install off real hardware, and it is the piece that
distinguishes this plan from every earlier draft.

Binding the NVMe controller to `vfio-pci` means **the host can never see that
drive**. That is intended — NixOS lives on the bulk drive and has no business
touching Windows' disk — and it is also a useful safety property: a stray
`mkfs`, `fsck` or automount on the host physically cannot reach `C:`.

It does not affect bare-metal boots at all. VFIO binding is a NixOS-runtime
thing; when you boot Windows directly, the firmware hands it the controller as
usual.

```nix
# hosts/desk/vfio.nix
{ config, pkgs, lib, ... }:
{
  boot.kernelParams = [
    "amd_iommu=on"
    "iommu=pt"                       # passthrough mode: no DMA translation for host devices
    # RX 6600 XT + its HDMI audio function, from Phase 0. The NVMe controller
    # is deliberately NOT here: both drives are SK hynix P41s sharing
    # 1c5c:1959, so an ID match would take the host's root drive too. It is
    # bound by PCI address below.
    "vfio-pci.ids=1002:73ff,1002:ab28"
  ];

  # vfio must claim the card before amdgpu/nvidia can. initrd, not kernelModules.
  boot.initrd.kernelModules = [ "vfio_pci" "vfio_iommu_type1" "vfio" ];

  # The host's iGPU driver. amdgpu for a Ryzen APU.
  boot.kernelModules = [ "kvm-amd" "amdgpu" ];

  # Host graphics run on the iGPU. (hardware.opengl was renamed in 24.11.)
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;   # Steam/Proton need the 32-bit stack

  # No vendor-reset: Phase 0 found an RX 6600 XT (Navi 23, RDNA2), which resets
  # cleanly. Polaris/Vega would have needed it.
}
```

```nix
# hosts/desk/libvirt.nix
{ pkgs, ... }:
{
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      swtpm.enable = true;                    # Windows 11 requires a TPM
      ovmf.enable = true;
      ovmf.packages = [ pkgs.OVMFFull.fd ];   # Full: includes Secure Boot + TPM support
    };
  };
  programs.virt-manager.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;
  environment.systemPackages = [ pkgs.virtiofsd pkgs.looking-glass-client ];
}
```

**`vfio-pci.ids` cannot be used for the NVMe controller on this machine.** It
matches by vendor:device, not by slot, and Phase 0 found both drives are SK
hynix P41s behind the same `1c5c:1959` controller — an ID match takes **both**
and the host loses its own root device. Bind the 2 TB drive's controller by PCI
address. Windows reports it on bus 17 and the 1 TB on bus 6, but Linux numbers
buses independently: take the address from Phase 0's
`ls -l /sys/block/nvme*n1/device/device` on the live USB, picking the drive
whose `lsblk` shows the NTFS `C:`.

```nix
# Bind one specific slot, not every device with that ID.
boot.initrd.preDeviceCommands = ''
  echo "<VEND> <DEV>" > /sys/bus/pci/drivers/vfio-pci/new_id
  echo "0000:<FAST_NVME_ADDR>" > /sys/bus/pci/devices/0000:<FAST_NVME_ADDR>/driver/unbind
  echo "0000:<FAST_NVME_ADDR>" > /sys/bus/pci/drivers/vfio-pci/bind
'';
```

**Verify before building a VM:** after the switch and reboot,

- `lspci -nnk -d <VEND:DEV>` must show `Kernel driver in use: vfio-pci` for the
  dGPU. If it still shows `amdgpu` or `nvidia`, the binding lost the race —
  that is the symptom of `vfio_pci` being in `boot.kernelModules` instead of
  `boot.initrd.kernelModules`.
- The same for the NVMe controller, **and** `lsblk` must not list Windows' disk
  at all. If it does, the host still owns it — stop and fix the binding before
  starting a guest, because both touching that filesystem is the one
  unrecoverable mistake available here.

#### Handing the disk to the guest

With the controller bound to `vfio-pci`, the guest gets it as a plain hostdev —
the same mechanism as the GPU, no storage driver involved:

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source><address domain='0x0000' bus='0x..' slot='0x..' function='0x0'/></source>
</hostdev>
```

OVMF then finds Windows' own ESP on that drive and boots `bootmgfw.efi` exactly
as the firmware does on bare metal. **No virtio storage driver, no
`INACCESSIBLE_BOOT_DEVICE`, no unattended-install answer file, no image
build** — the guest is booting the installed OS, not an image built to resemble
it.

The remaining virtual devices (NIC, balloon) do want virtio drivers. Install
them once from bare metal via `pkgs.virtio-win`'s ISO before the first guest
boot, so the first boot has them rather than discovering it needs them.

---

## Phase 5 — Performance tuning, only while the VM runs

This is the part worth getting right, because the obvious approach is the wrong
one.

**Do not use `isolcpus`.** It is a boot parameter: it permanently removes cores
from the host scheduler, so NixOS runs on a fraction of the machine *even when
the VM is off*. Compiles, which are the thing this box does most, get slower
forever to make gaming faster sometimes.

The correct mechanism is **libvirt qemu hooks + cgroup v2 cpusets**, applied on
VM start and reversed on VM stop. Nothing is degraded while the VM is down.

```nix
# hosts/desk/perf-hook.nix
{ pkgs, ... }:
let
  # Ryzen 5 7600X: 6C/12T on a single CCD, so there is no CCD boundary to
  # respect. Assumes the usual Linux numbering (SMT sibling of n is n+6) —
  # confirm with `lscpu -e`. Host keeps cores 0-1, guest gets 2-5.
  hostCpus = "0-1,6-7";       # cores NixOS keeps
  allCpus  = "0-11";
  hugepages2M = 8192;         # 16 GiB guest / 2 MiB, of 32 GB total
in
{
  virtualisation.libvirtd.hooks.qemu."10-win-perf" =
    pkgs.writeShellScript "win-perf" ''
      set -eu
      PATH=${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.cpupower pkgs.coreutils ]}
      [ "$1" = "win" ] || exit 0

      case "$2/''${3:-}" in
        prepare/begin)
          # Fence every host task off the guest's cores. --runtime = not persisted.
          for s in system.slice user.slice init.scope; do
            systemctl set-property --runtime -- "$s" AllowedCPUs=${hostCpus}
          done
          systemctl stop irqbalance.service || true
          cpupower frequency-set -g performance
          echo ${toString hugepages2M} > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
          ;;
        release/end)
          echo 0 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
          cpupower frequency-set -g schedutil
          systemctl start irqbalance.service || true
          for s in system.slice user.slice init.scope; do
            systemctl set-property --runtime -- "$s" AllowedCPUs=${allCpus}
          done
          ;;
      esac
    '';
}
```

Hook arguments are `$1` guest name, `$2` operation, `$3` sub-operation.
`prepare/begin` runs before QEMU launches; `release/end` after it is gone, so
the teardown runs even on a crash.

**2 MiB vs 1 GiB hugepages.** Start with 2 MiB, allocated in the hook as above —
they allocate reliably at runtime and cost nothing when the VM is down. 1 GiB
pages are measurably better for a large guest but *cannot* be reliably allocated
at runtime once memory is fragmented, so they need boot-time reservation
(`hugepagesz=1G hugepages=N`) — which permanently removes that RAM from NixOS.
Measure first; escalate only if 2 MiB proves insufficient.

If you would rather not hand-roll the cpuset manipulation, `vfio-isolate` does
the same job with a nicer interface and is designed to be called from these
hooks.

### Domain-side settings (the other half)

In the guest XML — pinning and topology are libvirt's job, not the hook's:

```xml
<cpu mode='host-passthrough' check='none' migratable='off'>
  <topology sockets='1' dies='1' cores='4' threads='2'/>   <!-- 7600X: host keeps 2 of 6 -->
  <feature policy='require' name='topoext'/>   <!-- AMD: guest sees correct SMT -->
  <cache mode='passthrough'/>
</cpu>
<cputune>
  <vcpupin vcpu='0' cpuset='2'/>  <!-- pair each vcpu to its SMT sibling -->
  <vcpupin vcpu='1' cpuset='8'/>
  <!-- ... -->
  <emulatorpin cpuset='0-1'/>     <!-- emulator threads on HOST cores, not guest ones -->
  <iothreadpin iothread='1' cpuset='2-3'/>
</cputune>
<memoryBacking><hugepages/><nosharepages/></memoryBacking>
<features>
  <hyperv mode='custom'>
    <relaxed state='on'/><vapic state='on'/>
    <spinlocks state='on' retries='8191'/>
    <vpindex state='on'/><synic state='on'/><stimer state='on'/>
    <frequencies state='on'/><tlbflush state='on'/><ipi state='on'/>
  </hyperv>
  <kvm><hidden state='off'/></kvm>   <!-- no anti-cheat: keep enlightenments -->
</features>
```

`emulatorpin` is the one people forget. Without it, QEMU's own I/O threads land
on the same cores as the vCPUs and show up as frame-time spikes.

---

## Phase 6 — Managing the one Windows install

### The honest framing

Windows has no store, no closure, and no atomic rollback. Any config tool is
**convergent**, not declarative in the Nix sense: applying a config moves the
system toward a state, but deleting a line does *not* remove what it installed.
There is no `nixos-rebuild switch` that garbage-collects a registry key.

That limitation is unchanged. What changed is how much of it matters:

> **There is one installation. Configuring it once configures both boot modes,
> because they are the same `C:\`.**

An earlier draft of this phase existed to keep two separate installs from
drifting — two profiles, a declared delta, a check that the delta stayed honest.
All of that is deleted. A package installed while running as a guest is installed when
you next boot bare metal, not because anything synced but because nothing was
ever separate.

What remains is a single question: **how does a Windows install get its
configuration from this repo, in a way a Windows admin would recognise?**

### One profile, pulled from this repo

**Nix is the source of truth, WinGet DSC is the applier, and the rendered
artifacts are committed here.**

```
hosts/desk/windows/
  profile.nix        # packages and settings, as Nix attrs
  render.nix         # profile -> DSC yaml + .reg + Apply.ps1 + Test.ps1
  rendered/          # GENERATED AND COMMITTED. This is what Windows reads.
```

```nix
# hosts/desk/windows/profile.nix
{
  packages = [
    "Valve.Steam"
    "Microsoft.PowerShell"
    "Git.Git"
    "wez.wezterm"
  ];
  settings = {
    showFileExtensions = true;
    taskbarAlignment = "Left";
    developerMode = true;
  };
}
```

rendered by `pkgs.formats.yaml` into the file `winget` actually consumes:

```yaml
# hosts/desk/windows/rendered/configuration.dsc.yaml
# GENERATED by `nix run .#render-windows`. Do not edit; edit profile.nix.
properties:
  configurationVersion: 0.2.0
  resources:
    - resource: Microsoft.WinGet.DSC/WinGetPackage
      id: Valve.Steam
      directives: { description: Install Steam }
      settings: { id: Valve.Steam, source: winget }
    - resource: Microsoft.Windows.Developer/WindowsExplorer
      id: explorer
      directives: { description: Explorer settings }
      settings: { FileExtensions: Show }
```

### Why the artifacts are committed

This looks like a Nix anti-pattern, and there is a concrete reason for it.

**NixOS cannot push configuration to Windows here.** When Windows runs as a
guest it is reachable, but when it runs bare metal NixOS is not running at all —
and it is the *same install*, so a config channel that only works in one boot
mode is a config channel that leaves the machine in an undefined state half the
time. Anything Windows applies, it must already have on disk.

So the flow inverts: **Nix renders, the render is committed, Windows pulls.**

```powershell
# From an elevated PowerShell — in either boot mode, identically.
git -C C:\src\nix-config pull        # git clone once, on first run
cd C:\src\nix-config\hosts\desk\windows\rendered
.\Apply.ps1
```

The entire Windows-side toolchain is **git and winget**, both of which ship with
Windows or install from it. No Nix on Windows, no SSH server, no control node,
no network path between the two operating systems. A Windows admin reading this
sees a repo, a YAML file and `winget configure` — idioms, not a foreign object.

The obvious risk is the committed render drifting from the profile that
generated it. A flake check closes it, so a `.nix` change cannot land without
its regenerated artifacts:

```nix
# checks.desk-windows-rendered — fails if `rendered/` is stale
pkgs.runCommand "check-windows-rendered" { } ''
  diff -r ${self.packages.${system}.windowsRendered} \
          ${./hosts/desk/windows/rendered} \
    || { echo "rendered/ is stale — run: nix run .#render-windows"; exit 1; }
  touch $out
''
```

That also recovers some of the `nix flake check` coverage lost by deleting the
wezterm Windows tests — see [Risks](#risks-ranked).

### Applying and checking drift

WinGet DSC has a real test mode, which is what makes it a management tool rather
than a one-shot installer:

| | Command | What it does |
| --- | --- | --- |
| Converge | `winget configure --file configuration.dsc.yaml --accept-configuration-agreements` | Brings the system to the described state |
| **Check drift** | `winget configure test --file configuration.dsc.yaml` | Reports each resource in / not in the desired state, changing nothing |

`Test.ps1` wraps the second. A weekly Scheduled Task running it turns drift from
something you discover into something that tells you — and with one install
there is exactly one task to register and one report to read.

- [ ] `git clone` this repo on Windows, run `Apply.ps1`, confirm
      `winget configure test` comes back clean afterwards
- [ ] Register the weekly `Test.ps1` Scheduled Task
- [ ] Run `Apply.ps1` from the guest, reboot bare metal, and confirm the change
      is there. It will be — but seeing it once is what makes the "one install"
      claim real rather than asserted

### What DSC cannot reach, and the escape hatch

WinGet DSC's resource coverage is good for packages and thin for settings.
Expect to hit things it cannot express. Two escape hatches, in order:

1. **A committed `.reg` file**, rendered from the same profile attrs and
   imported by `Apply.ps1`. Crude, diffable, unambiguously a Windows idiom.
2. **Group Policy via `LGPO.exe`** (Microsoft Security Compliance Toolkit) for
   anything policy-shaped. A policy backup directory is version-controllable.

Neither is elegant. Both keep the property that matters: the change is written
down in this repo rather than clicked once and forgotten.

**If WinGet DSC disappoints more broadly**, the upgrade path is
[Microsoft DSC v3](https://github.com/PowerShell/DSC) (`dsc.exe`) — the general
engine `winget configure` is a front end to. Same YAML shape, more resources,
one more thing to install. Reach for it once winget's coverage is demonstrably
the blocker.

**What was considered and rejected:**

- **Ansible over SSH/WinRM** — richer than DSC for settings work, and now that
  there is only one install the "two methods" objection is gone. It still fails
  the structural test: it needs a control node reaching the target, and nothing
  reaches Windows while it is running bare metal. A config method that works in
  one boot mode is worse than one that works in both.
- **Chocolatey** — broader coverage than winget for older software. Kept in
  reserve as a *supplement* for packages winget lacks; it has no settings story.
- **Scoop** — user-scope, no admin, good `scoop export`/`scoop import`.
  Complementary for CLI tools, wrong shape for games and system settings.

### Drift repair

There is nothing disposable left, so "rebuild" is off the table. In order:

1. `Apply.ps1` — re-converge. Handles most drift.
2. `winget configure test` to find what convergence did not fix, then extend
   `profile.nix` so that it does. Every escalation past this point should leave
   a commit behind.
3. **In-place repair install** — mount a Windows 11 ISO and run `setup.exe` from
   inside Windows, choosing "Keep personal files and apps". Rebuilds the OS
   around the install, preserving the license, the data and the activation
   state.
4. Reset this PC → Keep my files, then `Apply.ps1`. Loses apps, keeps the
   license.

Losing the ability to rebuild is the real price of this layout, and it is worth
being honest that it is a price. What buys it back is that the thing you would
have rebuilt — a second, throwaway install — was only ever needed because there
were two. A repair install on the one install you have is slower than
regenerating a `qcow2`, and you will need it far less often.

### The VM definition

**Recommended: NixVirt.** It gives `virtualisation.libvirt.connections."qemu:///system"`
with declarative `domains`, `networks` and `pools`, and `lib.domain.writeXML` for
building the XML from Nix attributes rather than pasting `virsh dumpxml` output.
The domain here is unusual in one way — it has no disk image, just the NVMe
hostdev from [Phase 4](#phase-4--vfio-and-the-libvirt-host) and the SMBIOS block
from [the licensing section](#keeping-activation-stable-across-the-crossing) —
which makes it *more* suited to generation from attrs, not less.

Two caveats from its README, both of which bite if unexpected:

- **Domains, networks and pools not listed in the config are deleted.** That is
  the behaviour you want, but a VM someone creates in virt-manager vanishes on
  the next switch.
- Redefining an active domain deactivates and reactivates it — "like shutting
  the power off". Plan switches for when the VM is down.

The pragmatic alternative: build the domain once in virt-manager,
`virsh dumpxml win > hosts/desk/windows/domain.xml`, commit it, and add a
oneshot unit that `virsh define`s it. Less elegant, zero new inputs, and the XML
in git is still the source of truth.

### Secrets

**There are none in the Windows config.** The product key is the generic
placeholder and is not used at all now that there is no unattended install; the
local account already exists; there is no provisioner credential.

What *is* unmanaged state is listed in [Phase 9](#phase-9--retire-the-wsl-host):
the Microsoft account the license hangs off, and the machine's own BitLocker
recovery key if it is ever re-enabled. Neither belongs in git, and neither is
something this repo generates.

---

## Phase 7 — Display, input, audio

**Display — do both, in this order.**

1. **Second cable from the dGPU to a spare monitor input.** Lowest latency,
   zero moving parts, and it is the fallback that works when everything else is
   broken. Wire this first; do not skip it because Looking Glass sounds nicer.
2. **Looking Glass**, once (1) works. The guest renders on the passed-through
   dGPU and frames are shared back to the iGPU-driven desktop through the
   `kvmfr` device, so the VM is a window on your normal desktop. nixpkgs has
   first-class support:

```nix
boot.extraModulePackages = [ config.boot.kernelPackages.kvmfr ];
boot.initrd.kernelModules = [ "kvmfr" ];
boot.kernelParams = [ "kvmfr.static_size_mb=64" ];   # 64 covers 1440p; 128 for 4K

services.udev.packages = lib.singleton (pkgs.writeTextFile {
  name = "kvmfr";
  text = ''SUBSYSTEM=="kvmfr", GROUP="kvm", MODE="0660", TAG+="uaccess"'';
  destination = "/etc/udev/rules.d/70-kvmfr.rules";
});

virtualisation.libvirtd.qemu.verbatimConfig = ''
  namespaces = []
  cgroup_device_acl = [
    "/dev/null", "/dev/full", "/dev/zero", "/dev/random", "/dev/urandom",
    "/dev/ptmx", "/dev/kvm", "/dev/rtc", "/dev/hpet",
    "/dev/vfio/vfio", "/dev/kvmfr0"
  ]
'';
```

Note `cgroup_device_acl` — libvirt's default device ACL does not include
`/dev/kvmfr0`, and leaving it out produces a permission error that reads like
something else entirely.

**Input.** Pass an entire USB host controller through VFIO if Phase 0 shows one
in its own IOMMU group. That gives the guest real USB with no translation
layer — best for controllers, high-polling-rate mice, and VR. Otherwise use
libvirt's `<input type='evdev'>` with a both-Ctrl hotkey to toggle capture.

**Audio.** libvirt has supported `<audio type='pipewire'/>` since 9.10. For a
`qemu:///system` domain the QEMU process runs as a system user and cannot find
your session's PipeWire socket, so it needs the `runtimeDir` attribute pointed
at `/run/user/1000`. If that fights you, HDMI audio out of the passed-through
dGPU's audio function is a zero-config fallback — you are passing that function
through anyway.

---

## Phase 8 — Cutover QA

Nix proves the closure; it cannot prove any of this.

**Host**

- [ ] `hostname` → `desk`; `tailscale status` shows `desk`; `avahi-resolve -n desk.local`
- [ ] `systemctl --failed` empty
- [ ] `lspci -nnk -d <dGPU>` → `Kernel driver in use: vfio-pci`
- [ ] iGPU drives the desktop: `glxinfo -B` names the AMD iGPU, not llvmpipe
- [ ] From the Mac: `ssh n8@desk.<tailnet>.ts.net`, and WezTerm's `ssh_domains` lists `desk`
- [ ] `wezterm-mux-server` active; a remote pane from the Mac actually opens
- [ ] rclone Drive mount present and writable
- [ ] `claude --version`, `gh auth status`, `docker run --rm hello-world`, `nvim --version`
- [ ] `git config user.email` → `nathan@natb1.com`; `authorized_keys` has both keys, mode 600

**Both boot modes**

- [ ] Windows boots bare metal from the firmware menu, and reports
      **activated** — check again here, not just in Phase 2
- [ ] Windows boots as a guest, and *still* reports activated. This is the
      single most important check in this document: it is what the SMBIOS
      impersonation exists to produce
- [ ] Cross four times — metal, guest, metal, guest — confirming activation
      holds each time. Once is luck; four times is the configuration working
- [ ] Clocks agree after each crossing
- [ ] `powercfg /a` shows hibernation disabled. A Windows update can quietly
      re-enable Fast Startup, and with one filesystem serving both boot modes
      that is how it gets corrupted
- [ ] Steam works in both, from the same library, with no re-download and no
      re-validation

**Host**

- [ ] `hostname` -> `desk`; `tailscale status` shows `desk`; `avahi-resolve -n desk.local`
- [ ] `systemctl --failed` empty
- [ ] `lspci -nnk -d <dGPU>` -> `Kernel driver in use: vfio-pci`
- [ ] `lspci -nnk -d <fast NVMe>` -> `vfio-pci`, **and `lsblk` does not list
      Windows' disk at all.** If the host can see that filesystem, stop
- [ ] iGPU drives the desktop: `glxinfo -B` names the AMD iGPU, not llvmpipe
- [ ] From the Mac: `ssh n8@desk.<tailnet>.ts.net`, and WezTerm's `ssh_domains` lists `desk`
- [ ] `wezterm-mux-server` active; a remote pane from the Mac actually opens
- [ ] rclone Drive mount present and writable
- [ ] `claude --version`, `gh auth status`, `docker run --rm hello-world`, `nvim --version`
- [ ] `git config user.email` -> `nathan@natb1.com`; `authorized_keys` has both keys, mode 600
- [ ] A `nixos-rebuild build` on the bulk drive is not painfully slower than the
      Phase 0 `fio` numbers predicted. This is the cost of the layout, and it
      should be a number you accepted rather than one you discover

**Guest**

- [ ] `virsh list` shows `win` running; Device Manager shows no unknown devices
- [ ] Device Manager shows the **real** NVMe controller, not a virtio disk —
      that is how you know the hostdev took rather than falling back
- [ ] dGPU in the guest with the vendor driver loaded, no Code 43 / Code 31
- [ ] A game runs at expected frame rate with acceptable frame *times* — check
      1% lows, not the average; VM problems show up as stutter, not low FPS
- [ ] Audio plays, and keeps playing after an alt-tab

**The shutdown discipline — the new sharp edge**

- [ ] `virsh shutdown win` (clean) then boot bare metal: filesystem is clean,
      no chkdsk on entry
- [ ] Deliberately test the wrong way once, while there is nothing to lose:
      `virsh managedsave win`, then confirm the NixOS side **refuses or warns**
      rather than letting you reboot into a bare-metal Windows on top of a
      saved guest's dirty state. If nothing stops you, add the guard — a
      pre-reboot check for saved domains is worth the twenty lines
- [ ] Confirm `virsh managedsave-remove win` is in your vocabulary before you
      need it at speed

**The performance hook — the part most likely to be silently wrong**

- [ ] With the VM **down**: `nproc` sees every core; a `nixos-rebuild build` runs
      at full speed
- [ ] With the VM **up**: `systemctl show user.slice -p AllowedCPUs` shows only
      the host cores; `cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages`
      is nonzero; `cpupower frequency-info` says performance
- [ ] After `virsh destroy win` (not a clean shutdown — test the crash path):
      everything above reverts. `release/end` is what makes this true; if it
      does not fire, the host stays crippled after every crash.
      **Then boot bare metal and let Windows chkdsk** — `virsh destroy` is a
      power cut to the guest, and the filesystem it cut power to is the real one
- [ ] Reboot with the VM set to autostart off, confirm nothing is degraded

**Windows management**

- [ ] `winget configure test` comes back clean after `Apply.ps1`
- [ ] Add a package to `profile.nix`, re-render, commit, then `git pull` +
      `Apply.ps1` **from the guest** — reboot bare metal and confirm it is
      there. One install means this must be true; verify it once anyway
- [ ] `nix flake check` fails when `rendered/` is stale — verify by editing
      `profile.nix` and *not* re-rendering
- [ ] The weekly `Test.ps1` Scheduled Task exists and reports somewhere you will
      actually see it

---


## Phase 9 — Retire the WSL host

Only after Phase 8 passes.

- [ ] Delete `hosts/wsl/` and the `nixosConfigurations.wsl` output
- [ ] Delete `modules/home/wezterm-pin.nix`'s Windows half and
      `scripts/sync-wezterm.sh` if nothing else uses them
- [ ] Remove the `wsl` node from the Tailscale admin panel
- [ ] Mac: drop `wsl` from `~/.ssh/known_hosts` and any config pointing at it
- [ ] Fix the `n8@nixos` comment on the SSH key in `modules/home/default.nix` —
      [TODO.md §2](../TODO.md) already flags it and this is the natural moment
- [ ] README: replace the "A future native NixOS host" section with the real one
- [ ] Update the "State this repo does not manage" list: the Windows-side WezTerm
      install and the `G:` volume are gone; new entries are the Microsoft
      account the digital license hangs off (no product key — see
      [Secrets](#secrets)), everything on Windows' own drive, rclone
      credentials, the Samba password database (`smbpasswd`), and
      `/etc/restic/{media.password,id_ed25519}`
- [ ] Note in the README that `hosts/desk/windows/` configures a Windows install
      this repo does not otherwise own — the drive is Windows', the profile is
      ours

---

## Risks, ranked

1. **Booting bare metal on top of a saved guest.** The new top risk, and the
   one genuinely created by this design. `virsh managedsave` or a paused domain
   leaves the NTFS mid-flight in host RAM; boot the metal from that state and
   the filesystem takes the damage. Nothing in libvirt or the firmware stops
   you. Mitigations: always `virsh shutdown`, never save; a pre-reboot check for
   saved domains; and the Phase 8 drill that makes the failure mode familiar
   before it is expensive.
2. **A stray `disko --mode disko`.** Wipes the bulk drive, which now holds
   NixOS root *and* the media volume. Install-only; everything afterwards is
   `nixos-rebuild`. The consolation, and it is a real one: Windows is on the
   other drive and this command cannot reach it.
3. **`vfio-pci.ids` matches both NVMe drives.** Confirmed in Phase 0: both are
   SK hynix P41s on `1c5c:1959`, so an ID-based binding takes the host's root
   device too and the machine does not boot. Phase 4 binds by address; the
   risk now is someone "simplifying" that back to an ID.
4. **The NVMe controller's IOMMU group is dirty.** Kills the approach rather
   than inconveniencing it. Found in Phase 0, before anything is installed,
   which is the entire reason Phase 0 is a gate.
5. **Activation wobbles across the crossing.** Expected to be solved by the
   SMBIOS impersonation, but not contractually guaranteed — Microsoft does not
   document the hash. Recoverable via the Troubleshooter because the license is
   account-linked, which is what keeps this a nuisance rather than a crisis.
6. **Fast Startup comes back.** A Windows update re-enables hibernation, the
   "shutdown" stops being one, and the filesystem both boot modes share starts
   accumulating damage. `powercfg /a` is on the Phase 8 list for this reason
   and is worth re-checking after feature updates.
7. **NixOS root on the slower drive.** Not a failure mode, a permanent tax —
   and the one thing in this plan that makes daily work worse to make gaming
   better. Phase 0's `fio` numbers are how you decide whether it is acceptable
   *before* committing, rather than noticing it in month three.
8. **BitLocker re-enables itself.** Windows can turn on Device Encryption after
   some updates or a Microsoft account change. A TPM-sealed key will not unseal
   in the guest, so the next guest boot lands in recovery. Check it alongside
   `powercfg /a`.
9. **IOMMU groups are dirty for the dGPU.** The original gate, unchanged.
10. **The performance hook does not revert.** A crashed VM leaving the host
    pinned to four cores is the kind of bug you diagnose three weeks later as
    "NixOS feels slow lately". The `virsh destroy` test in Phase 8 exists for
    exactly this.
11. **The media backup stops and nobody notices.** The failure mode of every
    backup that has ever failed. `runCheck` plus the `OnFailure` hook in
    [Media storage](#media-storage) are the minimum; the restore drill is what
    actually proves it. Ranked below the Windows risks only because those are
    time-boxed to the migration — this one is permanent, and of everything on
    this list it is the likeliest to be discovered too late.
12. **Samba serving an empty share.** If the bulk SSD does not mount, an
    unguarded smbd exports `/srv/media` on the root filesystem and clients write
    into it. The `requires=srv-media.mount` binding prevents it; verify by
    booting once with the drive pulled.
13. **`nix flake check` coverage drops.** Deleting the wezterm Windows tests
    removes 15 checks' worth of real assertions. The stale-`rendered/` check in
    [Phase 6](#phase-6--managing-the-one-windows-install) recovers some of it;
    whatever else replaces them should land in the same PR as the deletion, or
    it never lands.

## Deliberately not doing

- **A second Windows install.** Considered at length and rejected: it meant an
  unactivated copy running unlicensed, two config profiles, a repartition of the
  Windows drive, and an image build — all to avoid the SMBIOS impersonation this
  plan does in twelve lines of XML.
- **Dual-boot in the ordinary sense** — two operating systems sharing one
  drive's partition table. Each OS gets its own disk instead, which is why
  disko keeps its declarative install and Windows keeps its bootloader.
- **Hypervisor hiding.** Costs performance, buys nothing: anti-cheat titles
  boot bare metal, which is now just "reboot into the install you already have".
- **`isolcpus`.** Permanent cost for an occasional benefit — see
  [Phase 5](#phase-5--performance-tuning-only-while-the-vm-runs).
- **Putting the Steam library on `/srv/media` and mounting it over SMB.**
  Loading times over a network share are not worth discussing.
- **Nix on Windows.** The Windows side needs git and winget. Adding a third
  thing to install before the machine can configure itself defeats the point.
