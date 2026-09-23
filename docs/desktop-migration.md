# Plan — WSL → native NixOS, with one Windows that boots bare metal or virtualized

Written 2026-09-20. This is the *second* migration this repo has tracked; the
first — moving the WSL host off `commons.systems` and onto this repo — finished
on 2026-09-21. This one is about the desktop stopping being a Windows box that hosts NixOS, and becoming a machine that runs
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
| Windows' disk is touched once, by 300 MB | The big shrink, the ESP sharing, the drive image, the restore-from-backup risk |
| Disko never meets a Windows partition | Hand-partitioning, hand-written `fileSystems`, `configurationLimit = 3` |
| One install means one license | The unactivated second copy, and the rule against signing into it |
| Metal and guest are the same C:\ | Two config profiles, the drift between them, the answer file, the image build |

What it costs, stated up front rather than discovered in Phase 4: **NixOS
root, the host-side game library and the media volume all share the 1 TB
drive** (the two SSDs turned out to be the same model, so the tax is capacity,
not speed), activation needs the guest to
[impersonate the host's hardware](#keeping-activation-stable-across-the-crossing),
bare metal and the guest see [two different TPMs](#two-tpms-one-install), and
the fast NVMe controller must sit in a clean IOMMU group — a second gate
alongside the GPU's.

Sequencing: **the WSL switch came first, and it is done.** Switching the WSL
host onto this repo was the cheap, reversible change that proved the repo works;
it passed QA and was cleaned up on 2026-09-21. Repurposing the desktop's drives
is neither cheap nor reversible, which is why it waited. Nothing outside this
plan gates it now — Phase 0 is the only go/no-go.

---

## Status — 2026-09-21

### Done

- **Phase 0, Windows side** — inventory measured and recorded
  ([below](#phase-0-windows-side--measured-2026-09-21)); the plan's code
  corrected where it disagreed (ESP location, NVMe binding, RTC, CPU pinning).
- **Licensing** — RETAIL, digital license linked to the Microsoft account.
- **BitLocker** off (fully decrypted), **Secure Boot** off, **Fast Startup /
  hibernation** off (`powercfg /h off`, verified with `powercfg /a`).
- **Old Linux partitions on the 1 TB drive** — disposable, no backup needed.
- **Games** stay on the 2 TB Windows drive; the games-partition fallback is gone.
- **The WSL switch** — the WSL host runs from this repo as `.#wsl` (hostname
  `wsl`), and the `commons.systems` migration that gated this plan is closed.
- **WezTerm's WSL-only split** — the Windows GUI defaults and the
  copy-to-Windows activation moved out of the shared module into
  `hosts/wsl/home/wezterm-windows-config.nix`, and the platform guards became
  `stdenv.hostPlatform.*`. A second Linux host no longer inherits WSL behavior.
- **Windows' own ESP** — a 300 MB ESP exists on the 2 TB drive (disk 1,
  partition 3), `bcdboot` wrote the boot files to it, and **Windows booted from
  it** on 2026-09-23: `Get-Partition | ? IsSystem` → disk 1, partition 3, and
  `Get-Partition -DiskNumber 1` shows MSR, `C:`, ESP (300 MB,
  `{c12a7328-…}`, `IsSystem`), WinRE — in that order, numbered 1–4.

### Next, in order

1. **Finish proving the new ESP.** The boot from it is done (above). Still to
   do, from that boot (elevated):
   `reagentc /disable; reagentc /enable; reagentc /info` → WinRE **Enabled**.
   The re-run is required: the first one registered WinRE in the BCD Windows
   was running from, which was the *old* ESP's. Then confirm Settings → System
   → Activation.
2. **Update the motherboard firmware** — see
   [Firmware update](#firmware-update). After step 1, so a boot failure has one
   cause, not two.
3. **Phase 1** — land `hosts/desk` in the flake, from WSL. Independent of
   steps 1–2; can run any time.
4. **Phase 0, Linux side** — live USB: IOMMU groups (**the go/no-go gate**),
   `/dev/disk/by-id` names, `smartctl`, `lscpu -e`, `dmidecode`,
   `nixos-generate-config`, interface names from `ip link`.
5. **Phase 2** — install NixOS on the 1 TB drive, Secure Boot off.
6. **Phase 2b** — turn Secure Boot back on, with lanzaboote and your own keys
   plus Microsoft's.

### Decided 2026-09-21

- **Network: Wi-Fi everywhere, for now.** NixOS, bare-metal Windows and the
  guest all use the MediaTek RZ616 (MT7922). Consequences:
  [Networking on Wi-Fi](#networking-on-wi-fi).
- **NixOS root: 200 GB.** The rest of the 1 TB drive, ~730 GB, is one btrfs
  volume shared by `/srv/media` and `/srv/games`, the host-side Steam library
  — see [Where the Steam library lives](#where-the-steam-library-lives).
- **The media is irreplaceable** — cannot be re-downloaded or re-ripped. So the
  offsite backup is Hetzner, append-only is mandatory rather than optional, and
  the backup lands before the media does. See [Media storage](#media-storage).
- **Printer: NixOS shares it** (added 2026-09-23). The Brother HL-L2305 on
  USB moves from a local Windows queue to a CUPS queue on the host, published
  to the LAN, the guest and the tailnet — see
  [Printer sharing](#printer-sharing). Bare-metal Windows keeps printing
  locally; the network loses the printer for those sessions.
- **Board revision: 1.0** (per the box). Firmware must come from the rev 1.0
  download page — see [Firmware update](#firmware-update).

### Corrected 2026-09-23 (review)

Nothing here changes a decision; each is a place where the pasted config or
the text was wrong about how the machine behaves.

- **Phase 4's NVMe binding used `new_id`**, which is an ID match and would
  have taken the host's root drive too — the exact failure Risk 3 describes.
  Now `driver_override`.
- **Host reboots would have power-cut Windows' disk**: libvirt cannot save a
  VFIO domain, and NixOS's default asks it to. `onShutdown = "shutdown"`,
  `onBoot = "ignore"`, and Risk 1 and the Phase 8 drill rewritten around what
  can actually happen (a paused domain; a host reboot).
- **Windows Hello** was unaccounted for: two TPMs, one install, a PIN that
  breaks on every crossing. New section, Phase 0 decision, Phase 8 check,
  Phase 9 state, Risk 9.
- **The perf hook's teardown could abort before restoring the cpusets**
  (`set -e` plus a governor name amd-pstate does not offer). Reordered, made
  failure-tolerant, sysfs instead of `cpupower`, hugepage allocation verified.
- **Samba's `bind interfaces only`** would have left the share unreachable
  from the tailnet and the guest; dropped, scoping stays with the firewall.
- **The host-side Steam library** had nowhere to live but the 200 GB root;
  `/srv/games` subvolume, and the sizing residual now includes it.
- Smaller: boot-loader lines and the CI host list in Phase 1; `managed='no'`
  on the NVMe hostdev; the domain `<uuid>` must equal the sysinfo one;
  `programs.ssh.knownHosts` for the Storage Box; Initial Display Output on the
  iGPU; disko's current CLI spelling; the winget WezTerm that contradicted
  Phase 3 removed; Looking Glass host pinned to the client's release; Takeout
  quota; stale "slower drive" text after Phase 0 found identical drives.

### Residuals — open, not blocking the next step

| Item | Where it bites | Notes |
| --- | --- | --- |
| Board revision on the PCB itself | Step 2 | The box says 1.0. The silkscreen on the board (near the bottom edge, "REV: 1.x") is authoritative; worth a glance before flashing |
| Wi-Fi interface name on NixOS | Samba, CUPS, firewall | `<FILL_ME_WLAN_IF>` — from `ip link` on the live USB (likely `wlp14s0`-shaped) |
| Total size of the media, across all five sources | Media storage, [Step 3](#step-3--bring-the-media-in) | Google Drive + Google Photos + the MacBook + a GCS bucket + Flickr must fit in ~730 GB after de-duplication — **together with the host-side Steam library**, which shares that volume. If they do not, the root/media split or the drive changes — measure before Phase 2 fixes the split |
| GCS bucket: storage class and egress | [Step 3](#step-3--bring-the-media-in) | Coldline/Archive add per-GB retrieval fees on top of internet egress. Check the class before pulling |
| Flickr export request | [Step 3](#step-3--bring-the-media-in) | Asynchronous — Flickr prepares the archive over hours to days. Request it early so it is ready by ingest; download links expire |
| Google Takeout export request | [Step 3](#step-3--bring-the-media-in) | Same shape as Flickr, worse deadline: Takeout is prepared over hours to days and the **download links expire after 7 days**. Request it with *delivery to Google Drive* so it lands somewhere rclone can pull from unattended, instead of a browser download that must finish inside the window |
| Google Photos library size and item count | [Step 3](#step-3--bring-the-media-in) | Read both off [photos.google.com](https://photos.google.com) before requesting the export — the count is the only verification Takeout admits, and it has to be recorded *before* the library changes under it |
| Google One quota headroom for the Takeout archive | [Step 3](#step-3--bring-the-media-in) | Delivery to Drive stores the archive *in* Drive, against the same quota Photos already fills, so it needs free space equal to the library. No headroom → download-link delivery pulled inside the 7 days, or a month of extra storage |
| Windows Hello sign-in method | Before the first guest boot | Bare metal and the guest use different TPMs, so a TPM-backed PIN is invalidated on every crossing — [Two TPMs, one install](#two-tpms-one-install). Decide: password sign-in, PIN re-created per crossing, or test fTPM passthrough |
| Fate of the Drive/Photos/GCS/MacBook/Flickr copies | After the restore test | Keep, or retire in favour of `/srv/media` + Hetzner. Not before the restore test either way |
| Stale NVRAM entry for the old ESP | Phase 2 | Once disko wipes the 1 TB drive, the old "Windows Boot Manager" entry points at nothing. `efibootmgr -b <n> -B` it, alongside the `efibootmgr -o` step |
| `C:` free space | Ongoing | ~88 GB after the ESP. Games live here; the answer to "full" is uninstalling or a bigger Windows drive, never the 1 TB drive |
| `virtio-win` NIC/balloon drivers | Before the first guest boot | Install from bare metal via `pkgs.virtio-win`'s ISO |
| `account.microsoft.com/devices` | Before Phase 8 | Note the name the PC is listed under — it is how the Activation Troubleshooter identifies it |
| Game library vs ProtonDB, and each title's Secure Boot/TPM requirement | Before Phase 7; Phase 2b | Which titles need Windows at all, which of those need bare metal (kernel anti-cheat), and which of *those* refuse to start without Secure Boot (e.g. Battlefield 6, recent Call of Duty). The last list is why [Phase 2b](#phase-2b--restore-secure-boot) exists |
| Printer's USB URI | [Printer sharing](#printer-sharing) | The serial-keyed `usb://Brother/HL-L2305%20series?serial=U66480F3N341782` is built from what Windows reports; `lpinfo -v` after Phase 2 is authoritative |
| Alerting for `OnFailure` | Media storage | `<FILL_ME_notify_unit>` — the repo has no notification path yet |

### Firmware update

**Currently F9d (2023-09). Target: F43c (2026-07-20, AGESA 1.3.0.1c).**

The board is rev 1.0, and rev 1.0/1.1 BIOSes are listed on Gigabyte's
*un-suffixed* B650I AORUS ULTRA page — the same F-series line this board is
already on (F9 → F20 → F30 → … → F43c). Rev 1.3 and 1.4 have their own pages
and their own files; **never flash a file from those.** Checked 2026-09-21:

| | |
| --- | --- |
| Support page | <https://www.gigabyte.com/Motherboard/B650I-AORUS-ULTRA/support> |
| File | [`mb_bios_b650i-aorus-ultra_8arpl109_f43c.zip`](https://download.gigabyte.com/FileList/BIOS/mb_bios_b650i-aorus-ultra_8arpl109_f43c.zip) (14.57 MB) |
| Checksum (as published) | `9D0F` |
| Previous | F43b (2026-06-29), F42 (2026-05-20) — fallbacks if F43c misbehaves |

Three years of AGESA updates is worth taking before the
Linux-side Phase 0 pass, for this plan specifically: IOMMU grouping and ACS
behaviour come from the firmware, and on a mini-ITX board with one x16 slot a
firmware update is the only lever available if the groups come back dirty.
Security fixes come along too — among them LogoFAIL (F21), Sinkclose (F33a),
the microcode-signature CVE-2024-36347 (F34/F37), TPM CVE-2025-2884 (F37), and
the DDR5 Rowhammer mitigation option (F41).

Mechanics: download the file above, unzip it onto a FAT32 USB stick, flash with **Q-Flash** (or Q-Flash Plus, no CPU/RAM needed)
from the firmware setup. Not from inside Windows.

A firmware update resets settings to defaults. Afterwards, re-check:

- [ ] **SVM** enabled and **IOMMU** set to Enabled (not Auto)
- [ ] **Initial Display Output: IGD** (the iGPU), not the PCIe slot. If the
      firmware POSTs on the dGPU, the kernel's simpledrm claims the card's
      framebuffer before vfio-pci binds and the bind fails with
      `BAR 0: can't reserve` — see [Phase 4](#phase-4--vfio-and-the-libvirt-host).
      Bare-metal Windows is unaffected: it drives the dGPU from its own driver
      whichever GPU the firmware posted on
- [ ] **Secure Boot off — it will not be.** F38's release notes: *Secure Boot
      enabled as system default*. So after flashing it is **on**, and must be
      turned off again (Windows boots either way; systemd-boot without
      lanzaboote does not). CSM off. *Once [Phase 2b](#phase-2b--restore-secure-boot)
      is done this check inverts:* a flash may also reset the key databases to
      factory defaults, dropping your enrolled key — NixOS then refuses to boot
      until the keys are re-enrolled. See Phase 2b's recovery note
- [ ] Boot order — Windows Boot Manager on the **2 TB** drive first (until
      NixOS exists)
- [ ] XMP/EXPO memory profile, if it was on before
- [ ] Windows boots and is still activated. The fTPM may be cleared by an AGESA
      jump; with BitLocker off that costs nothing but possibly a Windows Hello
      PIN re-setup
- [ ] Wi-Fi still works in Windows (the only network this machine has)
- [ ] Record the new version in the Phase 0 table

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

1. **Windows' disk is modified exactly once, by 300 MB.** Phase 0 found Windows'
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
   drift"; it is **booting bare metal while the guest is paused, or rebooting
   the host while the guest is still up**, which leaves the one NTFS mid-flight.
   libvirt will not *save* a domain with VFIO devices, so the saved-guest case
   cannot happen — but NixOS's default for a host shutdown is to try exactly
   that save, fail, and let the guest be killed. See [Risks](#risks-ranked) 1
   and the `onShutdown` setting in [Phase 4](#phase-4--vfio-and-the-libvirt-host).
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
| Board / BIOS | Gigabyte **B650I AORUS ULTRA** (mini-ITX), AMI BIOS **F9d** (2023-09) | Mini-ITX has **one** x16 slot: "move the card to another slot" is not an IOMMU-gate fallback here. Board is **rev 1.0** (per the box). The BIOS is three years old (latest for this revision: **F43c**, 2026-07-20) — [Firmware update](#firmware-update) |
| CPU / RAM | Ryzen 5 **7600X**, 6C/12T, **one CCD**; **32 GB** RAM; SVM enabled in firmware | No cross-CCD concern. Phase 5's numbers were written for a 16-core/64 GB box and are now corrected — guest 4C/8T + 16 GiB, host 2C/4T |
| dGPU | **Radeon RX 6600 XT** (Navi 23, RDNA2) `1002:73ff` + HDMI audio `1002:ab28`, Windows PCI bus 3 fn 0/1 | RDNA2: **no `vendor-reset`**. Both IDs are unique on this box, so `vfio-pci.ids` is safe *for the GPU* |
| iGPU | Raphael `1002:164e` | Host graphics; different ID from the dGPU, so the `vfio-pci.ids` match cannot catch it |
| SSDs | **Both SK hynix Platinum P41** (`SHPP41-1000GM`, `SHPP41-2000GM`), both NVMe, controller ID **`1c5c:1959` on both** | (1) There is no fast/bulk split — same drive family, same performance, so the `fio` worry evaporates and [Risk 7](#risks-ranked) is about capacity, not speed. (2) **[Risk 3](#risks-ranked) is confirmed**: `vfio-pci.ids` would take both controllers — and so would a `new_id` write. Bind by PCI address with `driver_override` — [Phase 4](#phase-4--vfio-and-the-libvirt-host) |
| Windows' drive | `C:` is the **2 TB** P41 (Windows disk 1, CPU-attached controller), 1862 GB NTFS, **89 GB free**. Its partitions: MSR, `C:`, WinRE — **no ESP** | Steam is on `C:` (`C:\Program Files (x86)\Steam`, the only library) and stays. 89 GB free is thin but not a blocker |
| The other drive | The **1 TB** P41 (Windows disk 0, chipset controller) is **not empty**: a 1 GB ESP marked System, plus five Linux-filesystem partitions (31 + 244 + 585 + 39 + 31 GB) | **Two plan-breaking facts** — see [The ESP is on the wrong drive](#the-esp-is-on-the-wrong-drive). Those five partitions are an old Linux install — **disposable, no backup needed** (confirmed 2026-09-21) |
| Windows' RTC | `RealTimeIsUniversal = 1` — Windows already keeps the RTC in **UTC** | `time.hardwareClockInLocalTime = true` would *create* the clock fight it was meant to prevent. Removed from `disko.nix`; NixOS's UTC default is correct |
| Fast Startup | Was **on**; `powercfg /h off` run 2026-09-21, `powercfg /a` now reports hibernation not enabled and Fast Startup unavailable | Done. Re-check after feature updates — [Risk 6](#risks-ranked) |
| BitLocker | `manage-bde -status`: C: **Fully Decrypted**, no key protectors | Nothing to do; the guest will boot without a recovery prompt. Watch for Device Encryption re-enabling itself — [Risk 8](#risks-ranked) |
| Secure Boot | `Confirm-SecureBootUEFI` → **False** | Already off. systemd-boot installs without lanzaboote |
| SMBIOS | system/board manufacturer `Gigabyte Technology Co., Ltd.`, product `B650I AORUS ULTRA`, serials `Default string`, UUID `03560274-043C-0547-E806-FF0700080009` | The `<sysinfo>` block in the licensing section can be filled from this (confirm against `dmidecode` in Phase 0 — Windows byte-swaps the first three UUID fields on some firmware) |
| Network | Windows runs on **Wi-Fi** (MediaTek RZ616 / MT7922, MAC `F0:A6:54:14:9B:0D`); the Intel I225-V wired port (`74:56:3C:47:E8:FF`) is **disconnected** | **Decided: Wi-Fi for everything, for now.** See [Networking on Wi-Fi](#networking-on-wi-fi) |
| WSL | Switched onto this repo 2026-09-21: hostname `wsl`, applies `.#wsl` as locked, `/etc/nixos` stubs removed, SSH key comment `n8@wsl` | Done — nothing on the WSL side gates this plan any more |

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
| `hosts/wsl/home/wezterm-windows-config.nix` | copy-to-Windows activation: three-tier Windows-username detection, five error codes, ~900 lines of shell test | **Deleted** |
| `hosts/wsl/home/wezterm-windows.nix` | installs the Windows GUI from a nightly zip that upstream overwrites in place, so `sync-wezterm.sh` mirrors each pin to an immutable release on this repo | **Deleted** — and the mirroring step with it |
| `hosts/wsl/home/claude-in-chrome.nix` | `.bat` shim, HKCU registry write, extension-dir symlink across `/mnt/c` | **Deleted.** Native Chrome needs none of it |

The groundwork is already on `main`: the WSL-only WezTerm behavior was split out
of `modules/home/wezterm.nix` into `hosts/wsl/home/` (dfcebcd), because an
`isLinux` guard would have handed it to any second Linux host. So deleting the
WSL host deletes these modules outright — nothing shared has to be untangled
first.

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

# 7. OPTIONAL: USB port -> controller map. Only needed if Phase 7 ever falls
#    back to passing a whole USB controller, which must not be the printer's
#    (see Printer sharing). Cheap to record while the live USB is up.
lsusb -t
for b in /sys/bus/usb/devices/usb*; do
  printf '%s -> %s\n' "${b##*/}" "$(basename "$(readlink -f "$b/..")")"
done
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
- [ ] **Update the motherboard firmware** (F9d → latest for the board
      revision) before the Linux pass — [Firmware update](#firmware-update)
- [ ] **Give Windows its own ESP on the 2 TB drive** and prove it boots —
      *created 2026-09-21; the boot from it and the `reagentc` re-run remain* —
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
- [ ] **Windows Hello: decide the sign-in method.** Bare metal uses the fTPM
      and the guest a virtual TPM, so a TPM-backed PIN stops working on every
      crossing. Switch to password sign-in before the first guest boot, or
      accept re-creating the PIN each time —
      [Two TPMs, one install](#two-tpms-one-install)
- [x] **Secure Boot off** in firmware — *already off; turned back on in
      [Phase 2b](#phase-2b--restore-secure-boot)*. Do this *after*
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
<!-- libvirt refuses to define the domain unless this equals the sysinfo
     system uuid below ("UUID mismatch between <uuid> and <sysinfo>"), so the
     domain's own UUID is the host's too — and NixVirt's `uuid` attr with it. -->
<uuid>[host's system UUID]</uuid>
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

#### Two TPMs, one install

Activation does not hash the TPM, but Windows Hello does depend on it, and this
is the one crossing cost that BitLocker-off does not remove. Bare metal uses the
board's **fTPM**; the guest gets **swtpm**, a different TPM with different keys.
Everything Windows keeps *in* the TPM is therefore valid in one boot mode only:

- **Windows Hello PIN and biometrics.** The PIN is a TPM-protected key, not a
  password. After a crossing Windows reports *"Your PIN is no longer available
  due to a change to the security settings on this device"* and makes you
  create it again — and again on the way back.
- Passkeys and other WebAuthn credentials stored in Windows Hello, for the same
  reason.
- Microsoft account device keys may re-provision; harmless, but it is where an
  extra sign-in prompt comes from.

Three ways to live with it, in order of preference:

1. **Password sign-in.** Settings → Accounts → Sign-in options: remove the PIN
   and turn off *"only allow Windows Hello sign-in"*. The one setting that makes
   the crossing invisible. Games do not care.
2. **Re-create the PIN per crossing.** Works, costs thirty seconds each time,
   and is what happens by default if you do nothing.
3. **Pass the host's fTPM through instead of swtpm**, so the guest sees the
   *same* TPM as bare metal
   (`<tpm model='tpm-tis'><backend type='passthrough'><device path='/dev/tpm0'/></backend></tpm>`).
   Then Hello keys resolve in both modes. The host has no TPM while the guest
   runs, which this host does not need, and AMD fTPM passthrough is less
   travelled than swtpm — test it in [Phase 8](#phase-8--cutover-qa) only if
   option 1 turns out not to be acceptable. BitLocker stays off either way:
   its PCR-sealed key would still see two different boot chains.

The swtpm state (`/var/lib/libvirt/swtpm/<domain uuid>/`) and the guest's OVMF
variables (`/var/lib/libvirt/qemu/nvram/win_VARS.fd`) are the guest half of this
identity. Losing either is another "new hardware" event from inside the guest,
so they go on the unmanaged-state list in [Phase 9](#phase-9--retire-the-wsl-host)
and are never regenerated casually — which also means a NixVirt redefinition
must keep the domain's `uuid` fixed.

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
    inputs.disko.nixosModules.disko    # via `inputs`: the outputs arg list does not name disko
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
  secure-boot.nix             # lanzaboote (Phase 2b) — added after the install
  media.nix                   # Samba, btrfs scrub, restic (Media storage)
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

Also host-scoped, because the groups do not exist on WSL and a nonexistent
group is, at best, a warning on every switch there. The same file carries the
boot loader — NixOS defaults to GRUB, and without these two lines Phase 2's
`nixos-install` fails at evaluation asking for `boot.loader.grub.devices`:

```nix
# hosts/desk/default.nix
boot.loader.systemd-boot.enable = true;
boot.loader.efi.canTouchEfiVariables = true;   # writes the NVRAM entry Phase 2 reorders

users.users.n8.extraGroups = [ "libvirtd" "kvm" "input" "networkmanager" ];
```

- [ ] Add `desk` to the "Evaluate every host" step in
      `.github/workflows/update-flake-lock.yml`, next to `wsl` — the weekly
      lock bump gates only the hosts it is told about.

### Networking on Wi-Fi

Decided 2026-09-21: **all three — NixOS, bare-metal Windows, the guest — use
Wi-Fi** (MediaTek RZ616, an MT7922, driver `mt7921e`). The I225-V wired port
stays unplugged for now. What that pins down:

```nix
# hosts/desk/default.nix
hardware.enableRedistributableFirmware = true;   # MT7922 firmware blobs
networking.networkmanager.enable = true;         # nmcli/nmtui
```

- **The guest is NATed, not bridged.** A Wi-Fi client cannot put a second MAC
  on the air (802.11 does not allow bridging a station), so the guest sits on
  libvirt's `default` network (`virbr0`, 192.168.122.0/24) behind the host.
  Outbound works; nothing on the LAN can reach the guest directly. Fine for
  gaming; revisit by plugging in the cable if that ever matters.
- **The guest reaches Samba over `virbr0`**, not the LAN — so `virbr0` needs a
  firewall opening alongside the Wi-Fi interface. Covered in
  [Media storage](#step-1--srvmedia-as-a-network-share).
- **The guest's `<mac>` is the Wi-Fi MAC `f0:a6:54:14:9b:0d`**, for the
  activation hash. On the NATed `virbr0` segment it cannot collide with the
  host's own use of that MAC on the Wi-Fi network.
- **The Wi-Fi PSK is hand-provisioned state** (NetworkManager keeps it under
  `/etc/NetworkManager/system-connections/`). Add it to the README's unmanaged
  list in Phase 9.
- **Install over Wi-Fi.** The graphical NixOS live ISO has NetworkManager;
  connect with `nmtui` before running disko.

### Disk layout — one drive each

The clean split that makes everything else work:

| Drive | Owner | Contents | Touched by this plan? |
| --- | --- | --- | --- |
| **2 TB P41** ("fast" below) | Windows, entirely | MSR, `C:`, WinRE as they are today, **plus a new ESP** carved from `C:` — see below. All Windows games stay on `C:` | **Once**, before anything else: a 300 MB shrink of `C:` for a new ESP — done 2026-09-21. Then never again |
| **1 TB P41** ("bulk" below) | NixOS, entirely | ESP, `/`, `/srv/games`, `/srv/media` | Yes — disko formats the whole thing, **after** Windows stops booting from it |

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

What was run, 2026-09-21 (elevated, from the running Windows — NTFS shrinks
online). 300 MB rather than the 1 GB first proposed: Windows' own default ESP is
100–260 MB, and nothing else ever goes on this one.

```powershell
$c = Get-Partition -DriveLetter C
Resize-Partition -DriveLetter C -Size ($c.Size - 300MB)
$esp = New-Partition -DiskNumber $c.DiskNumber -Size 300MB `
         -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
Format-Volume -Partition $esp -FileSystem FAT32 -NewFileSystemLabel SYSTEM
$esp | Add-PartitionAccessPath -AccessPath S:
bcdboot C:\Windows /s S: /f UEFI       # writes bootmgfw.efi + a fresh BCD, adds an NVRAM entry
$esp | Remove-PartitionAccessPath -AccessPath S:
reagentc /disable; reagentc /enable    # re-run after the first boot from the new ESP — see below
```

Result: disk 1 is now MSR (16 MB), `C:`, **ESP (300 MB, partition 3)**, WinRE
(909 MB, partition 4). This plan first recorded the ESP as partition 4, on the
assumption that numbers follow creation order; after the reboot Windows reports
them in disk order, the ESP as 3 and WinRE as 4. Identify the ESP by its
`GptType` (`{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}`) or `IsSystem`, never by
number.

One consequence of the ESP sitting between `C:` and WinRE, for later rather than now: WinRE is no longer
adjacent to `C:`. When a servicing update needs a bigger recovery partition it
grows WinRE by shrinking the *neighbouring* OS partition, and the ESP is now in
the way — so such an update fails with a `0x80070643`-style error instead of
resizing. 909 MB is roomy today; if it ever bites, the fix is to disable WinRE,
delete the partition and recreate a larger one behind the ESP with `reagentc`.

Then reboot into the **new** entry from the firmware boot menu (the drive-2
"Windows Boot Manager"), confirm Windows starts and is still activated, and only
then treat the 1 TB drive's ESP as disposable. The shrink can fail if an
unmovable file sits at the end of `C:` — WinRE sits *after* `C:`, so this
usually succeeds; if it does not, `reagentc /disable` + retry, then re-enable.

This is the one place the plan touches Windows' drive after all, and it is
worth being exact about why it is acceptable: it is a 300 MB shrink with a
backstop — the old ESP stays bootable until the new one is proven, so there is
never a moment when nothing boots.

**WinRE registration has to be redone after the first boot from the new ESP.**
`reagentc` writes to the BCD of the ESP Windows *booted from*, and the run above
happened while that was still the old one. Once `Get-Partition | ? IsSystem`
reports disk 1 partition 3, `reagentc /disable; reagentc /enable` registers
WinRE in the new BCD.

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
          size = "200G";                  # decided 2026-09-21; the rest is media
          content = { type = "filesystem"; format = "ext4"; mountpoint = "/"; };
        };

        media = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-L" "media" ];
            subvolumes = {
              "/media" = {
                mountpoint = "/srv/media";
                mountOptions = [ "noatime" ];
              };
              # The HOST-side Steam library (native + Proton titles). Not on
              # the 200 GB root — see "Where the Steam library lives". Its own
              # subvolume so snapshots and the restic paths stay media-only.
              # No nodatacow: btrfs mount options are filesystem-wide, so it
              # would silently switch off checksums for /srv/media too, and
              # game files are write-once anyway.
              "/games" = {
                mountpoint = "/srv/games";
                mountOptions = [ "noatime" ];
              };
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

**Decided: on the 2 TB drive, with Windows, where it is today**
(`C:\Program Files (x86)\Steam`). Windows owns that whole disk and the guest gets
the whole controller, so the library comes along in both boot modes with no
configuration whatsoever. The 2 TB drive is Windows' and nothing else's; the
1 TB drive carries no Windows data at all.

The one number to watch is `C:`'s free space — 89 GB at Phase 0. When it runs
short, the answer is uninstalling games or a bigger/second Windows drive, not a
games partition on the 1 TB drive: that would put a second disk in the guest
by block passthrough next to the VFIO one, and take space from `/srv/media`.

Note what is *not* an option: putting the library on `/srv/media` and reaching
it over SMB. Loading times over a network share are not worth discussing.

**The host has a library of its own, and it is not on `C:`.** `gaming.nix`
installs Steam on NixOS for the native and Proton titles, and Steam's default
library is `~/.local/share/Steam` — on the 200 GB root, next to the Nix store
and Docker. That root was sized before the host-side library was counted. So
`disko.nix` gives it a `/srv/games` subvolume on the btrfs volume instead: add
it as a library folder in Steam (Settings → Storage) on first run, and leave
the default one empty. Consequence for the sizing residual: **the ~730 GB is
shared between media and host-side games**, so the media total measured before
Phase 2 must leave room for the Proton titles you intend to keep installed.

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

**Once this drive holds media, disko's destroy mode is a destructive command.**
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
# the wrong disk. (`--mode disko` is the deprecated spelling of
# destroy,format,mount; current disko also demands the explicit wipe flag.)
nix --extra-experimental-features 'nix-command flakes' \
  run github:nix-community/disko/latest -- \
  --mode destroy,format,mount --yes-wipe-all-disks \
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

## Phase 2b — Restore Secure Boot

Added 2026-09-21. Phases 0–2 run with Secure Boot **off**, because a fresh
NixOS install boots unsigned systemd-boot. This phase turns it back **on**,
permanently, for both operating systems. Do it once NixOS has booted reliably
for a few days — and before the VFIO work, so the passthrough phases are
debugged on the final boot chain rather than changing it underneath them.

### Why bother

- **Kernel anti-cheat.** The whole reason bare-metal Windows is kept is games
  whose anti-cheat will not run in a VM — and a growing number of exactly those
  titles also refuse to start without Secure Boot (Battlefield 6, recent Call
  of Duty). With Secure Boot off, the boot mode that exists for anti-cheat
  cannot run it. The game-list residual says whether any current title is
  affected; the direction of travel says one will be.
- **Bootkits.** Signature checking of everything the firmware loads — the
  protection against BlackLotus-class malware it was designed for.

**Cost: none at runtime.** Signatures are checked once, at boot, in
milliseconds; nothing changes afterwards on the host, in Windows or in the
guest. The Windows feature that *does* cost game performance, Memory Integrity
(VBS/HVCI), merely *requires* Secure Boot — it is a separate switch in Windows
Security, and this phase does not turn it on.

What it does cost is operational: a signing key this repo does not manage
(`/var/lib/sbctl`), one more community-maintained flake input, and a recovery
step after firmware updates (below).

**The guest is unaffected either way.** It gets Secure Boot from OVMF
(`OVMFFull`, already in [Phase 4](#phase-4--vfio-and-the-libvirt-host)) and
swtpm, independent of the host's firmware setting.

### Configure lanzaboote

lanzaboote replaces systemd-boot with a signed boot stub. Pin a release tag —
**v1.1.0** (2026-06-22) is current as of writing.

```nix
# flake.nix inputs
lanzaboote = {
  url = "github:nix-community/lanzaboote/v1.1.0";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

```nix
# hosts/desk/secure-boot.nix — imported from hosts/desk/default.nix,
# with inputs.lanzaboote.nixosModules.lanzaboote added to the desk modules.
{ pkgs, lib, ... }:
{
  environment.systemPackages = [ pkgs.sbctl ];

  # lanzaboote replaces the systemd-boot module; it still installs
  # systemd-boot's menu, now signed.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
  };
}
```

Not in Phase 2's install: `pkiBundle` does not exist on the live USB, so the
install stays plain systemd-boot and this lands as an ordinary rebuild after.

### Procedure

1. **Keys**: `sudo sbctl create-keys` → `/var/lib/sbctl`, root-only.
2. **Rebuild** with `secure-boot.nix`; then `sudo sbctl verify` — everything in
   `/boot/EFI` signed except the `kernel-*` files, which is expected.
3. **Firmware into Setup Mode.** On this Gigabyte/AMI board: *Boot → Secure
   Boot → Secure Boot Mode: Custom → Key Management → Reset To Setup Mode*
   (menu names vary by BIOS version). Setup Mode means "no Platform Key", which
   is what lets the OS enroll keys. **Do not** pick an option that deletes all
   variables including **dbx** — the revocation list — if a gentler one is
   offered.
4. **Enroll, keeping Microsoft's keys:**

   ```sh
   sudo sbctl enroll-keys --microsoft
   ```

   `--microsoft` is **not optional on this machine**, for two reasons: bare-metal
   Windows' `bootmgfw.efi` is signed by Microsoft, and so is the **RX 6600 XT's
   option ROM** (its GOP driver). Enroll only your own key and Windows stops
   booting *and* the dGPU's firmware is refused — a black screen at POST with
   no obvious cause.
5. **Secure Boot on**, save, reboot into NixOS.

### Verify

- [ ] `bootctl status` → `Secure Boot: enabled (user)`
- [ ] `sbctl status` → installed, Secure Boot enabled, vendor keys: microsoft
- [ ] dbx is not empty: `ls -l /sys/firmware/efi/efivars/dbx-*` shows a
      non-trivial size
- [ ] **Bare-metal Windows** boots from the F12 menu; `msinfo32` → *Secure
      Boot State: On*; still activated
- [ ] The option-ROM check: with Initial Display Output temporarily set to the
      PCIe slot, the dGPU shows the firmware splash at POST; then set it back
      to IGD ([Firmware update](#firmware-update) says why it must stay there)
- [ ] A game that requires Secure Boot starts on bare metal, if the library
      has one

### Recovery, and the firmware-update trap

A BIOS update or CMOS clear can reset the key databases to Gigabyte's factory
defaults. Those contain Microsoft's keys but **not yours**: Windows still boots,
NixOS is refused. Not a failure of anything — re-run steps 3–5 from a NixOS
boot with Secure Boot temporarily off.

That requires the key, which lives only on the 1 TB drive. **Back up
`/var/lib/sbctl` off this machine** (it is small; somewhere encrypted), or a
dead 1 TB drive also means generating and enrolling new keys — recoverable,
but only because the old ones can simply be replaced. Add it to the README's
unmanaged-state list in Phase 9.

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

**Google Photos is not a mount and gets no unit here.** It is a separate store
from Drive — the folder sync between them was severed in 2019 — and the only API
into it degrades what it serves, so it is handled once, as an export, under
[Media storage Step 3](#step-3--bring-the-media-in). Nothing in Phase 3 depends
on it.

### WezTerm

The WSL-only split is already done on `main` (dfcebcd): `desk` imports
`modules/home/wezterm.nix` and not `hosts/wsl/home/wezterm-windows-config.nix`,
so it gets a plain GUI app with no further module work.

- `default_prog = { 'wsl.exe', ... }`, `default_gui_startup_args` and
  `home.activation.copyWeztermToWindows` — already scoped to the `wsl` host;
  they never reach `desk`, and go when `hosts/wsl/` does
  ([Phase 9](#phase-9--retire-the-wsl-host)).
- `wezterm-mux-server` — **keep**. It is still how the Mac gets a persistent
  remote session into this box, and its `stdenv.hostPlatform.isLinux` guard is
  now correct by design.
- The Tailscale `ssh_domains` auto-discovery — **keep**, unchanged. It picks up
  `desk` for free.
- The Windows branches of the shared Lua (`wsl.exe` tailscale invocation,
  `//wsl$/NixOS/...` identity-file paths) — **delete** in Phase 9, once no
  Windows WezTerm reads this config.

`tests/wezterm.test.nix` already evaluates the shared module alone (the native
NixOS case) and with the WSL overlay. `tests/wezterm_test.sh` exercises only the
WSL copy-to-Windows activation, so it goes with `hosts/wsl/` — but read it first
for anything it covers that is not WSL-specific. **Do the test deletion in its
own commit**, separate from the module change, so `git log` shows the coverage
loss was deliberate.

### Claude in Chrome

`hosts/wsl/home/claude-in-chrome.nix` exists purely to bridge Chrome-on-Windows
to `claude`-in-WSL through a `.bat` shim and an HKCU registry write. On native
NixOS, install Chrome and let Claude Code register its own native-messaging
host the normal way. **Delete the module**; do not port it.

### WezTerm's Windows GUI pin

`hosts/wsl/home/wezterm-windows.nix` and the Windows half of
`modules/home/wezterm-pin.nix` go away with the WSL host. So does the mirroring
step `main` added for them (f89ef8a): upstream overwrites its Windows nightly
zip in place, so `scripts/sync-wezterm.sh` uploads each pinned zip to an
immutable `wezterm-<version>` release on this repo. With no Windows GUI to
install, that step and those releases have no consumer.

Keep the lesson, though. It still applies to the Windows artifacts this plan
does pin: **`pkgs.virtio-win`**, hash-pinned in nixpkgs, for the NIC and balloon
drivers ([Phase 4](#phase-4--vfio-and-the-libvirt-host)), and the **Looking
Glass host application**, which must be the same release as
`pkgs.looking-glass-client` ([Phase 7](#phase-7--display-input-audio)). Pin
immutable sources; never a rolling URL.

And it is why the Windows profile in [Phase 6](#phase-6--managing-the-one-windows-install)
does **not** install WezTerm from winget. A winget WezTerm is an unpinned
stable build; the only thing it could usefully connect to is `desk`'s mux
server, a pinned nightly, and a version mismatch is exactly the handshake
failure the mirror existed to prevent. There is no need for a mux client on
Windows any more — the NixOS desktop with its own WezTerm is the machine you
are sitting at, and Windows runs games. If a Windows WezTerm is ever wanted
again, it comes from the `wezterm-<version>` mirror release by hash, rendered
into `Apply.ps1` from `wezterm-pin.nix`, never from winget.

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
| **bulk** | capacity | NixOS `/`, `/srv/games` (the host-side Steam library) and `/srv/media`. No Windows data |

This section is about the bulk drive's media volume. Note that `/` is now its
neighbour, which raises the stakes on the disko destroy-mode warning below:
the destructive mode takes the operating system with the media now, not just
the media.

Three steps, in this order. The share is useful on day one; the backup is what
makes the share safe to depend on; and only then does the media come in —
because it is irreplaceable, it arrives on a volume whose backup already works.

**Where the media is today** (2026-09-21): spread across five places —
**Google Drive**, **Google Photos**, **the MacBook's internal storage**, a **GCS
bucket** it has to be exported from, and **Flickr**. Drive and Photos are one
account and one Google One quota but **two separate stores** — Google severed the
Drive↔Photos folder sync in July 2019, so nothing in Photos is reachable through
the Drive remote and it needs its own ingest path. None of them is this machine,
which is good news: every source is itself a copy that survives the migration
untouched.

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
        # Reachability is scoped by `hosts allow` plus the per-interface
        # firewall rules below — NOT by `bind interfaces only`. smbd binds the
        # interfaces that exist when it starts and never picks up later ones,
        # and tailscale0 and virbr0 both routinely appear after it: the share
        # would silently be unreachable from the tailnet and the guest until
        # the next restart.
        "hosts allow" = "127.0.0.1 192.168.0.0/16 100.64.0.0/10";  # LAN + virbr0 + tailnet CGNAT
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

  # Discovery: WS-Discovery for the Windows guest. mDNS for Finder is already
  # on — modules/nixos/default.nix enables avahi with publishing for every
  # Linux host.
  services.samba-wsdd.enable = true;

  # tailscale0 is a trusted interface in modules/nixos/tailscale.nix, so the
  # tailnet needs no rule here. Wi-Fi and the guest's NAT bridge do.
  networking.firewall.interfaces."<FILL_ME_WLAN_IF>" = {
    allowedTCPPorts = [ 445 5357 ];
    allowedUDPPorts = [ 3702 ];
  };
  # The Windows guest, NATed behind virbr0.
  networking.firewall.interfaces.virbr0 = {
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
| **Hetzner BX11** (1 TB) | **€3.20/mo** ≈ $42/yr | same as below | same as below |
| Hetzner BX21 (5 TB) | €10.90/mo ≈ $142/yr | drive death, `rm -rf`, fire, theft, ransomware | Hetzner itself — RAID on one array in one building, [not mirrored to other servers](https://docs.hetzner.com/storage/storage-box/) |
| Hetzner BX31 (10 TB) | €20.80/mo | same | same |
| A local HDD (~6 TB) | ~$130 once | drive death **only** | anything that takes the whole machine, or the room it sits in |

Pick by whether the library is replaceable. Re-rippable or re-downloadable media
→ the HDD is sufficient and roughly $580 cheaper over five years. Irreplaceable
media → Hetzner, because the failure modes it adds coverage for (theft,
ransomware, an `rm -rf` nobody notices for a year) are each more likely than the
SSD death that prompted this.

**Decided 2026-09-21: the media is irreplaceable, so Hetzner — a BX11 (1 TB,
€3.20/mo).** The media subvolume can grow to ~730 GB (1 TB minus the 200 GB
root, less whatever `/srv/games` takes — games are not backed up), so 1 TB
holds a full copy plus snapshot history with headroom; Storage Boxes
upgrade in place to BX21 when it stops fitting. Watch `restic stats` — with
append-only and no automatic pruning, the repository only grows.

Irreplaceable also changes the order of operations: **the backup exists and has
passed a restore test before the original copy of the media is retired.** Until
then the SSD is not the only copy, and must not become it.

Sized to the **media subvolume** rather than the whole bulk drive. `/` is not in scope — it is declarative and rebuilt from this repo.
Adding a local HDD later as a fast-restore tier is additive — same restic
invocation, second repository — not a migration.

#### The unit

```nix
# hosts/desk/media.nix, continued
{
  services.restic.backups.media = {
    initialize = true;
    paths = [ "/srv/media" ];
    repository = "sftp:u<FILL_ME>@u<FILL_ME>.your-storagebox.de:restic/media";  # relative to the box's home
    passwordFile = "/etc/restic/media.password";        # 0600, hand-provisioned
    extraOptions = [
      "sftp.command='ssh -p 23 -i /etc/restic/id_ed25519 u<FILL_ME>@u<FILL_ME>.your-storagebox.de -s sftp'"
    ];
    extraBackupArgs = [ "--exclude-caches" "--one-file-system" ];
    pruneOpts = [ "--keep-daily 7" "--keep-weekly 5" "--keep-monthly 12" ];
    runCheck = true;
    checkOpts = [ "--read-data-subset=2%" ];            # samples, not a full download — ~15 GB/day at 730 GB, over Wi-Fi; 1% if the uplink minds
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "2h";
      Persistent = true;                                # catch up after downtime
    };
  };

  # A backup whose failures are silent is not a backup. This repo has no
  # alerting yet; until it does, at minimum make the failure visible.
  systemd.services.restic-backups-media.unitConfig.OnFailure = "<FILL_ME_notify_unit>";

  # The unit runs as root with no known_hosts, so the first ssh to the box
  # would fail host-key verification. Hetzner publishes the fingerprints; the
  # non-default port makes the [host]:port form mandatory. This IS declarative
  # and belongs in the repo, unlike the private key.
  programs.ssh.knownHosts.storagebox = {
    hostNames = [ "[u<FILL_ME>.your-storagebox.de]:23" ];
    publicKey = "ssh-ed25519 <FILL_ME_from_docs.hetzner.com>";
  };
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

#### Required: make the repository append-only

Optional for replaceable media; **required here**, because the media is not.

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

### Step 3 — bring the media in

**`rclone` for Drive and GCS**, because it speaks both and it is already in the
plan for the Drive mount (Phase 3). The MacBook is `rsync`. **Two sources are
exceptions, for opposite reasons.** Flickr has no rclone backend at all, so it
comes in through Flickr's own account export. Google Photos *has* one — and it
is the wrong tool anyway, because the API it drives is lossy: see below.

| Source | How | Notes |
| --- | --- | --- |
| Google Drive | `rclone copy gdrive:<path> /srv/media/<dest> --progress` | Use the Drive remote configured for Phase 3's mount, not the mount itself — `copy` against the API is faster and resumable. Google-native Docs/Sheets are not media; exclude them |
| Google Photos | **Google Takeout, not `rclone`** ([takeout.google.com](https://takeout.google.com)) → deselect everything, select *Google Photos*, delivery **to Google Drive**, `.tgz`, 50 GB parts. Then pull the parts with the Drive remote already configured above and unpack into `/srv/media/google-photos/` | Do **not** use `rclone`'s `google photos` backend for the archival copy. It can only see the library through the Photos Library API, which **strips GPS EXIF from every download** and re-encodes some originals — the loss is silent and it is not recoverable later. Takeout is the only route that yields the true originals. What it costs: each photo arrives with a **sidecar `.json`** holding the timestamp, GPS, description and album membership, and the metadata has to be merged back into the files (`exiftool`, or `google-photos-takeout-helper`) before the sidecars are worth less than the originals |
| GCS bucket | `rclone copy gcs:<bucket>/<path> /srv/media/<dest>` | Needs a `gcs` remote (service-account JSON or `gcloud` user creds — hand-provisioned, not in git). Internet egress is billed per GB, plus retrieval fees if the bucket is Coldline/Archive — check the class first. A one-off pull of a few hundred GB is tens of dollars, not a reason to hesitate |
| MacBook | From the Mac: `rsync -avh --progress ~/<path>/ n8@desk:/srv/media/<dest>/` over Tailscale | Or drag into the SMB share from Finder. `rsync` is resumable and prints what it skipped |
| Flickr | Account settings → *Your Flickr data* → request the export; download the zip parts when Flickr emails; unzip into `/srv/media/flickr/` | Contains the **originals** plus separate JSON for titles, descriptions, albums and tags — keep the JSON alongside, it is the only copy of that metadata outside Flickr. Fallback if the export is unusable: `gallery-dl` against the account with an API key |

Then, per source, **verify rather than assume**:

```sh
rclone check gdrive:<path>        /srv/media/<dest> --one-way   # size + hash
rclone check gcs:<bucket>/<path>  /srv/media/<dest> --one-way
# Mac side: rerun the same rsync with --dry-run --checksum; it should list nothing.
# Google Photos: no hashes, and `rclone check` against the Photos remote is
# worse than useless — it compares Takeout's originals to the API's degraded
# copies and reports every file as differing. Count instead, against the item
# count read off photos.google.com BEFORE the export was requested, and confirm
# every archive part unpacks (`tar -tzf` each one; a silently missing part is a
# silently missing slice of the library).
# Flickr: no hashes to compare against. Count instead — photo + video files
# extracted must equal the item count on the Flickr profile, and every zip part
# must unzip without error (`unzip -t`).
```

Expect overlap between the sources — Drive and Photos especially, since
phones have historically backed up to both. Land each source in its own
directory first, verify, *then* de-duplicate (`rclone dedupe`, or `fdupes -r` across the
directories) — merging during the copy makes the verification meaningless.

**Retiring a source is a separate decision, and it comes last.** Only after the
first restic backup of the ingested media has passed the restore proofs above
is `/srv/media` + Hetzner a trustworthy pair. Until then Drive, Photos, GCS,
the MacBook and Flickr are the backup. Google Photos earns extra caution here:
deleting from it is the one retirement that is **not** reversible on a whim,
because the Takeout copy is the only remaining original once the library is
emptied and the trash ages out at 60 days.

#### Three Google Takeout traps

Worth knowing before the export lands rather than during the ingest, because
two of them corrupt the verification and one of them corrupts the archive.

1. **The sidecars do not reliably match their media by name.** Takeout truncates
   the JSON basename, and disambiguates duplicates by appending a counter that
   lands in a different position on the media file than on its sidecar
   (`IMG_1234(1).jpg` beside `IMG_1234.jpg(1).json`). A naive pair-by-stem
   script drops the metadata for exactly those files and says nothing. Use a
   tool that knows the rules — `google-photos-takeout-helper` — and check its
   unmatched-file count, which is the number that matters.
2. **The file count overshoots the item count.** An edited photo ships as both
   the original and a `-edited` copy; a Live Photo ships as a still plus a
   `.mov`. Count distinct originals — excluding `*-edited.*` and the `.json`
   sidecars — or the verification above fails against a correct archive.
3. **Albums are directories of duplicates.** Each album is written out as its
   own folder containing *copies* of media that also live under
   `Photos from <year>/`, so the archive is meaningfully larger on disk than the
   library is. De-duplicate only after album membership has been merged out of
   the JSON: until then the duplicate path is the only record that the album
   existed, and `fdupes` will delete it.

The order this forces: unpack → merge sidecars with
`google-photos-takeout-helper` → verify the count → *then* de-duplicate, both
within Photos and against Drive. Leave room for it: the archives and their
unpacked contents coexist until the merge is verified, so the ingest needs
roughly **twice the Photos library size free** at its peak, on a volume that is
also holding the other four sources un-de-duplicated.

#### Checklist

- [ ] Bulk drive partitioned as btrfs by disko (§1), with `autoScrub` enabled
- [ ] `hosts/desk/media.nix`, imported from `hosts/desk/default.nix`
- [ ] `smbpasswd -a n8`; mount from the Mac over both LAN and tailnet
- [ ] Order a Storage Box BX11 (1 TB); generate a dedicated
      ed25519 key for it
- [ ] `/etc/restic/media.password` and `/etc/restic/id_ed25519`, both 0600,
      added to the README's unmanaged-state list
- [ ] Append-only forced command, plus the offline prune key recorded somewhere
      that is not this machine. Prove the forced command from a shell first —
      `restic -r rclone: -o rclone.program='ssh -p 23 …' snapshots` from `desk`,
      then a `restic forget` that must **fail** — before wiring the unit
- [ ] The four restore proofs above — run once on a small test set before
      ingest, and again after
- [ ] Measure the total size of the five sources **before Phase 2**; it must
      fit in ~730 GB after de-duplication. Budget Google Photos at more than
      its library size — Takeout's album folders are duplicates of media that
      also lives under `Photos from <year>/`
- [ ] Record the Google Photos item count **before** requesting Takeout — it is
      the only verification the export admits, and it is unreadable afterwards
      if the library has moved on
- [ ] Request the Flickr data export early — it is prepared asynchronously
- [ ] Request the Google Takeout export early, **delivered to Google Drive** —
      also asynchronous, and its download links expire after 7 days. Check the
      Google One quota first: the archive lands in Drive against the same
      quota Photos already fills, so it needs free space equal to the library.
      No headroom → download-link delivery, pulled inside the window, or a
      month of extra storage
- [ ] Ingest from Drive, Photos, GCS, the MacBook and Flickr into separate
      directories; `rclone check` / `rsync --dry-run --checksum` / item counts
      each; merge the Takeout sidecars back into the media; then de-duplicate
- [ ] First full backup, restore proof, *then* decide the fate of the sources

---

## Printer sharing

Added 2026-09-23. **The Brother printer moves from Windows to NixOS, and NixOS
shares it on the network.** Like [Media storage](#media-storage) it is off the
phase sequence: it needs Phases 1–2 and nothing else, and nothing depends on it.

### What it is — measured 2026-09-23

| Item | Measured (bare-metal Windows) | Consequence |
| --- | --- | --- |
| Model | **Brother HL-L2305** (USB-only mono laser), USB `04f9:0075`, serial `U66480F3N341782` | Stays plugged into the desktop; the desktop becomes the print server |
| USB interface | One interface, class `07/01/02` (bidirectional printer). **No `07/01/04`** | No IPP-over-USB, so `ipp-usb` and driverless printing are out on the host side — it needs a real CUPS driver |
| Windows queue | `Brother HL-L2305 series`, inbox *Brother Laser Type1 Class Driver*, port `USB001`, **not shared** | Nothing to undo: Windows was never the print server. The local queue keeps working bare metal |
| Host controller | AMD `1022:15b7`, Windows PCI bus 18 fn 4 — one of the CPU's USB controllers | Only matters if Phase 7's controller-passthrough fallback is ever used — [below](#keep-the-printer-on-the-host) |
| Region | en-US | `PageSize=Letter` |

**Driver: `brlaser`.** The nixpkgs package tracks the maintained
`Owl-Maintain/brlaser` fork (6.2.8), which lists `HL-L2305 series` with
`PCFileName "brl2305.ppd"` — the upstream `pdewacht/brlaser` list stops at the
HL-L2300D. Brother's own `.deb` driver would need patchelf wrapping and a
32-bit userland; `brlaser` is open source and needs neither.

### Protocol: IPP from CUPS, advertised over mDNS

Not Samba printer sharing. SMB printing makes every client supply a driver; a
shared CUPS queue renders on the host and advertises itself as an IPP
Everywhere / AirPrint printer (`_ipp._tcp` with the `_universal` subtype), which
**macOS adds with no driver** and **Windows 11 adds with its inbox IPP class
driver**. The printer itself speaks neither — the host translates, which is the
point of having a print server.

```nix
# hosts/desk/printing.nix
{ pkgs, ... }:
{
  services.printing = {
    enable = true;
    drivers = [ pkgs.brlaser ];
    # Listen beyond localhost; scope with allowFrom + the per-interface
    # firewall, the same split as Samba's `hosts allow` in media.nix.
    listenAddresses = [ "*:631" ];
    allowFrom = [ "localhost" "192.168.0.0/16" "100.64.0.0/10" ];  # LAN + virbr0 + tailnet
    browsing = true;          # publish shared queues via avahi (already on — modules/nixos/default.nix)
    defaultShared = true;
    # CUPS rejects requests whose Host: header is not one of its own names
    # ("Request from ... using invalid Host: field"). Clients arrive as
    # desk.local, desk.<tailnet>.ts.net and 192.168.122.1 — accept them all;
    # allowFrom still decides who gets in.
    extraConf = ''
      ServerAlias *
    '';
  };

  # Declarative queue: no hand-run lpadmin, nothing for Phase 9's
  # unmanaged-state list. The URI is keyed on the serial, so it survives the
  # printer moving to another port.
  hardware.printers = {
    ensureDefaultPrinter = "brother";
    ensurePrinters = [{
      name = "brother";
      description = "Brother HL-L2305";
      location = "desk";
      deviceUri = "usb://Brother/HL-L2305%20series?serial=U66480F3N341782";  # confirm with `lpinfo -v`
      model = "drv:///brlaser.drv/brl2305.ppd";
      ppdOptions.PageSize = "Letter";
    }];
  };

  # 631 on the same two interfaces as Samba. tailscale0 is already trusted.
  # mDNS (5353/udp) is opened by services.avahi's own openFirewall default.
  networking.firewall.interfaces."<FILL_ME_WLAN_IF>".allowedTCPPorts = [ 631 ];
  networking.firewall.interfaces.virbr0.allowedTCPPorts = [ 631 ];
}
```

Not `services.printing.openFirewall`: it opens 631 on every interface, and the
Samba block already set the precedent of scoping by interface.

**The tailnet gets IPP, not discovery.** mDNS does not cross Tailscale, so the
MacBook adds the tailnet queue once, by address —
`ipp://desk.<tailnet>.ts.net:631/printers/brother`, with *AirPrint* as the
driver — while on the LAN it finds the printer by itself. It is the same queue
either way, and the paper still comes out of a printer in the room you left.

### Who prints how, in each boot mode

This is the part the one-Windows design makes interesting:

| State | Who owns the USB printer | Network clients (Mac, phones) | Windows |
| --- | --- | --- | --- |
| NixOS, no guest | NixOS | Print via CUPS | — |
| NixOS + guest | **NixOS** — the printer is *not* passed through | Print via CUPS | The guest prints to CUPS over `virbr0`, like any client |
| Bare-metal Windows | Windows (NixOS isn't running) | **No printer** | Prints locally over USB, as it does today |

Two consequences, both accepted:

1. **Bare metal takes the printer off the network.** Nothing hosts the share
   while NixOS is down. Making bare-metal Windows share it too was considered
   and rejected: Windows' sharing is SMB printing, which advertises no AirPrint
   record, so the Mac would need a second queue that works only in the boot
   mode used least. Bare metal is the anti-cheat exception, not the daily
   state; for those hours the Mac waits.
2. **The one Windows install has two queues for the same printer.** The local
   USB queue (live bare metal, offline in the guest — the device isn't there)
   and an IPP queue to the host (live in the guest, dead bare metal — the host
   isn't there). Neither is wrong; each is the right queue in exactly one boot
   mode. Two settings keep that from being confusing:
   - The IPP queue is declared in the Windows profile
     ([Phase 6](#phase-6--managing-the-one-windows-install)), not added by
     hand, at the **`virbr0` address** rather than `desk.local` — the guest's
     path to the host that depends neither on the Wi-Fi lease nor on mDNS
     crossing NAT:
     `Add-Printer -Name "Brother (desk)" -IppURL "http://192.168.122.1:631/printers/brother"`,
     rendered into `Apply.ps1` behind a `Get-Printer` guard so reruns are
     no-ops.
   - **"Let Windows manage my default printer" stays on** (the Windows
     default). It remembers the last-used printer per network, so each boot
     mode settles on its own live queue without a rule for it.

   The local queue is not in the profile: Windows re-creates it by PnP whenever
   the device appears, with the inbox driver, so there is nothing to declare.

### Keep the printer on the host

[Phase 7](#phase-7--display-input-audio) gives the guest USB devices one at a
time, so the printer stays with the host by construction: **never redirect
`04f9:0075`**, by `<hostdev type='usb'>` or by SPICE. Handing it to the guest
yanks it out from under CUPS, and every Mac job queues silently until the guest
stops.

The one way to lose it by accident is Phase 7's fallback of passing a whole
USB controller, which takes every port on it. If that fallback is ever used,
it must not be the printer's controller — `1022:15b7` today, of four
(`15b6`, `15b7`, `15b8` on the CPU; `43f7` on the chipset). Phase 0's optional
port map (step 7) says which port is which; otherwise move the printer.

### Checklist

- [ ] After Phase 2: `lpinfo -v` shows the `usb://Brother/HL-L2305%20series?serial=…`
      URI exactly as in `printing.nix`; fix the string if the backend reports
      it differently
- [ ] `lpstat -t` → `brother` enabled, accepting, default; `lp -d brother /etc/os-release` prints
- [ ] From the Mac on the LAN: *desk*'s Brother appears under **Add Printer**
      with *AirPrint* as the driver, and prints
- [ ] From the Mac over Tailscale, off the LAN: the `ipp://desk.<tailnet>.ts.net`
      queue prints
- [ ] From the guest: `Brother (desk)` prints
- [ ] Bare metal: the local USB queue prints
- [ ] Guest up: `lsusb` on the host **still** lists `04f9:0075`, and a Mac
      job prints while the guest runs

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
    # No `amd_iommu=on`: it is not a value the driver knows, and AMD-Vi is on
    # whenever the firmware enables it (Phase 0's dmesg check proves that).
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

    # What libvirt-guests does to a running `win` when the HOST shuts down.
    # The NixOS default is "suspend" = `virsh managedsave`, which libvirt
    # refuses for a domain with VFIO devices — the save fails, and systemd
    # then kills QEMU: a power cut to the real Windows disk on every host
    # reboot. "shutdown" sends ACPI power-off and waits.
    onShutdown = "shutdown";
    shutdownTimeout = 600;                    # seconds; Windows Update can be slow to go
    # And on the next NixOS boot, do NOT relaunch whatever was running at the
    # last shutdown (the default "start" would grab the dGPU and pin cores
    # before you have logged in).
    onBoot = "ignore";
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

**And not with `new_id` either.** Writing `1c5c 1959` to vfio-pci's `new_id`
is *also* an ID match: the kernel immediately probes every unbound device with
that ID, and at this point in the initrd both controllers are unbound — the
`nvme` module comes from `availableKernelModules` and is loaded by udev, which
runs *after* `preDeviceCommands`. So a `new_id` line would take the 1 TB drive
too, and the machine would stop booting. `driver_override` is per-device: it
tells the kernel that this one slot may bind only to vfio-pci, and leaves the
other controller for `nvme` when udev gets to it.

```nix
# Bind one specific slot, not every device with that ID. vfio_pci is already
# loaded (boot.initrd.kernelModules above), so a probe is all it takes.
boot.initrd.preDeviceCommands = ''
  echo vfio-pci > /sys/bus/pci/devices/0000:<FAST_NVME_ADDR>/driver_override
  echo 0000:<FAST_NVME_ADDR> > /sys/bus/pci/drivers_probe
'';
```

`preDeviceCommands` is a hook of the *scripted* initrd, which is still the
default. If `boot.initrd.systemd.enable` is ever turned on, this becomes a udev
rule in the initrd that sets `driver_override` for that address and triggers a
probe — the principle is unchanged.

**Verify before building a VM:** after the switch and reboot,

- `lspci -nnk -d <VEND:DEV>` must show `Kernel driver in use: vfio-pci` for the
  dGPU. If it still shows `amdgpu` or `nvidia`, the binding lost the race —
  that is the symptom of `vfio_pci` being in `boot.kernelModules` instead of
  `boot.initrd.kernelModules`. If `dmesg` shows `vfio-pci ... BAR 0: can't
  reserve`, the firmware POSTed on the dGPU and simpledrm owns its framebuffer:
  set Initial Display Output to IGD ([Firmware update](#firmware-update)).
- The same for the NVMe controller, **and** `lsblk` must not list Windows' disk
  at all. If it does, the host still owns it — stop and fix the binding before
  starting a guest, because both touching that filesystem is the one
  unrecoverable mistake available here.

#### Handing the disk to the guest

With the controller bound to `vfio-pci`, the guest gets it as a plain hostdev —
the same mechanism as the GPU, no storage driver involved:

```xml
<!-- managed='no': the controller is already on vfio-pci from the initrd, and
     libvirt must never hand it back. With managed='yes' libvirt tracks whether
     *it* bound the device and reprobes it to the host driver on shutdown when
     it thinks it did — after a libvirtd restart mid-run that bookkeeping is
     lost, and C: would appear in lsblk the moment the guest stops. -->
<hostdev mode='subsystem' type='pci' managed='no'>
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
  nrHugepages = "/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages";
  governors = "/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor";
  savedGovernor = "/run/win-perf.governor";
in
{
  virtualisation.libvirtd.hooks.qemu."10-win-perf" =
    pkgs.writeShellScript "win-perf" ''
      set -u
      PATH=${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.coreutils ]}
      [ "$1" = "win" ] || exit 0

      case "$2/''${3:-}" in
        prepare/begin)
          # Setup may fail loudly: a non-zero exit here stops the guest from
          # starting, which beats starting it half-tuned.
          set -e
          # Fence every host task off the guest's cores. --runtime = not persisted.
          for s in system.slice user.slice init.scope; do
            systemctl set-property --runtime -- "$s" AllowedCPUs=${hostCpus}
          done
          systemctl stop irqbalance.service || true
          # Save the governor and set performance via sysfs. Do NOT assume the
          # name to restore: on this CPU amd-pstate runs in EPP mode, whose
          # only governors are performance and powersave — `schedutil` does
          # not exist there, and cpupower is not needed at all.
          cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > ${savedGovernor}
          echo performance | tee ${governors} > /dev/null
          # 2 MiB pages allocate at runtime but not from fragmented memory;
          # compact first, then verify — a short allocation makes QEMU fail
          # with an unhelpful "cannot allocate memory" later.
          echo 1 > /proc/sys/vm/compact_memory
          echo ${toString hugepages2M} > ${nrHugepages}
          got=$(cat ${nrHugepages})
          if [ "$got" -lt ${toString hugepages2M} ]; then
            echo "win-perf: got $got of ${toString hugepages2M} hugepages" >&2
            echo 0 > ${nrHugepages}
            exit 1
          fi
          ;;
        release/end)
          # Teardown runs after a crash too, and every line must be attempted:
          # NO set -e. The cpuset restore comes first because it is the one
          # whose failure cripples the host ("the performance hook does not
          # revert", in Risks).
          for s in system.slice user.slice init.scope; do
            systemctl set-property --runtime -- "$s" AllowedCPUs=${allCpus} || true
          done
          echo 0 > ${nrHugepages} || true
          if [ -r ${savedGovernor} ]; then
            tee ${governors} < ${savedGovernor} > /dev/null || true
            rm -f ${savedGovernor}
          fi
          systemctl start irqbalance.service || true
          ;;
      esac
    '';
}
```

Hook arguments are `$1` guest name, `$2` operation, `$3` sub-operation.
`prepare/begin` runs before QEMU launches; `release/end` after it is gone, so
the teardown runs even on a crash. Note the asymmetry: setup is allowed to
abort, teardown never is.

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
  <!-- No <iothreads>/<iothreadpin>: the guest's only disk is the VFIO
       hostdev, so QEMU has no block device for an I/O thread to serve. -->
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
    # No "wez.wezterm": winget's is an unpinned stable build, and the mux
    # server it would connect to is a pinned nightly — see Phase 3, "WezTerm's
    # Windows GUI pin". Windows does not need a mux client.
  ];
  # Version-locked artifacts are NOT winget packages. render.nix turns these
  # into a download-by-URL + SHA-256 verify step in Apply.ps1, the same way
  # wezterm-pin.nix pins the nightly: an immutable source, never "latest".
  pinned = {
    lookingGlassHost = {
      version = "<same release as pkgs.looking-glass-client>";   # e.g. B7
      sha256  = "<FILL_ME>";
    };
  };
  # Network printers the guest reaches through the host. Rendered into
  # Apply.ps1 as a guarded Add-Printer -IppURL — see Printer sharing.
  printers = {
    "Brother (desk)" = "http://192.168.122.1:631/printers/brother";
  };
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
   `kvmfr` device, so the VM is a window on your normal desktop. The Windows
   half — the Looking Glass *host* application plus the IVSHMEM driver — must
   be the **same release** as `pkgs.looking-glass-client` (a B6 host and a B7
   client do not talk), so it is pinned in the Windows profile by version and
   hash ([Phase 6](#phase-6--managing-the-one-windows-install)) and bumped in
   the same commit as the nixpkgs input that moves the client. nixpkgs has
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

**Input — device by device, no USB controller.**

- **Keyboard and mouse:** Looking Glass forwards them from its window over
  SPICE. When latency matters more than convenience, libvirt's
  `<input type='evdev'>` hands the guest the host's devices, with a both-Ctrl
  hotkey to toggle capture.
- **A gamepad or other single device:** `<hostdev mode='subsystem' type='usb'>`
  by vendor:product for one that always belongs to the guest, or SPICE USB
  redirection (`spiceUSBRedirection`, already on in Phase 4) to lend one on
  demand.
- **Anything anti-cheat-sensitive** boots bare metal anyway, where Windows has
  every port.

**Fallback: a whole USB controller over VFIO**, only for a device that
misbehaves when passed individually (VR headsets are the usual case). It
needs the controller in a clean IOMMU group, binding by address like the NVMe,
and a controller the printer is not on — passing one takes every port on it
([Printer sharing](#keep-the-printer-on-the-host)). Not the default, because
it gives up ports the host uses and adds a third IOMMU gate for a need that
may never come up.

**Audio.** libvirt has supported `<audio type='pipewire'/>` since 9.10. For a
`qemu:///system` domain the QEMU process runs as a system user and cannot find
your session's PipeWire socket, so it needs the `runtimeDir` attribute pointed
at `/run/user/1000`. If that fights you, HDMI audio out of the passed-through
dGPU's audio function is a zero-config fallback — you are passing that function
through anyway.

---

## Phase 8 — Cutover QA

Nix proves the closure; it cannot prove any of this.

**Both boot modes**

- [ ] `bootctl status` on the host → `Secure Boot: enabled (user)`, and
      `msinfo32` on bare metal → *Secure Boot State: On* — Phase 2b survived
      everything after it
- [ ] Windows boots bare metal from the firmware menu, and reports
      **activated** — check again here, not just in Phase 2
- [ ] Windows boots as a guest, and *still* reports activated. This is the
      single most important check in this document: it is what the SMBIOS
      impersonation exists to produce
- [ ] Cross four times — metal, guest, metal, guest — confirming activation
      holds each time. Once is luck; four times is the configuration working
- [ ] Clocks agree after each crossing
- [ ] Sign-in works in both modes with the method chosen in
      [Two TPMs, one install](#two-tpms-one-install) — no PIN re-enrolment
      prompt on the crossing, or one you have decided to live with
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
- [ ] `df -h / /srv/games /srv/media` — root, the host-side game library and
      the media volume share the 1 TB drive; headroom on each is the cost of
      this layout, and it should be a number you accepted rather than one you
      discover

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
- [ ] `virsh managedsave win` is **refused** ("domain has assigned non-USB
      host devices") — libvirt will not save a domain with VFIO devices, so the
      saved-guest case cannot happen. Confirm it once so the refusal is not a
      surprise mid-session
- [ ] The cases that *can* happen, tested while there is nothing to lose:
      `virsh suspend win` (paused, NTFS mid-flight in RAM) then
      `virsh resume win`; and a host `reboot` with the guest up, which must log
      libvirt-guests shutting `win` down cleanly — the `onShutdown = "shutdown"`
      setting from [Phase 4](#phase-4--vfio-and-the-libvirt-host) — rather than
      killing it. Then boot bare metal: no chkdsk on entry
- [ ] After that host reboot, `win` is **not** running on the next NixOS boot
      (`onBoot = "ignore"`)
- [ ] A pre-reboot guard for a paused domain is still worth the twenty lines:
      `virsh list --state-paused` non-empty → refuse to reboot

**The performance hook — the part most likely to be silently wrong**

- [ ] With the VM **down**: `nproc` sees every core; a `nixos-rebuild build` runs
      at full speed
- [ ] With the VM **up**: `systemctl show user.slice -p AllowedCPUs` shows only
      the host cores; `cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages`
      is 8192, not something smaller;
      `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` says performance
- [ ] After `virsh destroy win` (not a clean shutdown — test the crash path):
      everything above reverts, **cpusets first** — and the governor goes back
      to what it was, not to a hard-coded name. `release/end` is what makes
      this true; if it does not fire, or aborts halfway, the host stays
      crippled after every crash.
      **Then boot bare metal and let Windows chkdsk** — `virsh destroy` is a
      power cut to the guest, and the filesystem it cut power to is the real one
- [ ] Reboot with the VM set to autostart off, confirm nothing is degraded

**Printer** — the [Printer sharing checklist](#checklist-1), in full: LAN,
tailnet, guest and bare metal each print, and the printer survives the guest
starting.

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
- [ ] Delete `modules/home/wezterm-pin.nix`'s Windows half, the Windows-zip
      mirroring in `scripts/sync-wezterm.sh`, and the Windows branches of the
      shared WezTerm Lua. The `wezterm-<version>` releases can stay as history
- [ ] Remove the `wsl` node from the Tailscale admin panel
- [ ] Mac: drop `wsl` from `~/.ssh/known_hosts` and any config pointing at it
- [ ] Replace the `n8@wsl` key in `modules/home/default.nix` with `desk`'s own
      key (or, if the key moves to `desk`, rename its comment `n8@desk`)
- [ ] README: replace the "A future native NixOS host" section with the real one
- [ ] Update the "State this repo does not manage" list: the Windows-side WezTerm
      install and the `G:` volume are gone; new entries are the Microsoft
      account the digital license hangs off (no product key — see
      [Secrets](#secrets)), everything on Windows' own drive, rclone
      credentials, the Wi-Fi PSK, the Samba password database (`smbpasswd`),
      `/etc/restic/{media.password,id_ed25519}`, the Secure Boot keys in
      `/var/lib/sbctl` (backed up off-machine — [Phase 2b](#phase-2b--restore-secure-boot)),
      and the guest's TPM and firmware state —
      `/var/lib/libvirt/swtpm/<uuid>/` and `/var/lib/libvirt/qemu/nvram/win_VARS.fd`
      ([Two TPMs, one install](#two-tpms-one-install))
- [x] Note in the README that `hosts/desk/windows/` configures a Windows install
      this repo does not otherwise own — *done in the PR that added this plan*

---

## Risks, ranked

1. **Booting bare metal on top of a paused guest, or rebooting the host with
   the guest up.** The new top risk, and the one genuinely created by this
   design. A paused domain leaves the NTFS mid-flight in host RAM; boot the
   metal from that state and the filesystem takes the damage. A saved domain
   cannot happen — libvirt refuses `managedsave` with VFIO devices — but that
   refusal is itself the second half of the risk: NixOS's default on host
   shutdown is to *try* the save, fail, and let systemd kill QEMU, which is a
   power cut to the real disk on every reboot. Mitigations:
   `virtualisation.libvirtd.onShutdown = "shutdown"` and `onBoot = "ignore"`
   ([Phase 4](#phase-4--vfio-and-the-libvirt-host)); always `virsh shutdown`,
   never pause across a reboot; a pre-reboot check for paused domains; and the
   Phase 8 drill that makes the failure mode familiar before it is expensive.
2. **A stray disko destroy run.** Wipes the bulk drive, which now holds NixOS
   root, the host-side game library *and* the media volume. Install-only;
   everything afterwards is `nixos-rebuild`. The consolation, and it is a real
   one: Windows is on the other drive and this command cannot reach it.
3. **An ID match binds both NVMe drives.** Confirmed in Phase 0: both are SK
   hynix P41s on `1c5c:1959`, so `vfio-pci.ids` takes the host's root device
   too and the machine does not boot — and so does a `new_id` write, which an
   earlier draft of Phase 4 used while believing it was binding by address.
   Phase 4 binds by `driver_override`; the risk now is someone "simplifying"
   that back to either ID form.
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
7. **One 1 TB drive for root, the host-side game library and the media.** Not
   a failure mode, a permanent tax — the one thing in this plan that makes
   daily life tighter to make gaming better. Phase 0 retired the *speed* half
   of this (both drives are the same P41); what remains is capacity, and the
   sizing residual is how you decide it is acceptable *before* Phase 2 fixes
   the split, rather than noticing in month three.
8. **BitLocker re-enables itself.** Windows can turn on Device Encryption after
   some updates or a Microsoft account change. A TPM-sealed key will not unseal
   in the guest, so the next guest boot lands in recovery. Check it alongside
   `powercfg /a`.
9. **Windows Hello breaks on every crossing.** Two TPMs, one install: a
   TPM-backed PIN is invalid in whichever boot mode did not create it, and
   Windows demands a new one each time. Not data loss, but it is the crossing
   cost you will meet most often. Decided in Phase 0 —
   [Two TPMs, one install](#two-tpms-one-install).
10. **IOMMU groups are dirty for the dGPU.** The original gate, unchanged.
11. **The performance hook does not revert.** A crashed VM leaving the host
    pinned to four cores is the kind of bug you diagnose three weeks later as
    "NixOS feels slow lately". The hook's teardown therefore restores the
    cpusets first and tolerates every later failure — an earlier draft ran it
    under `set -e` with a governor name that does not exist on this CPU, which
    would have aborted the teardown before the cpuset restore every single
    time. The `virsh destroy` test in Phase 8 exists for exactly this.
12. **The media backup stops and nobody notices.** The failure mode of every
    backup that has ever failed. `runCheck` plus the `OnFailure` hook in
    [Media storage](#media-storage) are the minimum; the restore drill is what
    actually proves it. Ranked below the Windows risks only because those are
    time-boxed to the migration — this one is permanent, and of everything on
    this list it is the likeliest to be discovered too late.
13. **Samba serving an empty share.** If the bulk SSD does not mount, an
    unguarded smbd exports `/srv/media` on the root filesystem and clients write
    into it. The `requires=srv-media.mount` binding prevents it; verify by
    booting once with the drive pulled.
14. **Secure Boot keys lost to a firmware update.** A BIOS flash or CMOS clear
    restores factory keys; NixOS stops booting, Windows does not, which makes
    it look like NixOS broke. Re-enroll per
    [Phase 2b](#phase-2b--restore-secure-boot) — possible only if
    `/var/lib/sbctl` is still there or backed up. And enrolling *without*
    `--microsoft` is the self-inflicted version: no Windows, no dGPU option
    ROM.
15. **`nix flake check` coverage drops.** Deleting the WSL host takes the
    WSL-specific half of the sixteen wezterm checks with it — the
    activation-script suite and the `wslHost = true` cases — while the
    native-Linux and macOS cases stay. The stale-`rendered/` check in
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
- **WezTerm on Windows.** The Windows GUI existed because Windows was the only
  desktop; now NixOS is. A winget build would be unpinned and could only
  mismatch the pinned mux server — [Phase 3](#wezterms-windows-gui-pin). If
  one is ever wanted, it comes from the mirror release by hash.
