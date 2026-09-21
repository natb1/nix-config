# Plan — WSL → native NixOS, dual-booting Windows, with a Windows VM too

Written 2026-09-20. This is the *second* migration this repo tracks: [TODO.md](../TODO.md)
is about finishing the move off `commons.systems`. This one is about the desktop
stopping being a Windows box that hosts NixOS, and becoming a machine that boots
NixOS *or* Windows, and that can run a second, separate Windows as a
GPU-passthrough guest from the NixOS side.

Three Windows-shaped facts drive most of what follows: the bare-metal install is
**kept** (it holds the activated license and is the only place kernel anti-cheat
runs), the guest is a **separate** install that stays **unactivated on purpose**,
and both are configured by **one profile set living in this repo** —
[Phase 6](#phase-6--managing-both-windows-installs).

Sequencing: **finish TODO.md §1–§3 first.** Switching the WSL host onto this
repo is the cheap, reversible change that proves the repo works. Repartitioning
the machine's boot drive around an install you intend to keep is neither. Do not
stack them.

---

## Decisions locked in

| Question | Answer | What it rules out |
| --- | --- | --- |
| GPU topology | Discrete card → VM, AMD iGPU → NixOS | Single-GPU hook gymnastics; the host never goes headless |
| Bare-metal Windows | **Kept.** Repartitioned, not wiped — it holds the activated license and is the anti-cheat escape hatch | `disko` owning the fast drive; a clean-slate install |
| Virtualized Windows | **Also kept**, as a *second, separate* install, deliberately unactivated | Booting the bare-metal partition as the guest |
| Windows config rigor | One profile set in this repo, rendered by Nix, applied to **both** targets by WinGet DSC | Per-target hand-clicking; treating either install as undocumented |
| Drift repair | Guest: rebuild the image. Metal: converge, repair-install as last resort | Treating the metal as disposable |

Four consequences worth stating up front:

1. **Disko does not own the fast drive.** Keeping bare-metal Windows means a
   partition table disko must not touch — it
   [explicitly does not support dual-boot](#disk-layout--dual-boot). The fast
   drive is partitioned by hand, once, and its NixOS filesystems are declared
   with plain `fileSystems` entries. Disko manages the bulk drive only.
2. **The two Windows installs are never up at the same time.** Bare metal boots
   *instead of* NixOS, and the guest only runs under NixOS. That mutual
   exclusion is structural, and it is what makes a single NTFS game library
   safely shareable between them (§1) — and what removes any way for NixOS to
   push config to the metal, which shapes [Phase 6](#phase-6--managing-both-windows-installs).
3. **Do not hide the hypervisor.** The `<kvm><hidden state='on'/></kvm>` +
   spoofed `vendor_id` trick exists to dodge anti-cheat, and it *costs*
   performance because it disables the Hyper-V enlightenments Windows uses to
   run fast under KVM. Anti-cheat titles go on the metal, where they are
   supported and where the license is. Skip the trick entirely and take the
   enlightenments.
4. **Check ProtonDB before building any of this.** Every title that runs native
   under Proton is a title neither Windows has to serve. If the list comes back
   mostly green, the VM shrinks from "daily driver" to "occasional escape
   hatch", and several phases below get much less important.

### Still unknown — resolved in Phase 0

- The exact discrete GPU (vendor + PCI IDs). If it is a **Radeon**, check
  whether it needs `vendor-reset` for the AMD reset bug (Polaris/Vega do;
  RDNA2+ generally do not). If it is **NVIDIA**, Code 43 has not been a real
  problem since the 465 driver.
- Whether the IOMMU groups isolate the dGPU cleanly.
- Ryzen core/CCD layout, for pinning.
- Model, capacity and SMART wear level of **each of the two SSDs**. *That* there
  are two — one chosen for speed, one for bulk — is settled; what they are is
  not, and the numbers decide where the Steam library lives (§1). Record
  specifically: free space on the fast drive after root and `win-os.qcow2`, and
  whether the bulk drive is genuinely slower (QLC, SATA, Gen3) or merely
  larger. "Bulk" meaning *bigger* and "bulk" meaning *slower* lead to different
  answers.
- **The fast drive's current partition table**, now that it is being preserved:
  how much free space `C:` yields when shrunk, the size of the existing ESP, and
  whether BitLocker is on. These decide the
  [dual-boot layout](#disk-layout--dual-boot) and they cannot be guessed.

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

**Nothing is destroyed in this phase.** WSL2 does not expose the PCI bus, so
this has to be done from a NixOS live USB. Boot it, run the following, save the
output somewhere off this machine (the Mac, or the Drive folder) — Phase 2
edits this drive's partition table, and notes stored on it are notes you may be
unable to read when you most need them.

```sh
# 1. Confirm AMD-Vi is actually on. Empty output = IOMMU disabled in BIOS.
dmesg | grep -i -e AMD-Vi -e IOMMU

# 2. Both GPUs, their PCI addresses, vendor:device IDs, and current drivers.
lspci -nnk | grep -A3 -E 'VGA|3D|Display|Audio device'

# 3. IOMMU groups. THIS IS THE GATE.
for g in /sys/kernel/iommu_groups/*/devices/*; do
  n=${g#*/iommu_groups/}; n=${n%%/*}
  printf 'group %3s  ' "$n"; lspci -nns "${g##*/}"
done | sort -h

# 4. Core topology, for pinning later.
lscpu -e
lstopo-no-graphics --of txt   # pkgs.hwloc — shows CCD/L3 boundaries
```

**The gate:** the dGPU and its HDMI-audio function must sit in an IOMMU group
containing nothing else you need on the host. A group that also holds your NVMe
controller or a USB controller you need means passthrough takes the whole group.

- Clean group → proceed.
- Dirty group → try moving the card to a different PCIe slot first. Failing
  that, `pcie_acs_override=downstream,multifunction` splits groups but requires a
  patched kernel and **defeats the isolation IOMMU exists to provide**. Treat it
  as a last resort you accept knowingly, not a default.
- No IOMMU at all → enable SVM + IOMMU in BIOS and re-run. If the board truly
  has neither, the VM half of this plan is dead — but bare-metal Windows is
  being kept regardless, so the fallback is simply "dual-boot without the
  guest", and everything except Phases 4–6's guest half still applies.

Also in Phase 0, before the partition table is touched:

- [ ] `nixos-generate-config --no-filesystems --show-hardware-config` from the
      live USB → this is `hosts/desk/hardware-configuration.nix`
- [ ] Record `/dev/disk/by-id/` names for every drive (by-id, not `/dev/nvme0n1` —
      by-id is stable across reboots and is what disko should reference)
- [ ] `smartctl -a` each SSD: model, capacity, and the wear indicator
      (`Percentage Used` on NVMe). The bulk drive's capacity sizes the backup
      tier; its wear level is the first honest input to "when does this die"
- [ ] Inventory the game library: which titles, and what ProtonDB says about each
- [ ] Inventory what is on `C:\` that matters and is not in Drive or git
- [ ] **Image the whole fast drive before touching its partition table.** `C:`
      is being shrunk in place, not reinstalled, and a shrink that goes wrong
      takes the activated license with it. `ddrescue` to the bulk drive or an
      external disk from the live USB, or a Windows-side full backup — either,
      but not neither
- [ ] **BitLocker status:** `manage-bde -status` from an elevated prompt. If it
      is on, save the recovery key somewhere off this machine *and* suspend
      protection before the repartition and before Secure Boot changes. Order:
      suspend → repartition → change firmware settings → boot both → resume.
      Skipping this is how you meet the recovery prompt with no key
- [ ] **`powercfg /h off`** — disables hibernation and with it Fast Startup.
      Required before any NTFS volume is shared with the guest or read by
      NixOS: Fast Startup leaves the filesystem dirty on every "shutdown", and
      a dirty NTFS mounted read-write from the other side corrupts it
- [ ] Record the current partition table (`Get-Disk`/`Get-Partition`, or
      `lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME` and `parted -l` from the USB),
      including the ESP's size — [Phase 1](#disk-layout--dual-boot) needs it
- [ ] Shrink `C:` from **inside Windows** (Disk Management, or
      `Resize-Partition`), not from Linux. Windows' own shrinker understands
      its filesystem and will refuse rather than guess; run a defrag first if
      immovable files cap the shrink short of what you need
- [x] Settle the licensing question below — **resolved: RETAIL, digital
      license, already linked to the Microsoft account, and the bare-metal
      install keeps it.** The guest is deliberately unactivated, so the old
      pre-wipe urgency is gone: nothing is being wiped

### Windows licensing — resolved

**Answer for this machine: RETAIL, digital license, already linked to the
Microsoft account — and the bare-metal install keeps it.** The guest is a
*second, separate* Windows install that runs unactivated by design. Nothing here
blocks the repartition, and there is no key to protect.

Measured on the pre-migration install:

| Field | Value | Consequence |
| --- | --- | --- |
| `ProductKeyChannel` | `Retail` | The virtualization clause below applies |
| `LicenseFamily` | `Professional` | Pro edition, so the answer file installs Pro |
| `PartialProductKey` | `3V66T` | The tail of `VK7JG-NPHTM-C97JM-9MPGT-3V66T`, Microsoft's published generic Pro key — *not* a per-machine key |
| `OA3xOriginalProductKey` | empty | No MSDM table, so not an OEM preinstall |
| Activation panel | *"activated with a digital license linked to your Microsoft account"* | Already linked; this install keeps the entitlement |

The two facts that matter downstream: **there is no key string to recover, carry
across the wipe, or keep out of git** — the entitlement lives on the Microsoft
account, and the key installed today is a public placeholder — and **activation
travels through that account, not through anything typed into the answer file.**

#### Can one license cover bare metal *and* the VM?

**No. Not both, and now that both exist, this is the section to re-read before
touching activation.**

The clause is *"**instead of** using the software directly on the licensed
device, you may install and use the software within **only one** virtual (or
otherwise emulated) hardware system on the licensed device."* "Instead of" is
substitution, not addition. It permits moving the licensed use into a VM; it
does not permit one license covering a bare-metal install and a VM at the same
time. Keeping bare metal means the license stays there, and the guest is simply
not covered by it.

Activation mechanics enforce the same shape. A digital license binds to a
hardware hash plus the account; the guest's hash differs from the metal's.
Signing into the Microsoft account inside the guest and running the Activation
Troubleshooter would **move the entitlement onto the guest's hash and
deactivate the bare-metal install.** Bouncing it back is a manual Troubleshooter
run that Microsoft rate-limits.

So, as a standing rule for the guest:

> **Never sign into the Microsoft account inside the VM, and never run the
> Activation Troubleshooter there.** The guest stays unactivated on purpose.
> There is no "just checking" version of this — signing in is the thing that
> moves the license.

This is a deliberate trade, not an oversight: an unactivated Windows 11 install
is not a licensed one. It runs indefinitely and Microsoft permits it to, but if
the guest ever becomes something you rely on rather than a test bed, the honest
fix is a second license, not a Troubleshooter run against the first.

**Rejected outright: booting the bare-metal partition as the guest.** Handing
the physical Windows partition to the VM via block passthrough is a known VFIO
pattern and it looks like it avoids maintaining two installs. It does not work
here. The guest presents different hardware, so that single install would
re-hash and fight activation every time you crossed between metal and VM — the
exact failure this section exists to prevent — on top of the usual driver-set
thrash and the risk of both booting it. Two separate installs is the cheaper
answer, and it is what makes [Phase 6](#phase-6--managing-both-windows-installs)
worth building: two installs are only maintainable if one method configures
both.

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
cannot be done after the wipe.

A firmware key, where one exists, is also readable from Linux once NixOS is
installed — not useful on this machine, since there is no MSDM table:

```sh
strings /sys/firmware/acpi/tables/MSDM | grep -Eo '[A-Z0-9]{5}(-[A-Z0-9]{5}){4}'
```

**Why RETAIL settles it.** The "Use with Virtualization Technologies" clause
reads: *"Instead of using the software directly on the licensed device, you may
install and use the software within only one virtual (or otherwise emulated)
hardware system on the licensed device."* That is precisely this migration: same
physical machine, Windows moves off the metal and into one VM, never both at
once.

**The OEM branch, not taken, kept for the reasoning.** Had the channel been OEM
(`OEM_DM` — preinstalled by the vendor, key in the MSDM table), Microsoft's
stated position is that OEM keys cover physical instances only and carry no
virtualization rights. The VM presents a different hardware hash, so it would
not auto-activate. It *can* be made to activate by passing the host's own MSDM
ACPI table and SMBIOS strings through to the guest
(`-acpitable file=/sys/firmware/acpi/tables/MSDM` plus libvirt `<sysinfo>`), a
well-documented technique — but note what that does and does not do: it makes
the guest activate, it does not change the license terms. The empty
`OA3xOriginalProductKey` above retires this path.

#### What the guest install looks like instead

The answer file's *"local account, skip MS account"* OOBE is now exactly right,
and for a new reason: it is the thing keeping the license on the metal. Keep it,
and treat the resulting unactivated guest as the finished state rather than a
stage to graduate from.

The answer file's product-key slot takes the generic Pro key
`VK7JG-NPHTM-C97JM-9MPGT-3V66T`. It selects the edition and gets Setup past the
key prompt; it activates nothing, which is the intent. Because it is a published
placeholder rather than a secret, it belongs in plaintext in `image.nix` — see
[Secrets](#secrets).

**What unactivated costs, concretely:** a desktop watermark, Personalization
settings locked (wallpaper, accent colour, lock screen), and an occasional nag.
**No impact on games, performance, driver support, updates, or WinGet.** The
locked Personalization pane is the only one that touches
[Phase 6](#phase-6--managing-both-windows-installs): a handful of appearance
settings cannot be applied to the guest through DSC or any other channel, so the
`metal` and `guest` profiles legitimately diverge there rather than the guest
drifting.

- [x] **Before the wipe:** link the license to the Microsoft account — *already
      done; the Activation panel confirms it.* A retail license linked to an
      account re-activates through the Activation Troubleshooter after a
      hardware change; an unlinked one means a phone-activation call. This step
      is unrecoverable once Windows is gone.
- [x] Record the channel and the key somewhere that survives the wipe — *the
      table above is that record. There is no key beyond the generic one.*
- [ ] Confirm this PC is listed at `account.microsoft.com/devices` and note the
      name it appears under — that is how you identify it in the Activation
      Troubleshooter's device list after the hardware change.
- [x] ~~If buying a fresh retail Windows 11 Pro key, budget for it now~~ — not
      needed. This migration has no license line item.

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
  disko.nix                   # partitioning
  desktop.nix                 # display manager, PipeWire, fonts, browser
  gaming.nix                  # steam, gamemode, mangohud, native-Proton side
  vfio.nix                    # IOMMU, vfio-pci binding, kvmfr
  libvirt.nix                 # libvirtd, OVMF, swtpm, the NixVirt domain
  perf-hook.nix               # the while-the-VM-runs tuning (§5)
  windows/                    # the declarative image (§6)
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

### Disk layout — dual-boot

**Disko explicitly does not support dual-boot, so it does not get the fast
drive.** That is not a workaround; it is the documented boundary. The fast drive
already holds a Windows install that must survive, and disko's model is "declare
the table, create the table". Two rules follow, and the rest of this section is
their consequence:

> The fast drive is partitioned **by hand, once**, and its NixOS filesystems are
> declared with plain `fileSystems` entries.
> Disko manages **the bulk drive only**.

#### The fast drive, after shrinking `C:`

| # | Partition | Owner | Notes |
| --- | --- | --- | --- |
| 1 | ESP | **shared** | Already exists. Windows made it; NixOS mounts it at `/boot` |
| 2 | MSR (16 MB) | Windows | Leave it alone |
| 3 | `C:` (NTFS) | Windows | Shrunk from inside Windows in Phase 0 |
| 4 | WinRE (NTFS) | Windows | Recovery. Leave it alone — moving it breaks reset |
| 5 | NixOS root (ext4) | NixOS | Created by hand in the freed space |
| 6 | swap | NixOS | Sized for hibernation only if you want it; otherwise skip |

**On sharing the ESP.** One ESP that both OSes use is the arrangement
systemd-boot handles best: it auto-discovers `\EFI\Microsoft\Boot\bootmgfw.efi`
and offers Windows as an entry with no extra configuration. Two ESPs works in
firmware but makes cross-ESP chainloading awkward enough that it is not worth
choosing deliberately.

The catch is size. OEM ESPs are typically 100 MB, and NixOS puts every
generation's kernel and initrd there — 512 MB is the usual recommendation, and
this repo's previous single-boot layout asked for 1 GiB. Phase 0 records the
actual size; the decision follows from it:

- **ESP ≥ 512 MB** → share it as-is. Nothing to do.
- **ESP is 100 MB** (the likely case) → either
  **(a)** live within it: `boot.loader.systemd-boot.configurationLimit = 3;`
  keeps three generations, which fits, at the cost of a shorter rollback
  history; or
  **(b)** grow it during the repartition, which means moving partition 3's
  start — real work, and the one operation in this plan most likely to end in
  a restore from the Phase 0 image. Only worth it if (a) proves too tight in
  practice.

Default to **(a)**. It is reversible, and `configurationLimit` is one line.

```nix
# hosts/desk/filesystems.nix — hand-partitioned, so hand-declared.
# PARTUUIDs from `blkid` after partitioning, NOT device paths.
{
  fileSystems."/" = {
    device = "/dev/disk/by-partuuid/<FILL_ME_ROOT>";
    fsType = "ext4";
  };

  # The ESP Windows created. `umask=0077` hides it from non-root; do not
  # reformat it, and do not let any tool "fix" it.
  fileSystems."/boot" = {
    device = "/dev/disk/by-partuuid/<FILL_ME_ESP>";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };

  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 3;   # a 100 MB shared ESP holds about this many
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # Windows writes local time to the RTC. Without this the two OSes fight over
  # the clock and you get an offset on every crossing.
  time.hardwareClockInLocalTime = true;
}
```

#### The bulk drive — disko's, and now shared

The game library partition changes meaning. It was "a raw block device handed to
the guest". It is now **the single NTFS Steam library both Windows installs
use**: a drive letter on bare metal, a raw block device on the guest.

That is safe *only* because of the mutual exclusion in the
[decisions table](#decisions-locked-in) — bare metal boots instead of NixOS, and
the guest only runs under NixOS, so the two can never mount it at once. NTFS is
not a cluster filesystem; two concurrent writers corrupt it. The structural
guarantee is what makes this work, not discipline.

Two conditions, both non-negotiable:

- **Fast Startup off** (`powercfg /h off`, Phase 0). Otherwise bare-metal
  Windows leaves the volume dirty on every shutdown and the guest either
  refuses it or damages it.
- **The host never mounts it.** No `fileSystems` entry, no automount. NixOS's
  only relationship with this partition is passing it to the guest.

The payoff is real: one library, installed once, usable from whichever Windows
is booted, and the OS/library split that made "rebuild the guest" cheap now also
means a guest rebuild costs nothing in re-downloads.

```nix
# hosts/desk/disko.nix — the BULK DRIVE ONLY. The fast drive is not described
# here and must never be added: disko would recreate its table and take Windows
# with it.
{
  disko.devices.disk.bulk = {
    device = "/dev/disk/by-id/nvme-<FILL_ME_BULK>";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        # Shared NTFS Steam library. Deliberately no `content`: disko creates
        # the partition and stops. Bare-metal Windows formats it NTFS once and
        # gives it a drive letter; the guest gets it as a raw block device.
        # The host never mounts it.
        games.size = "<FILL_ME>G";

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
}
```

**Why btrfs on the bulk drive and ext4 on root.** The media volume's job is
holding files nobody opens for months, which is exactly the condition under
which silent corruption goes unnoticed — and restic will faithfully back up a
corrupted file without complaint. btrfs checksums every block, so a monthly
`services.btrfs.autoScrub` turns bit rot into an alert instead of a surprise in
2029. Snapshots come along for free and cover the likelier loss: an accidental
delete you want undone in seconds rather than restored from Hetzner.

No compression — the payload is already-compressed video, so btrfs would decline
the extents anyway and the CPU is better spent elsewhere.

**Once this drive holds media, `disko --mode disko` is a destructive command.**
It is only meant to run at install, but it is sitting right there in Phase 2's
copy-pasteable block and it wipes every disk it manages. Post-install, the only
disko mode that should ever touch this machine is `--mode mount`. The Hetzner
backup is what makes that a bad afternoon rather than a permanent loss, which is
the clearest argument for doing Step 2 early rather than "once there's something
worth backing up".

**Split the Windows storage in two.** This is the design decision that makes the
"rebuildable image" choice survivable:

- `win-os.qcow2` — the C: drive. Small (~120 GB), disposable, regenerated by the
  image build. Losing it costs 30 minutes.
- a separate large volume mounted as the Steam library. **Persistent.** Never
  touched by a rebuild.

Steam re-adopts an existing library folder after a Windows reinstall — it
validates and moves on. Without this split, "rebuild the image" means
re-downloading the entire library and nobody does that twice, which is how
declarative setups quietly become pets.

#### Where the library volume lives

Four ways to give the guest that volume. Only the last is actually ruled out:

| Option | Mechanism | Trade |
| --- | --- | --- |
| Raw file on the **fast** SSD | `<disk type='file'>` on ext4 root | Lowest latency. Spends fast-drive capacity that root and `win-os.qcow2` also want |
| **Its own partition on the bulk SSD** | `<disk type='block' dev='/dev/disk/by-id/…-part1'>` | Near-native block performance, no CoW overhead, capacity where the capacity is. Host never mounts it |
| Raw file on the bulk SSD's btrfs | `<disk type='file'>` under `/srv` | Most flexible sizing, but needs `chattr +C` on the directory first or CoW fragmentation will hurt — and that disables checksums for the file |
| **Whole bulk NVMe via VFIO** | `vfio-pci` binds the device | **Ruled out.** VFIO takes the device away from the host, so the media volume and `/srv/media` go with it |

Only whole-device passthrough conflicts with serving media from that drive.
Everything else coexists fine: the host owns the disk, and the guest gets a
partition or a file on it.

**Default to the second row** unless Phase 0 says the bulk drive is meaningfully
slower rather than merely bigger. It gets near-native speed without spending
fast-drive capacity, and it keeps the two workloads on separate filesystems — a
guest that trashes its own NTFS cannot reach `/srv/media`, which matters because
one of those two is backed up and the other is deliberately disposable.

What you do give up by sharing the spindle: endurance and bandwidth. A Steam
download saturating the bulk SSD will slow an SMB read from it. Tolerable on a
single-user desktop; worth knowing before you diagnose it as a network problem.

---

## Phase 2 — Install, alongside Windows

**This phase is no longer a clean install.** Windows is on the fast drive and
stays there, so the destructive one-liner this section used to open with is
gone. Read [Disk layout](#disk-layout--dual-boot) first.

Preconditions, all from Phase 0: the drive is imaged, BitLocker is suspended,
Fast Startup is off, `C:` is already shrunk, and Secure Boot is off in firmware.

```sh
# 1. Fast drive: create the NixOS partitions BY HAND in the free space left by
#    the shrink. Partitions 1-4 (ESP, MSR, C:, WinRE) are Windows' — do not
#    touch them. `cgdisk` or `parted`, whichever you trust more under pressure.
#
#    NOT `disko --mode disko` against this drive. Not ever. It recreates the
#    whole table and Windows goes with it.

# 2. Bulk drive: this one IS disko's, and it is empty, so the destructive mode
#    is correct here exactly once.
nix --extra-experimental-features 'nix-command flakes' \
  run github:nix-community/disko -- --mode disko \
  --flake /path/to/nix-config#desk

# 3. Mount the hand-made partitions the way the installer expects.
mount /dev/disk/by-partuuid/<ROOT> /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-partuuid/<ESP> /mnt/boot      # Windows' ESP. Do NOT mkfs it.

# 4. Record the PARTUUIDs into hosts/desk/filesystems.nix before installing.
blkid

nixos-install --flake /path/to/nix-config#desk
```

Then reboot and **verify both directions before doing anything else** — a
dual-boot that only goes one way is a problem best found now, while the live USB
is still plugged in:

- [ ] systemd-boot's menu lists both NixOS and Windows
- [ ] Windows boots, and is still activated (Settings → System → Activation)
- [ ] NixOS boots
- [ ] Clocks agree after crossing between them — that is
      `time.hardwareClockInLocalTime` doing its job
- [ ] Resume BitLocker protection if Phase 0 suspended it

Then `sudo tailscale up`, `git clone` the repo to `~/natb1/nix-config`, and from
there it is the same `nixos-rebuild switch --flake .#desk` loop as every other
host.

- [ ] Add a `desk` row to the README's host table with its rebuild command

**Windows updates will sometimes reassert themselves as the default boot
entry.** This is normal, not a failure: `efibootmgr -o` from NixOS, or the
firmware's boot menu, puts systemd-boot back in front. Worth knowing before it
happens at an inconvenient moment.

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

Keep the lesson, though. It applies directly to §6 below: **pin immutable URLs.**
`pkgs.virtio-win` is hash-pinned in nixpkgs precisely so this does not recur.

---

## Media storage

Off the phase sequence deliberately. This needs Phases 1–2 (the box exists and
boots) and **nothing in the VM track depends on it**, so it can land the week the
machine is installed, months before any passthrough work.

The desktop has **two SSDs with different jobs**, and keeping them straight is
what the rest of this section rests on:

| Drive | Chosen for | Holds |
| --- | --- | --- |
| **fast** | latency | Windows `C:` (kept), `/` and `win-os.qcow2` |
| **bulk** | capacity | `/srv/media` (host-mounted, shared, backed up) and, by default, the shared NTFS Steam library used by both Windows installs — [§1](#disk-layout--dual-boot) picks between them |

The two live on one disk but never share a filesystem: the host mounts the media
partition and never touches the games one. The games partition is NTFS, and
**both** Windows installs use it — a drive letter on bare metal, a raw block
device in the guest — which is safe only because they can never be running at
the same time. [Disk layout](#disk-layout--dual-boot) has the conditions that
keep it so.

Two steps, in this order. The share is useful on day one; the backup is what
makes the share safe to depend on.

### Step 1 — `/srv/media` as a network share

**SMB, not NFS.** The clients are the MacBook today and both Windows installs
after Phase 6 — bare metal reaches the share over the LAN like any other client,
which is a second reason SMB is the right protocol. NFS on macOS is a long-standing disappointment — Finder integration,
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

**Start with Hetzner**, sized to the **media partition** rather than the whole
bulk drive — the games partition is disposable by design and the host does not
even mount it, so nothing on it can be swept into a backup.
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

```nix
# hosts/desk/vfio.nix
{ config, pkgs, lib, ... }:
{
  boot.kernelParams = [
    "amd_iommu=on"
    "iommu=pt"                       # passthrough mode: no DMA translation for host devices
    "vfio-pci.ids=<VEND:DEV>,<VEND:DEV_AUDIO>"   # from Phase 0 step 2
  ];

  # vfio must claim the card before amdgpu/nvidia can. initrd, not kernelModules.
  boot.initrd.kernelModules = [ "vfio_pci" "vfio_iommu_type1" "vfio" ];

  # The host's iGPU driver. amdgpu for a Ryzen APU.
  boot.kernelModules = [ "kvm-amd" "amdgpu" ];

  # Host graphics run on the iGPU. (hardware.opengl was renamed in 24.11.)
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;   # Steam/Proton need the 32-bit stack

  # ONLY if Phase 0 shows a Radeon dGPU with the reset bug:
  # boot.extraModulePackages = [ config.boot.kernelPackages.vendor-reset ];
  # boot.kernelModules = [ "vendor-reset" ];
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

**Verify before building a VM:** after the switch and reboot,
`lspci -nnk -d <VEND:DEV>` must show `Kernel driver in use: vfio-pci`. If it
still shows `amdgpu` or `nvidia`, the binding lost the race — that is the
symptom of `vfio_pci` being in `boot.kernelModules` instead of
`boot.initrd.kernelModules`.

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
  # Fill from Phase 0's `lstopo`. On Ryzen, keep the guest inside ONE CCD —
  # cross-CCD memory access goes over Infinity Fabric and costs real latency.
  hostCpus = "0-3,16-19";     # cores NixOS keeps
  allCpus  = "0-31";
  hugepages2M = 12288;        # 24 GiB guest / 2 MiB
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
  <topology sockets='1' dies='1' cores='6' threads='2'/>
  <feature policy='require' name='topoext'/>   <!-- AMD: guest sees correct SMT -->
  <cache mode='passthrough'/>
</cpu>
<cputune>
  <vcpupin vcpu='0' cpuset='4'/>  <!-- pair each vcpu to its SMT sibling -->
  <vcpupin vcpu='1' cpuset='20'/>
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

## Phase 6 — Managing both Windows installs

### The honest framing

Windows has no store, no closure, and no atomic rollback. Every tool below is
**convergent**, not declarative in the Nix sense: applying a config moves the
system toward a state, but deleting a line from the config does *not* remove
what it installed. There is no `nixos-rebuild switch` that garbage-collects a
registry key.

There are now **two** Windows installs, and the thing that used to rescue the
convergent layer no longer covers both:

| | Bare metal | Guest |
| --- | --- | --- |
| Holds the activated license | **yes** | no, permanently |
| Holds user data | yes | no |
| Can be thrown away and rebuilt | **no** | yes, cheaply |
| Anti-cheat titles | yes | no |
| Reachable from NixOS while NixOS is running | **no** — dual-boot | yes |

"Rebuild the image" was the answer to drift. It is still the answer *for the
guest*. For the metal it is not an answer at all, which means the convergent
layer has to actually be good rather than merely be a first pass before a
rebuild. That is the real cost of keeping bare-metal Windows, and it is worth
paying: the metal is where the license and the anti-cheat titles live.

So the layers, with which target each one serves:

| # | Layer | Ceiling | Metal | Guest |
| --- | --- | --- | --- | --- |
| 1 | **VM definition** — domain XML, VFIO, pinning, hugepages | Fully declarative. It is all Nix | — | ✓ |
| 2 | **OS install** — edition, partitioning, user, locale, skip OOBE | Fully declarative. The answer file is generated data | — | ✓ |
| 3 | **Driver injection** — virtio storage/net/balloon | Fully declarative, hash-pinned | — | ✓ |
| 4 | **Apps & settings inside Windows** | **Convergent only** | ✓ | ✓ |
| 5 | **Drift repair** | The actual decision | Converge; repair-install as last resort | Rebuild |

**Layer 4 is the shared one, and it is the whole of this phase's new work.**
Layers 1–3 are guest-only and unchanged from the single-Windows plan.

### One profile set, two targets

The requirement is a single method that covers both installs, uses idioms a
Windows admin would recognise, and lives in version control here. That resolves
to: **Nix is the source of truth, WinGet DSC is the applier, and the rendered
artifacts are committed to this repo.**

```
hosts/desk/windows/
  profiles/
    common.nix        # everything both installs get
    metal.nix         # bare-metal only: dGPU driver, anti-cheat titles, BitLocker
    guest.nix         # guest only: virtio guest tools, no account sign-in
  render.nix          # profile attrs -> DSC yaml + .reg + Apply.ps1 + Test.ps1
  rendered/           # GENERATED AND COMMITTED. This is what Windows reads.
    metal/
    guest/
  image.nix           # guest only: ISO, answer file, build script (layers 2-3)
```

`common.nix` carries the overlap — shells, browsers, fonts, Steam, the settings
you would be annoyed to set twice. `metal.nix` and `guest.nix` carry only what
genuinely differs. The divergence is small and *declared*, which is the point:
today the two installs differ because nobody wrote down how they differ.

A profile is ordinary Nix attrs:

```nix
# hosts/desk/windows/profiles/common.nix
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

and `render.nix` turns it into the files Windows actually consumes, via
`pkgs.formats.yaml` exactly as the previous plan generated the answer file:

```yaml
# hosts/desk/windows/rendered/metal/configuration.dsc.yaml
# GENERATED by `nix run .#render-windows`. Do not edit; edit profiles/ instead.
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

### Why the artifacts are committed, not just built

This is the part that dual-boot forces, and it is worth being explicit about
because it looks like a Nix anti-pattern.

**There is no push channel to bare metal.** NixOS and bare-metal Windows are
never running at the same time, so the host cannot `ssh` a config over the way
it could to the guest. Anything the metal applies, it must already have on disk.

So the flow inverts: **Nix renders, the render is committed, Windows pulls.**

```powershell
# On either Windows install, from an elevated PowerShell:
git -C C:\src\nix-config pull        # git clone once, on first run
cd C:\src\nix-config\hosts\desk\windows\rendered\metal    # or \guest
.\Apply.ps1
```

That is the entire Windows-side toolchain: **git and winget, both of which ship
with Windows or install from it.** No Nix on Windows, no SSH server required, no
control node, no network path between the two OSes. A Windows admin reading this
sees a repo, a YAML file and `winget configure` — idioms, not a foreign object.

The obvious risk is the committed render drifting from the profiles that
generated it. Close that with a flake check, so the repo cannot land a `.nix`
change without the regenerated artifacts beside it:

```nix
# checks.desk-windows-rendered — fails if `rendered/` is stale
pkgs.runCommand "check-windows-rendered" { } ''
  diff -r ${self.packages.${system}.windowsRendered} \
          ${./hosts/desk/windows/rendered} \
    || { echo "rendered/ is stale — run: nix run .#render-windows"; exit 1; }
  touch $out
''
```

This also recovers most of the `nix flake check` coverage lost by deleting the
wezterm Windows tests — see [Risks](#risks-ranked).

### Applying and testing on each target

WinGet DSC has a real test mode, which is what makes it usable as a *management*
tool rather than a one-shot installer:

| | Command | What it does |
| --- | --- | --- |
| Converge | `winget configure --file configuration.dsc.yaml --accept-configuration-agreements` | Brings the system to the described state |
| **Check drift** | `winget configure test --file configuration.dsc.yaml` | Reports each resource in / not in the desired state, changing nothing |

`Test.ps1` wraps the second one, and a Scheduled Task running it weekly on each
install turns drift from something you discover into something that tells you.
This is the closest Windows gets to `nixos-rebuild dry-activate`, and it is
worth wiring up on the metal especially, where there is no rebuild to fall back
on.

- [ ] Both installs: `git clone` this repo, run `Apply.ps1` once, confirm
      `winget configure test` comes back clean afterwards
- [ ] Both installs: register the weekly `Test.ps1` Scheduled Task
- [ ] Confirm the two profiles differ *only* where `metal.nix`/`guest.nix` say
      they do — run `test` on each with the other's YAML and read the diff

### What DSC cannot reach, and the escape hatch

WinGet DSC's resource coverage is good for packages and thin for settings.
Expect to hit things it cannot express. Two escape hatches, in order:

1. **A committed `.reg` file**, rendered from the same profile attrs and
   imported by `Apply.ps1`. Crude, diffable, and unambiguously a Windows idiom.
2. **Group Policy via `LGPO.exe`** (Microsoft Security Compliance Toolkit) for
   anything policy-shaped. A policy backup directory is version-controllable and
   applies identically to both targets.

Neither is elegant. Both keep the property that matters: the change is written
down in this repo rather than clicked once and forgotten.

**If WinGet DSC disappoints more broadly**, the upgrade path is
[Microsoft DSC v3](https://github.com/PowerShell/DSC) (`dsc.exe`) — the general
engine that `winget configure` is a front end to. Same YAML shape, far more
resources, one more thing to install on each target. Worth reaching for only
once winget's coverage is demonstrably the blocker.

**What was considered and rejected:**

- **Ansible over SSH/WinRM** — genuinely idempotent and far richer than DSC for
  settings work. Rejected on the structural point above: it needs a control node
  that can reach the target, and nothing can reach bare metal while NixOS is up.
  It would mean one method for the guest and a different one for the metal,
  which is precisely what this phase exists to avoid.
- **Chocolatey** — broader package coverage than winget for older software, and
  a Nix-generated package list is dead simple. Kept in reserve as a *supplement*
  for packages winget lacks, not as the framework; it has no settings story.
- **Scoop** — user-scope, no admin, good `scoop export`/`scoop import`.
  Complementary for CLI tools, wrong shape for games and system settings.
- **Per-target ad-hoc setup** — the status quo, and the thing that makes two
  Windows installs twice the work instead of one profile plus a delta.

### Drift repair, by target

**Guest: rebuild.** Unchanged, and still cheap because the OS disk and the game
library are separate ([Disk layout](#disk-layout--dual-boot)). A wrong state is
fixed by regenerating, not by hoping convergence noticed.

**Metal: converge, then escalate.** In order:

1. `Apply.ps1` — re-converge. Handles most drift.
2. `winget configure test` to find what convergence did not fix, then extend the
   profile so that it does. Every escalation past this point should leave a
   commit behind.
3. **In-place repair install** — mount the same Win11 ISO the guest build uses
   and run `setup.exe` from inside Windows, choosing "Keep personal files and
   apps". Rebuilds the OS around the install, preserving the license and data.
4. Reset this PC → Keep my files, then `Apply.ps1`. Last resort; loses apps,
   keeps the license.

Note what is *not* on that list: reinstalling from scratch. The metal holds the
activated digital license, and while a clean install would re-activate from the
account, it also means reproving something this plan deliberately never risks.

### Layer 1 — the VM definition

**Recommended: NixVirt.** It gives `virtualisation.libvirt.connections."qemu:///system"`
with declarative `domains`, `networks` and `pools`, a `lib.domain.templates.windows`
template that already wires OVMF Secure Boot + TPM, and `lib.domain.writeXML` for
building the XML from Nix attributes rather than pasting `virsh dumpxml` output.

Two caveats from its README, both of which bite if unexpected:

- **Domains, networks and pools not listed in the config are deleted.** That is
  the behaviour you want, but it means a VM someone creates in virt-manager
  vanishes on the next switch.
- Redefining an active domain deactivates and reactivates it — "like shutting
  the power off". Plan switches for when the VM is down.

The pragmatic alternative if NixVirt feels like too much surface area: build the
VM once in virt-manager, `virsh dumpxml win > hosts/desk/windows/domain.xml`,
commit it, and add a oneshot unit that `virsh define`s it. Less elegant, zero new
inputs, and the XML in git is still the source of truth. Both are fine; NixVirt
is better if you want the XML *generated* rather than *checked in*.

### Layers 2–3 — the guest image build

**Guest only.** Bare metal is already installed and is never rebuilt from an
answer file; it joins the story at layer 4, where it picks up the same profile
render as everything else.

Shape, with the Windows ISO kept out of git and out of the cache — the same ISO
serves the guest build and the metal's [repair-install path](#drift-repair-by-target):

```nix
# hosts/desk/windows/image.nix
{ pkgs, lib, ... }:
let
  cfg = {
    hostname = "win";
    username = "n8";
    locale   = "en-US";
    timezone = "Eastern Standard Time";
    packages = [ "Valve.Steam" "EpicGames.EpicGamesLauncher" "Microsoft.PowerShell" ];
  };

  # The ISO is ~6 GB, unredistributable, and Microsoft's download URLs rotate —
  # so it is NOT fetchurl'd. requireFile fails the build with instructions until
  # the operator adds it once:
  #   nix-store --add-fixed sha256 Win11_24H2_English_x64.iso
  windowsIso = pkgs.requireFile {
    name = "Win11_24H2_English_x64.iso";
    sha256 = "<FILL_ME>";
    message = ''
      Download the Windows 11 ISO from Microsoft, then:
        nix-store --add-fixed sha256 Win11_24H2_English_x64.iso
    '';
  };

  # Layer 2: the answer file, generated from cfg rather than hand-maintained.
  autounattend = pkgs.writeText "autounattend.xml" ''
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <!-- windowsPE: disk layout, edition, generic Pro key (selects the
           edition and clears the key prompt; activates nothing) -->
      <!-- oobeSystem: local account ${cfg.username}, skip MS account, skip telemetry.
           NOTE: skipping the account means the guest stays unactivated until
           you sign in later — see Phase 0, "Getting the digital license into
           the guest". That is the intended order, not an oversight. -->
      <!-- FirstLogonCommands: powershell -File D:\provision.ps1 -->
    </unattend>
  '';

  # Layer 4: the package/settings manifest, generated from Nix attrs.
  dsc = (pkgs.formats.yaml { }).generate "configuration.dsc.yaml" {
    properties = {
      configurationVersion = "0.2.0";
      resources = map (id: {
        resource = "Microsoft.WinGet.DSC/WinGetPackage";
        inherit id;
        directives.description = "Install ${id}";
        settings = { inherit id; source = "winget"; };
      }) cfg.packages;
    };
  };

  provision = pkgs.writeText "provision.ps1" ''
    winget configure --file D:\configuration.dsc.yaml --accept-configuration-agreements
    # GPU scheduling, power plan, OpenSSH server (so the host can converge later)
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
  '';

  # Windows Setup scans removable media for autounattend.xml at the root.
  answerIso = pkgs.runCommand "answer.iso" {
    nativeBuildInputs = [ pkgs.xorriso ];
  } ''
    mkdir root
    cp ${autounattend} root/autounattend.xml
    cp ${provision}    root/provision.ps1
    cp ${dsc}          root/configuration.dsc.yaml
    xorriso -as mkisofs -J -r -V UNATTEND -o $out root
  '';
in
# Layer 3 + the build itself.
pkgs.writeShellApplication {
  name = "build-windows-image";
  runtimeInputs = [ pkgs.qemu_kvm pkgs.OVMFFull pkgs.swtpm ];
  text = ''
    # qemu-system-x86_64 -enable-kvm \
    #   -drive file=win-os.qcow2,if=virtio \
    #   -cdrom ${windowsIso} \
    #   -drive file=${answerIso},media=cdrom \
    #   -drive file=${pkgs.virtio-win}/share/virtio-win/virtio-win.iso,media=cdrom \
    #   ... OVMF, swtpm, headless
  '';
}
```

**Why `writeShellApplication` and not a derivation.** A true Nix build would be
purer, but the provisioning step needs the network (winget reaches out to
Microsoft's catalog) and the whole thing takes 30+ minutes with KVM. Forcing it
into the sandbox means either `__noChroot` or a fixed-output derivation whose
hash changes every time upstream ships a Steam update — both are fragile in ways
that produce confusing failures later. A script whose *inputs* are all
Nix-pinned and whose *execution* is imperative is the honest ceiling here. Say so
in the file's header comment so the next reader does not "fix" it.

**Alternatives for the build step, if hand-rolling QEMU is more than you want:**

- **Packer** (`pkgs.packer`) with a Nix-generated HCL template. More machinery,
  but it is the tool everyone else uses for exactly this, and it handles the
  boot-command/floppy/WinRM-wait dance you would otherwise write yourself.
- **`dockur/windows`** — a container that wraps QEMU and does ISO download,
  unattend generation and virtio injection for you. Fastest path to a working
  VM, but GPU passthrough through the container layer is awkward and you inherit
  its opinions. Reasonable as a "get it working this weekend, graduate later"
  step; not a destination.

Layer 4's alternatives are covered above, in
[What DSC cannot reach](#what-dsc-cannot-reach-and-the-escape-hatch) — they now
have to serve both installs, which rules out more of them than it used to.

One thing the answer file should still do, even though the guest is never
pushed to: enable `OpenSSH.Server`. It is not the config channel — `Apply.ps1`
pulling from the repo is — but it makes the guest reachable from the host for
everything else, and the metal cannot have that regardless.

### Secrets

**The product key is not a secret here.** [Phase 0](#windows-licensing--resolved)
settled that this machine activates by digital license, so the only key the
answer file carries is `VK7JG-NPHTM-C97JM-9MPGT-3V66T` — a placeholder Microsoft
publishes. It goes in `image.nix` in plaintext. Nothing about it needs
`requireFile` or an encrypted store, and on its own it is not a reason to adopt
`sops-nix`/`agenix`.

What *is* secret is the rest of the answer file: the local account password, and
any credentials the provisioner needs. Those must not land in git — keep them in
a `requireFile`'d fragment alongside the ISO, or encrypt them in the repo with
`sops-nix`/`agenix`. This is the same category as
`~/.config/nix/access-tokens.conf` in the README's "state this repo does not
manage" list — add the answer-file secrets to that list either way.

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

**Dual-boot**

- [ ] systemd-boot offers both entries, and both boot
- [ ] Bare-metal Windows still reports **activated** after every step of this
      plan — check it again here, not just in Phase 2
- [ ] Clocks agree after crossing between the two
- [ ] BitLocker protection is resumed, and a reboot does not prompt for the
      recovery key
- [ ] The shared games partition mounts read-write on bare metal, and Steam
      adopts the library without re-downloading
- [ ] `powercfg /a` on bare metal shows hibernation disabled — this is what
      keeps the shared NTFS clean, and a Windows update can quietly re-enable it

**Guest**

- [ ] `virsh list` shows `win` running; Device Manager shows no unknown devices
- [ ] The guest is **unactivated and not signed into a Microsoft account** —
      this is the desired state, not a defect. If it ever reads "activated",
      the license moved off the metal and needs moving back
- [ ] The guest sees the same games partition as a raw device, and Steam adopts
      it — with bare-metal Windows **not** running, which it cannot be
- [ ] dGPU in the guest with the vendor driver loaded, no Code 43 / Code 31
- [ ] `winget list` matches the package list in `image.nix`
- [ ] A game runs at expected frame rate with acceptable frame *times* — check
      1% lows, not the average; VM problems show up as stutter, not low FPS
- [ ] Audio plays, and keeps playing after an alt-tab
- [ ] The Steam library volume mounted and adopted without re-downloading

**The performance hook — the part most likely to be silently wrong**

- [ ] With the VM **down**: `nproc` sees every core; a `nixos-rebuild build` runs
      at full speed
- [ ] With the VM **up**: `systemctl show user.slice -p AllowedCPUs` shows only
      the host cores; `cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages`
      is nonzero; `cpupower frequency-info` says performance
- [ ] After `virsh destroy win` (not a clean shutdown — test the crash path):
      everything above reverts. `release/end` is what makes this true; if it
      does not fire, the host stays crippled after every crash
- [ ] Reboot with the VM set to autostart off, confirm nothing is degraded

**Windows management — the part that now has to work twice**

- [ ] `winget configure test` comes back clean on **both** installs after
      `Apply.ps1`
- [ ] Add a package to `common.nix`, re-render, commit, `git pull` + `Apply.ps1`
      on each install, and confirm both converge. This is the whole method in
      one test; if it is awkward here it will be awkward forever
- [ ] `nix flake check` fails when `rendered/` is stale — verify by editing a
      profile and *not* re-rendering
- [ ] The weekly `Test.ps1` Scheduled Task exists on both and reports somewhere
      you will actually see it

**The rebuild path — test it before you need it**

- [ ] Delete `win-os.qcow2`, re-run `build-windows-image`, confirm the guest
      comes back with the same packages and the game library intact. If this
      does not work, the "declarative" claim is decorative.
- [ ] Confirm the rebuilt guest is still unactivated and still not signed in —
      a rebuild that silently grabs the license is worse than no rebuild

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
      install and the `G:` volume are gone; the Windows ISO, the Microsoft
      account the guest's digital license hangs off (no product key — see
      [Secrets](#secrets)), rclone credentials, the Samba password database
      (`smbpasswd`), and `/etc/restic/{media.password,id_ed25519}` are new

---

## Risks, ranked

1. **The repartition eats the Windows install.** Now the top risk, and new.
   Shrinking `C:` in place puts the activated license, the anti-cheat titles and
   whatever is on `C:\` behind one partition-table edit. Mitigations, all in
   Phase 0 and none optional: image the drive first, shrink from inside Windows
   rather than from Linux, suspend BitLocker before touching anything, and never
   let disko near the fast drive.
2. **A stray `disko --mode disko` destroys Windows.** Distinct from the media
   version below and worse. The fast drive is deliberately absent from
   `disko.nix`; the danger is a future edit "completing" it for tidiness. The
   comment in that file is load-bearing — leave it there.
3. **The guest steals the license.** One Microsoft account sign-in inside the VM
   deactivates bare metal. It is a two-click mistake with a rate-limited fix,
   and nothing in the system prevents it, which is why it is written down in
   [the licensing section](#can-one-license-cover-bare-metal-and-the-vm) and
   checked in Phase 8.
4. **The shared games partition gets mounted twice.** Structurally prevented —
   the two Windows installs cannot run at once — but Fast Startup re-enabled by
   a Windows update reintroduces the dirty-NTFS version of the same damage.
   `powercfg /a` is on the Phase 8 list for this reason.
5. **Windows updates take the boot entry.** Cosmetic, recoverable with
   `efibootmgr -o`, and alarming the first time. Listed so it is not diagnosed
   from scratch at 11pm.
6. **The two Windows installs drift apart.** The failure mode Phase 6 exists to
   prevent: profiles that describe the metal well and the guest approximately,
   until "run `Apply.ps1`" stops being trustworthy on one of them. The weekly
   `winget configure test` task and the stale-`rendered/` flake check are the
   two things standing against it.
7. **IOMMU groups are dirty.** Found in Phase 0, before anything is destroyed.
   This is why Phase 0 is a gate and not a formality.
8. **The Windows image build is a long feedback loop.** 30+ minutes per attempt,
   and an answer-file typo fails near the end. Iterate on the answer file against
   a *plain* VM with no passthrough first — separate the two variables.
9. **The performance hook does not revert.** A crashed VM leaving the host
   pinned to four cores is the kind of bug you diagnose three weeks later as
   "NixOS feels slow lately". The `virsh destroy` test in Phase 8 exists for
   exactly this.
10. **Steam library on a disposable volume by accident.** Phase 1's split
   prevents it; verify with the Phase 8 rebuild test.
11. **The media backup stops and nobody notices.** The failure mode of every
   backup that has ever failed. `runCheck` plus the `OnFailure` hook in
   [Media storage](#media-storage) are the minimum; the restore drill is what
   actually proves it. Ranked below the Windows risks only because those are
   time-boxed to the migration itself — this one is permanent, and of everything
   on this list it is the likeliest to be discovered too late.
12. **A stray `disko --mode disko` wipes the media volume.** The bulk drive is
   under disko's management, and disko's destroy mode does not ask. Treat the
   Phase 2 command block as install-only; everything afterwards is
   `nixos-rebuild`. This risk is the reason the backup is not optional.
13. **Samba serving an empty share.** If the bulk SSD does not mount, an
   unguarded smbd exports `/srv/media` on the root filesystem and clients write
   into it. The `requires=srv-media.mount` binding prevents it; verify by
   booting once with the drive pulled.
14. **`nix flake check` coverage drops.** Deleting the wezterm Windows tests
   removes 15 checks' worth of real assertions. Whatever replaces them — image
   build smoke test, domain XML eval test — should land in the same PR as the
   deletion, or it never lands.

## Deliberately not doing

- **~~Dual-boot.~~** Reversed — bare-metal Windows is kept. It carries the
  activated license and it is the only place kernel anti-cheat can run: Vanguard
  and similar want Secure Boot, TPM 2.0, IOMMU, VBS and HVCI *on bare metal*,
  which no amount of guest configuration provides. The cost is everything in
  [Risks](#risks-ranked) 1–6 and the convergent-only repair path for the metal
  in [Phase 6](#phase-6--managing-both-windows-installs).
- **Booting the bare-metal partition as the guest.** Rejected in
  [the licensing section](#can-one-license-cover-bare-metal-and-the-vm): it
  re-hashes activation on every crossing, which is the one thing this plan
  protects.
- **A second Windows license for the guest.** The guest runs unactivated
  instead. Revisit only if the guest stops being a test bed.
- **Hypervisor hiding.** Costs performance, buys nothing here.
- **Mirroring the two SSDs.** They are different sizes with different jobs, so
  RAID1 would cost capacity to buy coverage of exactly one failure mode — while
  propagating every other one (`rm -rf`, corruption, ransomware) to both copies
  instantly. The restic tier covers the drive death *and* the rest for less than
  the capacity a mirror would give up. RAID is availability; this is a desktop.
- **Moving the desktop modules into `modules/nixos/`.** One desktop host does not
  justify the abstraction; the repo's own host-vs-platform rule says so.
