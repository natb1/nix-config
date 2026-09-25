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

## After the reboot — do these, in order

**NixOS is installed on the 1 TB drive as of 2026-09-24, and the desktop is
up. Items 2, 3, 5–8 are done and 9 is mostly done (2026-09-24): `boot_vga`
read 1 on the iGPU, so niri's GPU pinning is enabled and is now confirmed at
runtime; the first switch passed after the `~/.config` ownership fix; `desk` is
on the tailnet; and after two fatal session bugs were fixed, autologin brings
niri up on tty1 on its own. POST is visible (item 1). Only 4 remains —
Windows bare metal, deferred — and it gates
[Phase 2b](#phase-2b--restore-secure-boot).** Work
through this list on the first boot into `desk`. Items 1–4 are verification and
take minutes; 5 onward is ordinary work.

**Two bugs made the first desktop boot fail, both fixed in `249427c`.** Worth
reading if the session ever misbehaves again, because neither announced itself
usefully: `exec niri-session` without `-l`
[looped forever](#the-desktop-session) without ever starting `niri.service`,
and `focus-follows-mouse off` was a KDL parse error that would have killed niri
the moment the loop was broken. The second is now caught by a `nix flake check`
gate; the first is guarded twice over.

The install was seeded ([Seed the install](#seed-the-install-before-rebooting)),
so Wi-Fi, this repo, and the Claude and gh sessions should already be in place.

- [x] **1. Did it boot, and was POST visible?** Two separate questions. If the
      screen was blank until the desktop appeared, the firmware is still
      posting on the dGPU and you were blind at the systemd-boot menu — which
      is how you choose Windows. Not fatal, and the fix is either firmware
      (*Initial Display Output: IGD*) or moving the cable back to the card.
      *2026-09-24: yes to both. POST and the systemd-boot menu are visible on
      the iGPU output, and the menu lists Windows.*
- [x] **2. `cat /sys/bus/pci/devices/0000:12:00.0/boot_vga`** → must be **`1`**
      (and `0000:03:00.0` must be `0`). **This is the Phase 4 gate.** The cable
      was moved on 2026-09-24 and the DRM connectors confirmed it, but
      `boot_vga` is decided at POST and was still `1` on the dGPU at install
      time. Also re-check `cat /sys/class/drm/card*-HDMI-A-*/status` and that
      the iGPU connector's `edid` is now **non-zero** — it read 0 bytes before
      the reboot, which was probably just an undriven connector, but it is the
      only display this machine has.
      - **If `boot_vga` is 1 on the iGPU:** uncomment the `debug` block in
        [`hosts/desk/home/niri.kdl`](../hosts/desk/home/niri.kdl) to pin niri
        to the iGPU and keep it off the dGPU. Phase 4 needs this.
      - **If it is still the dGPU:** leave niri's pinning commented out and
        fix the firmware first.
      - *Measured 2026-09-24 on first boot:* `boot_vga` 1 on `12:00.0`, 0 on
        `03:00.0`; `card2-HDMI-A-2` (iGPU, `12:00.0`) **connected**,
        `card1-HDMI-A-1` (dGPU, `03:00.0`) disconnected. Pinning enabled.
      - *And confirmed at runtime the same day, which closes this gate.* niri's
        own log: render node `/dev/dri/renderD129` from the `12:00.0` by-path
        symlink, `card2` as the primary node, and for `card1` — the dGPU —
        `node is ignored, skipping`. Its only DRM file descriptors were `card2`.
        So niri renders on the iGPU and never opens the dGPU, which is exactly
        what Phase 4 needs in order to lend `03:00.0` to a guest without
        logging out. Two details worth carrying forward: `ignore-drm-device`
        accepts a by-path symlink, so the udev rule the config comment once
        contemplated is unnecessary; and the render-node numbering is the
        reverse of the original guess — dGPU `03:00.0` is `renderD128`, iGPU
        `12:00.0` is `renderD129`. Key anything later off the PCI address.
      - The audio side agrees: the active PipeWire sink is the **Radeon HD
        Audio Controller** HDMI output to the DELL U3415W, i.e. the iGPU's.
        The dGPU's *Navi 21/23 HDMI/DP Audio* device is present and idle,
        which is the right state for a card whose audio function (`03:00.1`,
        alone in IOMMU group 15) is passed to the guest whole.
- [x] **3. Wi-Fi came up on its own** — no `nmtui`. If not:
      `sudo systemctl restart NetworkManager`, and check the profile at
      `/etc/NetworkManager/system-connections/` is 600 and root-owned.
- [ ] **4. Windows still boots bare metal, and is still activated.** *Deferred
      2026-09-24 — not yet tried. The systemd-boot menu does list a Windows
      entry, which says the entry exists, not that it boots. Do this before
      Phase 2b: enrolling Secure Boot keys is the step most able to break
      Windows' boot, and a failure after it is only diagnosable if this
      baseline passed first.* Pick it
      from the firmware boot menu (**F12**). *Settings → System → Activation*
      should still say the digital licence is linked. Nothing touched its
      drive, so this is confirming rather than fixing — but confirm it before
      trusting it. Check the clocks agree afterwards, both sides keeping the
      RTC in UTC.
- [x] **5. Set the root password** if it was not set before the reboot:
      `sudo passwd root`. Day to day it is unused — `n8` has passwordless
      sudo — but it is the break-glass for single-user mode if `hosts/desk/`
      ever stops evaluating.
- [x] **6. First rebuild from the installed system:**
      `cd ~/natb1/nix-config && sudo nixos-rebuild switch --flake .#desk`.
      This is also the test that the seeded checkout and the flake agree.
      *Hit 2026-09-24:* it failed in `home-manager-n8.service` with
      `mkdir: cannot create directory '/home/n8/.config/…': Permission denied`
      — the seed script had left `~/.config` root-owned (fixed since; see
      [Seed the install](#seed-the-install-before-rebooting)). On an install
      seeded before the fix: `sudo chown -R n8:users ~/.config`, then rerun
      the switch.
- [x] **7. `sudo tailscale up`** — `desk` is a new tailnet node, not a rename
      of `wsl`.
- [x] **8. Add a `desk` row to the README's host table** with its rebuild
      command — the one Phase 2 checklist item that is pure documentation.
- [ ] **9. Sanity-check the desktop**: niri starts on tty1, waybar and swaync
      are up, `Mod+Return` gives WezTerm, `Mod+D` gives fuzzel, audio works
      (`wpctl status`), and Chrome opens with
      `--password-store=gnome-libsecret` honoured (gnome-keyring will ask for
      its own password on first use — that is intended, not a fault).
      - *Verified without hands 2026-09-24, after the `249427c` fixes:* getty
        autologin opened the session with no password, `niri.service` is
        `active (running)`, `loginctl` shows the session on **seat0** on tty1,
        waybar and `xwayland-satellite` are up, gnome-keyring started from PAM,
        and `wpctl status` lists a working sink. WezTerm is running — this note
        was written from it.
      - *One fault found and fixed:* `swaync.service` was **failed
        (start-limit-hit)**. Notifications worked, because niri's
        `spawn-at-startup "swaync"` had already started one, but that is a
        second launcher racing the user unit `services.swaync.enable` creates,
        and the unit lost five restarts in a row to `An instance of
        SwayNotificationCenter is already running!`. The `spawn-at-startup`
        line is gone; the unit owns swaync now, which is what gives it
        `Restart=on-failure` and dbus activation. waybar keeps its
        `spawn-at-startup` because `programs.waybar` without `systemd.enable`
        generates no unit to collide with. After the switch the duplicate was
        killed and the unit started in its place: `swaync.service` is
        `active (running)`, owns `org.freedesktop.Notifications`, and delivers
        — and **nothing is failed**, user or system.
      - *A second gap found the same way:* `notify-send` was not installed at
        all, so item 9's own audio/notification check and the
        [Desktop session checklist](#desktop-session-checklist) line that names
        it were unrunnable. `libnotify` is now in the package list.
      - *At the console, 2026-09-24:* `Mod+Return` and `Mod+D` (fuzzel)
        work, notifications draw on screen and stay in the `Mod+N` panel,
        tty2 is a plain shell, and `chrome://version` shows the flag. **Only
        the waybar tray (Steam/Tailscale/blueman) is still unchecked** — see
        the [Desktop session checklist](#desktop-session-checklist).

Known-good state at install time, for comparison if something looks wrong:

| | |
| --- | --- |
| Boot entries | `BootOrder: 0000,0002,0001,0005` — `0000` Linux Boot Manager (NixOS, 1 TB ESP) first, `0001` Windows (2 TB ESP, PARTUUID `8614cf7c…`), `0005` the USB stick |
| Stale NVRAM entry | **Already removed.** `Boot0004` pointed at the wiped 1 TB ESP (PARTUUID `f968dba4…`, which now exists on no partition) and was deleted with `efibootmgr -b 0004 -B`. That closes the residual the plan carried |
| Target layout | `nvme0n1p1` 1 G vfat `/boot`, `p2` 200 G ext4 `/`, `p3` 730.5 G btrfs with `/srv/media` and `/srv/games` subvolumes |
| Windows drive | `nvme1n1` untouched — 16 M MSR, 1.8 T NTFS, 300 M vfat `SYSTEM`, 909 M WinRE |
| Root filesystem after install | 14 G used of 196 G |

---

## Resume here — 2026-09-24

**For a new session picking this up.** This plan lives on PR
[#1](https://github.com/natb1/nix-config/pull/1)'s branch
`claude/sweet-hypatia-03wf7f`, not on `main`. The PR stays open while the
migration runs. Push plan updates to that branch, and fetch and rebase
first, because other sessions push to it too. The repo is **public**:
nothing secret goes in, including Wi-Fi PSKs and tokens.

**Where things stand:** the Windows side of Phase 0 is done, Windows boots
from its own ESP on the 2 TB drive, firmware is F43c with the post-flash
checklist closed, and memory runs the kit's XMP profile (unvalidated) — see
[Status](#status--2026-09-21). The live USB is the 32 GB "ASolid USB" stick
with **NixOS 26.05 graphical**
(`nixos-graphical-26.05.10478.1bc55b9def81-x86_64-linux.iso`, SHA-256
`2EB51809…A64E5B6C`), written raw 2026-09-23. The ISO was hash-checked
before the write; the stick is read back and hash-checked against it
before the first boot.

**Phases 0, 1 and 2 are done. The machine now boots NixOS into a working niri
desktop, and this plan is being edited from it.**

**Phase 0's gate passed.** The Linux pass ran from the live USB on 2026-09-24:
raw output is committed under
[`docs/desktop-inventory/`](./desktop-inventory/), read off in the
[Linux-side table](#phase-0-linux-side--measured-2026-09-24), and the verdict is
[here](#the-gate--passed-2026-09-24) — **dGPU `03:00.0` alone in IOMMU group 14,
its audio `03:00.1` alone in 15, the 2 TB NVMe controller `11:00.0` alone in
28.** Every hardware placeholder in this plan's config blocks holds a real
value, so the Phase 1–4 code below reads as final rather than as a template.

**[Phase 1](#phase-1--land-hostsdesk-in-the-flake) is done** (2026-09-24, from
the live USB). `hosts/desk` is in the flake and `.#desk` evaluates; `.#wsl` is
undisturbed. What landed, and what was deliberately left for later phases:
[here](#what-phase-1-actually-landed--2026-09-24).

**[Phase 2](#phase-2--install-nixos-on-the-bulk-drive) is done and booted**
(2026-09-24). The 1 TB drive was wiped and installed per `hosts/desk/disko.nix`;
the 2 TB Windows drive was not touched. `nixos-rebuild switch --flake .#desk`
runs from the installed system. Two bugs kept the first desktop boot on a login
prompt and were fixed in `249427c` — see the
[after-the-reboot list](#after-the-reboot--do-these-in-order), which is the
live status board for this stretch.

**`boot_vga` is verified, so the Phase 4 GPU gate is closed.** The monitor cable
[was on the wrong GPU](#the-monitor-is-plugged-into-the-wrong-gpu); it moved on
2026-09-24, the firmware posts on the iGPU (`boot_vga` 1 on `12:00.0`), and
niri's own log confirms it renders on `renderD129` and *ignores* the dGPU's
node entirely. That is the property Phase 4 depends on: `03:00.0` is free to go
to a guest without ending the session.

**POST is visible** on the iGPU (item 1, 2026-09-24), so the systemd-boot menu
— where Windows is chosen — can be seen.

**Next:**

1. **Windows bare metal** (item 4), when convenient: pick it from the menu,
   confirm activation, check the clocks agree afterwards. Deferred, not
   skipped — it gates Phase 2b.
2. **The hands-on half of item 9** — `Mod+Return`, `Mod+D`, a notification
   drawing on screen, the waybar tray, Chrome's password-store flag.
3. **[Phase 2b](#phase-2b--restore-secure-boot) waits** on its own rule — NixOS
   booting reliably *for a few days* first (it first booted 2026-09-24) — on
   item 4, and **on [BIOS memory tuning](#bios-tuning)** (decided 2026-09-24),
   so that a failed memory-training boot ending in a CMOS clear cannot also
   cost a Secure Boot key re-enrolment. Nothing in [Phase 3](#phase-3--re-home-what-wsl-was-doing)
   depends on 2b, so Phase 3 is the work to do while it soaks. 2b must still
   land before Phase 4.

### Bootstrapping the live USB

**Scoped down 2026-09-24, once Phase 2's shape became clear.** A live USB keeps
everything in RAM, so every boot repeated the same six steps. Two ideas for
fixing that properly — a custom ISO built from this flake, and an encrypted
persistence partition on the stick — were explored and then **dropped**: after
Phase 2 this machine boots NixOS from its own drive, and the stick becomes a
recovery tool used rarely. Neither is worth carrying as a commitment for that.

What is kept is the cheap part, which removes most of the pain anyway:

**`scripts/live-bootstrap.sh`** — one command replaces the six:

```sh
curl -sL https://raw.githubusercontent.com/natb1/nix-config/main/scripts/live-bootstrap.sh | sh
```

Clones anonymously, switches to the working branch, sets the git identity, and
execs into a `nix-shell` carrying git/gh, the Phase 0 inventory set and
claude-code. Idempotent, so it doubles as the "I rebooted again" command.

The single biggest saving needed no tooling at all: **the `gh` device flow was
never required.** This repo is public, so `git clone` needs no credentials.
`gh auth login` is only for pushing, and only then over HTTPS.

#### Two findings worth keeping, even though the work was dropped

**A partition of the booted stick cannot be formatted.** Creating one works;
formatting it fails with `Cannot use device /dev/sda3 which is in use (already
mapped or mounted)`. Nothing holds the partition — no holders, no
device-mapper entries, plain reads fine. The cause is that an isohybrid image
puts its ISO9660 filesystem on the **raw device**, so `/proc/mounts` carries
`/dev/sda /iso iso9660` for the *whole disk*. The kernel then refuses any
exclusive (`O_EXCL`) open of a partition of that disk, and `cryptsetup` needs
`O_EXCL`. **No flag overrides it** — it is the kernel's claim model, not a
safety check. `sfdisk --append` is unaffected, which is why one half succeeds
and the other cannot. Anything like this has to be done from a machine not
booted off the stick, or from a `copytoram` boot (this ISO supports it).

**There is now a spare 25.7 GiB partition on the live USB** — `/dev/sda3`,
start 7596032, created before the above was understood. It is **unformatted
and harmless**, and the stick boots fine with it there: verified afterwards
that the `iso9660` signature, the `EFIBOOT` vfat, `/iso` and the squashfs were
all intact, and that `sda1` still reads `start=0` with its boot flag. Left in
place rather than removed, because removing it means another partition-table
write for no gain. If a future session wonders what it is, that is what it is.
The original table, should it ever need rebuilding:

```
label: dos
label-id: 0x9fb6382f
/dev/sda1 : start=0,   size=7594752, type=0,  bootable
/dev/sda2 : start=284, size=6144,    type=ef
```


### Booting the live USB again (Phase 2, or any re-measurement)

Everything lives in RAM, so all of this repeats on every boot.

1. **Boot it.** Stick in, power on, **F12** at the Gigabyte logo, then pick
   the **`UEFI:`** entry for the stick. Secure Boot is off, so it boots as is.
   The stick is the 32 GB "ASolid USB" (`usb-ASolid_USB_B0000492-0:0`).
2. **Network.** Wi-Fi is the only link (the Ethernet port is not cabled, and
   `enp13s0` confirms NO-CARRIER). Use the desktop's network menu or `nmtui`.
   `sudo` on the live user is passwordless.
3. **Start a session on the live USB**, so it can run the commands itself.
   One command — see [Bootstrapping the live USB](#bootstrapping-the-live-usb)
   for what it does and why it does not log into `gh`:
   ```sh
   curl -sL https://raw.githubusercontent.com/natb1/nix-config/main/scripts/live-bootstrap.sh | sh
   ```
   Then tell it what to continue with. If a session on the live USB is not
   wanted, run the commands by hand, save the output into the repo checkout,
   push, and continue from WSL.

   The long way round, if the script is unavailable or being debugged:
   ```sh
   nix-shell -p git gh
   git clone https://github.com/natb1/nix-config.git && cd nix-config   # public: no auth
   git switch claude/sweet-hypatia-03wf7f
   git config user.name 'Nathan Buesgens'; git config user.email nathan@natb1.com
   gh auth login                        # only if you intend to push over HTTPS
   NIXPKGS_ALLOW_UNFREE=1 nix --extra-experimental-features 'nix-command flakes' \
     run --impure nixpkgs#claude-code
   ```
4. **Things the live image lacks** that cost time to rediscover: there is no
   `python3`, `dmesg` needs `sudo` (`kernel.dmesg_restrict`), and there is no
   clipboard tool, so `gh`'s device flow cannot copy its own code. `sudo` is
   passwordless. Inventory tools come from
   `nix-shell -p pciutils usbutils hwloc fio smartmontools dmidecode iw lm_sensors nvme-cli stressapptest`;
   `lspci`, `lsusb`, `smartctl` and `nvme` are already on `PATH`.
5. **Never put backticks in a `git commit -m` message here.** Obvious in
   hindsight, wasted a couple of minutes on 2026-09-24: the shell runs them as
   command substitution, and a message quoting `` `gh auth login` `` *ran*
   `gh auth login`, which blocked on a device-code prompt. Use `git commit -F`
   with a heredoc for anything with backticks in it.

Cloud sessions can still evaluate the flake: install Nix from
`releases.nixos.org`'s tarball (single-user, with `build-users-group =` in
`/etc/nix/nix.conf`), then pass
`--override-input <name> 'git+https://github.com/<owner>/<repo>?rev=<locked rev>&shallow=1'`
for each locked input, because the proxy serves git clones of GitHub but not
tarballs. In that container `nix flake check`'s wezterm tests fail the same
way with or without the change, so compare against the base commit there.

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
- **WinRE, re-registered in the new ESP's BCD** (2026-09-23) — `reagentc /info`
  → **Enabled**, location `harddisk1\partition4\Recovery\WindowsRE`, and
  `{current}`'s `recoverysequence` points at the new WinRE loader. It took the
  `ReAgent.xml` fix in
  [WinRE after moving the ESP](#winre-after-moving-the-esp): the plain
  `/disable; /enable` failed with error 2.
- **Activation, from a boot off the new ESP** (2026-09-23) — *"Windows is
  activated with a digital license linked to your Microsoft account."* The
  new ESP is proven, so **the 1 TB drive's ESP is now disposable**; Phase 2
  wipes it with the rest of that drive.
- **Firmware F9d → F43c** (2026-09-23), flashed with Q-Flash from a FAT32
  stick after the image's 16-bit sum matched the published `9D0F`
  (SHA-256 `21A6448F…36748C0C`). `Win32_BIOS` → `F43c`, 2026-07-20. Windows
  boots, is still activated (`LicenseStatus` 1), and Wi-Fi is up. The flash
  turned **Secure Boot back on**, as F38 predicted. It is off again:
  `Confirm-SecureBootUEFI` → False, and Windows still boots from the 2 TB
  ESP (`Get-Partition | ? IsSystem` → disk 1, partition 3). SVM and the
  IOMMU are on: Windows lists DMA protection among its available security
  properties, which needs the IOMMU. The plan's *PME Event Wake Up* item
  turned out not to exist on this board; see the corrected wake item in the
  [post-flash checklist](#firmware-update).
- **Post-flash checklist closed** (2026-09-23) — confirmed in firmware setup:
  Initial Display Output IGD, IOMMU Enabled (not Auto), ErP Disabled. Memory
  runs the kit's **XMP profile** (the kit has no EXPO): `Win32_PhysicalMemory`
  → 6000 MT/s. It has passed **one** of the seven validation rows (`stressapptest`, 2026-09-24, `Status: PASS` with a clean `journalctl -k`); the other six, including the hot run, are outstanding, so it is **not yet validated**. The rest of
  [BIOS tuning](#bios-tuning) is deferred. The validation set runs before
  media [Step 3](#step-3--bring-the-media-in); until then an unexplained
  crash means dropping back to JEDEC first.

- **Phase 1 prep: the WSL-only tailscale watcher moved into `hosts/wsl/`**
  (2026-09-24) — [the one landmine](#the-one-landmine-in-the-shared-modules).
  A pure refactor: `.#wsl` evaluates to the same derivation before and after.

- **Phase 0, Linux side — complete, and the gate PASSED** (2026-09-24). Run
  from the live USB; raw output committed under
  [`docs/desktop-inventory/`](./desktop-inventory/), read off in the
  [Linux-side table](#phase-0-linux-side--measured-2026-09-24).
  **[The gate](#the-gate--passed-2026-09-24) is clean on both parts**: the dGPU
  `03:00.0` is alone in IOMMU group 14, its HDMI audio `03:00.1` alone in group
  15, and the 2 TB NVMe controller `11:00.0` alone in group 28. No ACS
  override, no slot shuffling, no block-device fallback. Also settled:
  `wlp14s0`; iGPU `12:00.0`; bulk drive
  `nvme-SHPP41-1000GM_SJB8N565511208H0I`; both SSDs at 1% wear; SMT sibling of
  CPU *n* is *n*+6; the SMBIOS UUID matches Windows byte for byte.
  **Every `<DGPU_ADDR>` / `<IGPU_ADDR>` / `<FAST_NVME_ADDR>` / `<FILL_ME_WLAN_IF>`
  / `<FILL_ME_BULK>` placeholder in this plan's config blocks is now a real
  value.** Two findings that go the other way, neither blocking:
  **Linux sees no fans** (ITE `0x8689`, unclaimed by mainline `it87`) and **no
  DIMM temperatures** (`spd5118` binds nothing), so fan control is
  firmware-only for good and BIOS tuning's thermal check moves to HWiNFO. In
  the plus column, **Wake-on-WLAN lists `wake up on magic packet`**, so
  suspend-on-idle survives to Phase 8.

  The same pass turned up one thing that needs hands on the machine:
  **the monitor is cabled to the dGPU, so the firmware posts on it**
  (`boot_vga=1` on `03:00.0`) and the board's own video outputs are empty.
  *Initial Display Output: IGD* is set and cannot help. See
  [The monitor is plugged into the wrong GPU](#the-monitor-is-plugged-into-the-wrong-gpu).

- **Phase 1 — `hosts/desk` landed and evaluates** (2026-09-24). The installable
  base only: `default.nix` (systemd-boot, NetworkManager, MT7922 firmware),
  `hardware-configuration.nix`, `disko.nix`, the `disko` and `NixVirt` flake
  inputs, `nixosConfigurations.desk`, and `desk` added to CI's eval gate.
  Checked rather than assumed: `.#desk` evaluates, **`.#wsl` still does**,
  disko generated all four `fileSystems`, and its device is the 1 TB drive.
  Details and the deliberate omissions:
  [What Phase 1 actually landed](#what-phase-1-actually-landed--2026-09-24).

### Next, in order

1. **Verify `boot_vga` after a reboot.** The cable was moved 2026-09-24 and the
   DRM connectors confirm it (iGPU `connected`, dGPU `disconnected`), but
   `boot_vga` is set at POST and still reads 1 on the dGPU. Does not block Phase 2; **does block
   [Phase 4](#phase-4--vfio-and-the-libvirt-host)**, whose vfio-pci bind fails
   with `BAR 0: can't reserve` while simpledrm holds the dGPU.
2. **Phase 2** — install NixOS on the 1 TB drive, Secure Boot off. **The first
   destructive step in this plan.** Boots this same stick again. Note the
   [stale NVRAM entry](#residuals--open-not-blocking-the-next-step) for the
   1 TB drive's old ESP, which disko's wipe orphans. The installed machine
   autologins into **niri** — `desktop.nix` landed with Phase 1. Before
   rebooting, run
   [`scripts/seed-install.sh`](#seed-the-install-before-rebooting), which
   copies the Wi-Fi profile, this repo, and the Claude and gh sessions onto
   `/mnt`. Without it the first boot has no network (the PSK is deliberately
   not in a public repo), no checkout, and no logins — all recoverable by
   hand, but there is no reason to do it by hand.
3. **Phase 2b** — turn Secure Boot back on, with lanzaboote and your own keys
   plus Microsoft's.

~~Phase 0, Linux side~~ and ~~Phase 1~~ — both done 2026-09-24, above.

Independent of the list above, in firmware setup, any time:

- **[Fan control](#fan-control)** — the fans run at or near full speed most of
  the time. Firmware-only, and none of the tuning risk, so it need not wait.

Later, unscheduled:

- **[BIOS tuning](#bios-tuning)** — validate the XMP profile already on,
  then timings, then the CPU, then fast boot. Deferred 2026-09-23. **Its
  memory steps now gate [Phase 2b](#phase-2b--restore-secure-boot)**
  (2026-09-24), and the XMP validation gates media Step 3. Done after
  Phase 2b, a failed memory-training boot that ends in a CMOS clear also costs
  a Secure Boot key re-enrolment — see
  [Why the ordering matters](#why-the-ordering-matters-here).

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

### Decided 2026-09-23 — the desktop session

The plan had a slot for a desktop (`desktop.nix`: "display manager, PipeWire,
fonts, browser") but no desktop in it. Settled here, in full in
[The desktop session](#the-desktop-session):

- **niri**, assembled à la carte: waybar, **swaync** for notifications,
  fuzzel, swayidle. No prebuilt shell.
- **getty autologin straight into niri, and no screen lock.** Anything
  sensitive sits behind its own encryption — **gnome-keyring** holds Chrome's
  and other apps' secrets under a password of its own.
- **Idle: screens off, then suspend if Wake-on-WLAN proves reliable**; if it
  does not, screens off and never suspend. Phase 8 decides, with a stated bar.
- **iPhone notifications on the desktop over ANCS** (Bluetooth LE), via
  `ancs4linux` into swaync. A use case today.
- **The dGPU is lent to the host on demand**, not handed over at boot: the
  iGPU runs the desktop always, `dgpu host` gives the RX 6600 XT to native and
  Proton games, and starting `win` takes it back — see
  [Lending the dGPU to the host](#lending-the-dgpu-to-the-host-on-demand).
- **Push alerts to the phone (ntfy) are an optional follow-up**, not part of
  the cutover — see [Optional follow-ups](#optional-follow-ups).

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
| Board revision on the PCB itself | [Firmware update](#firmware-update) | The box says 1.0. `dmidecode` cannot settle it — the board's SMBIOS *Version* reads `x.x` (2026-09-24). The silkscreen (near the bottom edge, "REV: 1.x") is authoritative; worth a glance before the *next* flash. F43c is already on and boots, so this is retrospective now |
| Linux sees neither the fans nor the DIMM temperatures | [Fan control](#fan-control), [BIOS tuning](#bios-tuning) | Measured 2026-09-24. The board's ITE Super I/O reports **chip ID `0x8689`**, which mainline `it87` does not claim (`modprobe it87` → `No such device`), so no header RPM or PWM shows up in `sensors`. `spd5118` finds no DIMM sensors either. Two consequences: fan control stays firmware-only (already the plan, now forced), and BIOS tuning's "DIMMs under ~55 °C" has to be read from HWiNFO under bare-metal Windows. An OS-side curve would need the out-of-tree `it87` fork |
| Total size of the media, across all five sources | Media storage, [Step 3](#step-3--bring-the-media-in) | Google Drive + Google Photos + the MacBook + a GCS bucket + Flickr must fit in ~730 GB after de-duplication — **together with the host-side Steam library**, which shares that volume. If they do not, the root/media split or the drive changes — measure before Phase 2 fixes the split |
| GCS bucket: storage class and egress | [Step 3](#step-3--bring-the-media-in) | Coldline/Archive add per-GB retrieval fees on top of internet egress. Check the class before pulling |
| Flickr export request | [Step 3](#step-3--bring-the-media-in) | Asynchronous — Flickr prepares the archive over hours to days. Request it early so it is ready by ingest; download links expire |
| Google Takeout export request | [Step 3](#step-3--bring-the-media-in) | Same shape as Flickr, worse deadline: Takeout is prepared over hours to days and the **download links expire after 7 days**. Request it with *delivery to Google Drive* so it lands somewhere rclone can pull from unattended, instead of a browser download that must finish inside the window |
| Google Photos library size and item count | [Step 3](#step-3--bring-the-media-in) | Read both off [photos.google.com](https://photos.google.com) before requesting the export — the count is the only verification Takeout admits, and it has to be recorded *before* the library changes under it |
| Google One quota headroom for the Takeout archive | [Step 3](#step-3--bring-the-media-in) | Delivery to Drive stores the archive *in* Drive, against the same quota Photos already fills, so it needs free space equal to the library. No headroom → download-link delivery pulled inside the 7 days, or a month of extra storage |
| Windows Hello sign-in method | Before the first guest boot | Bare metal and the guest use different TPMs, so a TPM-backed PIN is invalidated on every crossing — [Two TPMs, one install](#two-tpms-one-install). Decide: password sign-in, PIN re-created per crossing, or test fTPM passthrough |
| Fate of the Drive/Photos/GCS/MacBook/Flickr copies | After the restore test | Keep, or retire in favour of `/srv/media` + Hetzner. Not before the restore test either way |
| ~~Stale NVRAM entry for the old ESP~~ | ~~Phase 2~~ | **Closed 2026-09-24.** disko wiped the 1 TB drive and `Boot0004` (PARTUUID `f968dba4…`) was left pointing at nothing; verified that GUID exists on no partition, then removed it with `efibootmgr -b 0004 -B`. One Windows entry remains, on the 2 TB ESP |
| `C:` free space | Ongoing | ~88 GB after the ESP. Games live here; the answer to "full" is uninstalling or a bigger Windows drive, never the 1 TB drive |
| `virtio-win` NIC/balloon drivers | Before the first guest boot | Install from bare metal via `pkgs.virtio-win`'s ISO |
| `account.microsoft.com/devices` | Before Phase 8 | Note the name the PC is listed under — it is how the Activation Troubleshooter identifies it |
| Game library vs ProtonDB, and each title's Secure Boot/TPM requirement | Before Phase 7; Phase 2b | Which titles need Windows at all, which of those need bare metal (kernel anti-cheat), and which of *those* refuse to start without Secure Boot (e.g. Battlefield 6, recent Call of Duty). The last list is why [Phase 2b](#phase-2b--restore-secure-boot) exists |
| Printer's USB URI | [Printer sharing](#printer-sharing) | The serial-keyed `usb://Brother/HL-L2305%20series?serial=U66480F3N341782` is built from what Windows reports; `lpinfo -v` after Phase 2 is authoritative |
| Alerting for `OnFailure` | Media storage | `<FILL_ME_notify_unit>` — the repo has no notification path yet. The intended answer is ntfy, deferred to [Optional follow-ups](#optional-follow-ups); until then the unit is a desktop pop-up via swaync, which only helps if you are at the desk |
| ancs4linux: pinned revision and hash | [iPhone notifications](#iphone-notifications-over-ancs) | Not in nixpkgs; packaged in this repo, pinned by rev and hash like every other out-of-tree artifact here |
| Memory kit's DRAM IC | [BIOS tuning](#bios-tuning) | Kit: 2 × 16 GB Corsair Vengeance **`CMK32GX5M2D6000C36`** — **XMP only, no EXPO**: DDR5-6000 36-36-36-76 at 1.35 V; running its XMP profile since 2026-09-23, not yet validated. The DRAM IC (Hynix A/M-die, Samsung, Micron) decides how far the timings go; the part number usually identifies it |

### Firmware update

**Done 2026-09-23: F9d (2023-09) → F43c (2026-07-20, AGESA 1.3.0.1c).**

The board is rev 1.0, and rev 1.0/1.1 BIOSes are listed on Gigabyte's
*un-suffixed* B650I AORUS ULTRA page — the same F-series line this board is
already on (F9 → F20 → F30 → … → F43c). Rev 1.3 and 1.4 have their own pages
and their own files; **never flash a file from those.** Checked 2026-09-21:

| | |
| --- | --- |
| Support page | <https://www.gigabyte.com/Motherboard/B650I-AORUS-ULTRA/support> |
| File | [`mb_bios_b650i-aorus-ultra_8arpl109_f43c.zip`](https://download.gigabyte.com/FileList/BIOS/mb_bios_b650i-aorus-ultra_8arpl109_f43c.zip) (14.57 MB) |
| Checksum (as published) | `9D0F` — the 16-bit sum of the image's bytes, which catches corruption, not tampering. `B650IAORUSULTRA.F43c` (33,554,432 bytes) matched it |
| SHA-256, as downloaded 2026-09-23 | zip `25F6CEC3331791F1ACE1B42D8C137C10BCA0F15D854576333AB6ACC5347B2890`; image `21A6448FC08FD9ADC6DDA75D0FA629808B2849C5633DE5FBFEA699F636748C0C` |
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

- [x] **SVM** enabled and **IOMMU** set to Enabled (not Auto) — *2026-09-23:
      Windows reports virtualization firmware on and lists DMA protection
      (`Win32_DeviceGuard` property 3, which needs the IOMMU). That cannot
      tell Enabled from Auto; the setup screen can*
- [x] **Initial Display Output: IGD** (the iGPU), not the PCIe slot — *set, and
      confirmed in setup 2026-09-23.* If the
      firmware POSTs on the dGPU, the kernel's simpledrm claims the card's
      framebuffer before vfio-pci binds and the bind fails with
      `BAR 0: can't reserve` — see [Phase 4](#phase-4--vfio-and-the-libvirt-host).
      Bare-metal Windows is unaffected: it drives the dGPU from its own driver
      whichever GPU the firmware posted on.
      **But the setting is not sufficient, and on 2026-09-24 it was not
      working:** `boot_vga=1` on `0000:03:00.0`, because the only monitor is
      cabled to the graphics card and the board's video outputs are empty. A
      preference cannot post to a port with nothing in it. The outstanding
      action is physical, not a firmware one — see
      [The monitor is plugged into the wrong GPU](#the-monitor-is-plugged-into-the-wrong-gpu)
- [x] **Secure Boot off — it will not be.** *2026-09-23: on after the flash
      (`UEFISecureBootEnabled` = 1), then turned off (`Confirm-SecureBootUEFI`
      → False).* F38's release notes: *Secure Boot
      enabled as system default*. So after flashing it is **on**, and must be
      turned off again (Windows boots either way; systemd-boot without
      lanzaboote does not). CSM off. *Once [Phase 2b](#phase-2b--restore-secure-boot)
      is done this check inverts:* a flash may also reset the key databases to
      factory defaults, dropping your enrolled key — NixOS then refuses to boot
      until the keys are re-enrolled. See Phase 2b's recovery note
- [x] Boot order — Windows Boot Manager on the **2 TB** drive first (until
      NixOS exists) — *2026-09-23: `Get-Partition | ? IsSystem` → disk 1,
      partition 3*
- [x] XMP/EXPO memory profile, if it was on before — *after the flash:
      4800 MT/s, so off. Whether it was on under F9d went unrecorded. Turned
      on 2026-09-23 (XMP, 6000 MT/s); validating it is
      [BIOS tuning](#bios-tuning) step 2* — and after
      [BIOS tuning](#bios-tuning), every setting in its table: reload the saved
      profile, then check it against the table, since a profile saved on one
      BIOS version is not guaranteed to load on the next
- [x] Windows boots and is still activated — *2026-09-23, `LicenseStatus` 1*. The fTPM may be cleared by an AGESA
      jump; with BitLocker off that costs nothing but possibly a Windows Hello
      PIN re-setup
- [x] Wi-Fi still works in Windows (the only network this machine has) —
      *2026-09-23, `Wi-Fi` (RZ616) Up*
- [ ] **ErP Disabled** (*Settings* → *Platform Power* → *ErP*; the menu is
      in Advanced Mode, F2). *Corrected 2026-09-23:* an earlier version of
      this item also asked for *PME Event Wake Up* / *Resume by PCI-E Device*.
      Neither exists on this board. Gigabyte's AM5 BIOS guide lists only AC
      BACK, ErP, Soft-Off by PWR-BTTN, Power Loading and Resume by Alarm
      under Platform Power. On AM5, wake from a PCIe device has no firmware
      switch. ErP only governs standby power in **S5** (soft-off), so it
      matters for waking a shut-down machine, not a suspended one. Wake from
      suspend is decided on the Linux side: the device's
      `/sys/bus/pci/devices/<wifi>/power/wakeup` = `enabled` and its
      `/proc/acpi/wakeup` entry. Check it in Phase 8 — see
      [Idle](#idle-screens-off-then-suspend--if-the-wi-fi-can-wake-it)
- [x] Record the new version in the Phase 0 table

### BIOS tuning

**Deferred 2026-09-23 — later, unscheduled.** The machine runs the F43c
defaults plus the kit's XMP profile meanwhile. Nothing in this plan waits on
tuning, except that the XMP profile is validated before media Step 3. Whenever it happens, each change is validated before the machine
runs with the media on board ([Step 3](#step-3--bring-the-media-in)). If it
happens after [Phase 2b](#phase-2b--restore-secure-boot), see the key cost
below. The firmware defaults run this
machine safely and slowly: on AM5 that mostly means JEDEC memory (DDR5-4800,
loose timings) and stock boost behaviour. Both are worth tuning on a box that
spends its time compiling and gaming. The tuning itself is ordinary; what this
plan adds is *when*, *how it is proven*, and *where it is written down*.

#### Why the ordering matters here

- **Unstable memory corrupts the things this plan cannot rebuild.** A bit flip
  in RAM happens *before* btrfs computes a checksum, so the checksum faithfully
  protects the corrupted data, `autoScrub` finds nothing, and restic backs it
  up to Hetzner. The same flip in the guest lands on the one Windows install.
  So memory is proven stable before the irreplaceable media arrives, not after.
- **A failed memory-training boot ends in a CMOS clear**, and a CMOS clear
  resets the Secure Boot key databases to factory ([Risk 14](#risks-ranked)).
  Tuning before Phase 2b means the trial-and-error happens while there are no
  keys to lose. Tuning *after* it, now the likely order since tuning is
  deferred, means re-enrolling keys every time a timing is one step too tight.
  That costs a few minutes, and nothing is at risk. Windows still boots on
  factory keys; for NixOS, turn Secure Boot off, boot, reset to Setup Mode,
  `sbctl enroll-keys --microsoft`, and turn it back on
  ([Recovery](#recovery-and-the-firmware-update-trap)). So batch the tuning
  into a few sittings rather than spreading it out.
- **The firmware update resets everything.** Tune once, on the firmware you
  will run, not on F9d.

#### What to tune, in order

One change at a time, each validated before the next. A tune that fails a test
two changes later cannot be attributed.

1. **Baseline.** Record what the kit is and what it runs at now (the residual
   above). Run the validation set below at defaults, so a later failure has a
   known-good point to fall back to.
2. **The kit's rated profile — XMP, not EXPO.** `CMK32GX5M2D6000C36` carries
   an XMP profile only: DDR5-6000, 36-36-36-76, 1.35 V. **On since
   2026-09-23; the baseline (step 1) was skipped, and validation is pending.**
   **First validation leg passed, 2026-09-24:** `stressapptest -s 3600
   -M 20000` on the live USB returned `Status: PASS` — 0 hardware incidents,
   0 errors, 3600.92 s at 39.4 GB/s — and `journalctl -k -g 'mce|EDAC|Hardware
   Error'` afterwards showed only subsystem banners (`EDAC MC: Ver: 3.0.0`,
   `MCE: In-kernel MCE decoding enabled`, `RAS: Correctable Errors collector
   initialized`), no events. 20000 MB rather than the 24000 MB this document
   suggested, because a live USB's `/nix/store` upper layer is a tmpfs and
   over-allocating would have OOM-killed the run. Raw output:
   [`docs/desktop-inventory/12-stressapptest.txt`](./desktop-inventory/12-stressapptest.txt).
   **That is one row of seven.** MemTest86+, TestMem5, y-cruncher and the hot
   run are all still outstanding, and the hot run is the one this profile is
   most likely to fail — see the temperature note below. So the profile is
   *not* validated yet; it is one leg in.
   That 1.35 V is DDR_VDD/VDDQ, the DIMMs' own rail, supplied by the PMIC on
   each module. It is not VSOC, the CPU's SoC rail, which the step-3 limit
   below is about. The profile does not set VSOC directly, but the firmware
   raises it automatically to run DDR5-6000 (typically to ~1.25 V), and
   AGESA since 2023 caps it at 1.30 V. Read it off *Tweaker* (*VCORE SOC*),
   or off HWiNFO's *CPU SoC Voltage (SVI3)*. XMP is fine on this
   board: Gigabyte's *Tweaker* → *XMP/EXPO Profile* reads either kind of SPD
   profile, so select the kit's XMP profile there. If it is not offered, or
   will not train, enter the same values by hand (DRAM frequency 6000;
   tCL/tRCD/tRP/tRAS 36/36/36/76; DDR_VDD and DDR_VDDQ 1.35 V; everything else
   Auto). An XMP profile is written for Intel memory controllers, so the
   firmware picks the secondary timings, and those are loose. That is where
   step 3's gains come from. On a 7600X the target is DDR5-6000 with
   **FCLK 2000 MHz** and **UCLK = MEMCLK (1:1)** — check the firmware did not
   drop UCLK to 1:2, which silently costs more than the profile gains.
   Validate. For many kits this is where to stop, and that is fine.
3. **Memory timings, only if the rated profile validated cleanly.** In order of payoff for
   DDR5 on AM5: **tRFC** (by far the largest, and very IC-dependent — Hynix
   A/M-die goes much lower than the profile), then **tREFI** raised (large gain,
   but temperature-sensitive — see below), then tRRD/tFAW/tWR, then primaries.
   Leave voltages at the rated values unless a specific timing needs them; VSOC
   stays **at or below 1.30 V** — AM5's hard limit, and the one setting in this
   list that can kill the CPU.
4. **Memory Context Restore.** AM5 retrains memory on every boot unless this is
   on, which is the 30–60 s black screen before POST. Turn it on **with Power
   Down Enable**, *after* the timings are final — with MCR on a marginal tune
   can pass training and fail later, so it must not be on while tuning.
   Re-validate: a tune that is stable with MCR off is not proven with it on.
5. **CPU: PBO + Curve Optimizer**, or nothing. Negative per-core offsets,
   modest ones (−10 to −20), validated per-core — an all-core load does not
   test the light-load boost states where Curve Optimizer instability lives.
   The payoff on a 7600X is lower temperatures and a little clock; the cost of
   getting it wrong is a compile that segfaults once a week. If the per-core
   test is too tedious, skip it: stock is a perfectly good answer here.
6. **Fan curves, re-checked** — the tune changes the heat. The curves
   themselves are set earlier, in [Fan control](#fan-control); here they are
   re-checked against the tuned machine's hot run. On mini-ITX the DIMMs sit
   in the GPU's exhaust; see temperature below.
7. **Fast Boot** — last of all, and only once NixOS is installed, because it
   hides the USB devices every step above relies on. *Boot* → *Fast Boot*:
   Disabled / Enabled / Ultra Fast. On AM5, Memory Context Restore (step 4)
   is most of the boot-time win; Fast Boot trims device enumeration on top.
   Use **Enabled, with *USB Support* = Full Initial — never Ultra Fast.**
   *Revised 2026-09-25: Ultra Fast is acceptable now that a bad generation
   falls back by itself — `bootCounting`, `panic=10` and the SP5100 watchdog
   in `hosts/desk/default.nix`. Setup is then `systemctl reboot
   --firmware-setup`, Windows `sudo efibootmgr --bootnext <its entry>`, and a
   CMOS clear plus the saved profile is the way back. Measure it against
   Enabled with `systemd-analyze` before keeping it; the text below is the
   original reasoning.*
   Ultra Fast leaves USB off until the OS loads. That kills the keyboard at
   the systemd-boot menu, which is how this machine chooses between NixOS and
   Windows, and it stops the machine booting a USB stick. That rules out the
   live USB, Q-Flash, and MemTest86+. Keep *NVMe Support* on (both drives
   boot), and leave *SATA Support* alone (there are no SATA drives). Entering
   setup without the keyboard at POST: `systemctl reboot --firmware-setup`
   from NixOS, or *Settings* → *System* → *Recovery* → *Advanced startup* →
   *UEFI Firmware Settings* from Windows. Verify: the systemd-boot menu takes
   keys, F12 still lists a USB stick, and cold-boot time is measurably lower
   (`systemd-analyze` reports the firmware time). Windows' own **Fast
   Startup** is a different thing (a hibernated kernel) and stays off either
   way: the NTFS is shared with the guest.

Leave alone, and re-check after each change since some firmware menus move
them: **SVM**, **IOMMU Enabled**, **Initial Display Output: IGD**, CSM off, and
**Above 4G Decoding** on. **Resizable BAR** stays on for bare-metal gaming; it is
the one setting that interacts with passthrough, so the Phase 8 guest checks
(no Code 43, frame times) are also its test, and turning it off is the first
thing to try if the guest's dGPU misbehaves.

#### Validation — the definition of "stable"

Each step passes all of these, or it is reverted:

| Test | Where | Pass |
| --- | --- | --- |
| MemTest86+ | The systemd-boot menu entry (`boot.loader.systemd-boot.memtest86.enable`, on since 2026-09-25) | 4 full passes, zero errors |
| TestMem5 (anta777 *extreme* config) | Bare-metal Windows | 3 cycles, zero errors |
| y-cruncher (VT3 / all tests) | Bare-metal Windows | 1 hour, no errors |
| CoreCycler | Bare-metal Windows, **Curve Optimizer only** | Every core, several hours overnight |
| `stressapptest -s 3600 -M <most of free RAM>` | Linux (live USB, later the host) | "Status: PASS" — **passed 2026-09-24** on the XMP profile, see below |
| Hot run | Whatever the machine does at its hottest — a long game session plus a build | Nothing below, afterwards |
| Error logs | Windows Event Viewer → System, source **WHEA-Logger**; Linux `journalctl -k -g 'mce\|EDAC\|Hardware Error'` | **Empty.** A corrected WHEA-19 is a failure, not a warning: it means the margin is gone |

**Temperature is the hidden variable.** DDR5 errors climb with DIMM
temperature, and tREFI is where they show first. A mini-ITX case with the RX
6600 XT exhausting across the DIMMs is the worst case, and a synthetic memory
test with the GPU idle does not reproduce it. Watch the SPD hub sensors
during the hot run; keep the DIMMs under ~55 °C, and back tREFI off before
anything else if errors appear only when warm. **Read them in HWiNFO under
bare-metal Windows** — on this board Linux cannot: `spd5118` binds nothing
(2026-09-24), so `sensors` reports no DIMM temperature at all. That makes the
hot run a Windows-side test here, which is convenient anyway, since the
"long game session" half of it is a Windows workload.

#### Where it is written down

BIOS settings are not declarative, so the record is the declaration:

- **A table in `hosts/desk/bios.md`**: firmware version, every non-default
  setting with its value, and the validation date. It is what gets the machine
  back after the next firmware update, which will reset all of it.
- **The firmware's own profile save** (Save Profile → to USB, plus a slot on
  the board) as the fast path — but the table is authoritative, because
  profiles are not guaranteed to load across BIOS versions.
- A photo of each settings page is a cheap third copy.

#### BIOS tuning checklist

- [ ] Baseline recorded; validation set passes at defaults
- [ ] XMP profile on (or its values by hand), FCLK 2000, UCLK = MEMCLK; validated
- [ ] Timings tightened (or explicitly stopped at the rated profile); VSOC ≤ 1.30 V; validated
- [ ] Memory Context Restore + Power Down Enable on; re-validated; cold boot
      is fast and warm reboots do not retrain
- [ ] Curve Optimizer validated per-core (or explicitly skipped)
- [ ] Fan curves re-checked; hot run clean, DIMMs under ~55 °C
- [ ] Fast Boot Enabled (USB Full Initial); systemd-boot menu and F12 USB boot still work
- [ ] SVM, IOMMU, IGD, Above 4G, CSM, ReBAR re-checked
- [ ] `hosts/desk/bios.md` committed; profile saved to USB
- [ ] Each step validated before it runs with the media on board; after
      Phase 2b, Secure Boot keys re-enrolled if a CMOS clear dropped them

### Fan control

Added 2026-09-23: the fans run at or near full speed most of the time. On the
F43c defaults that is a configuration problem until shown otherwise, and one
that can be fixed any time. Nothing here carries the tuning risk above.

**In the firmware, not in an OS.** This machine boots two operating systems,
and a curve set in one runs only while that one is up: CoolerControl on NixOS
does nothing for a bare-metal Windows session, and FanControl on Windows does
nothing for NixOS. Smart Fan 6 runs on the board's Super I/O chip, under
either OS, and even while a failed boot sits at the firmware. An OS-side
controller is only worth adding for what the firmware cannot see (below).

**Diagnose first** — *Smart Fan 6* (F6 in setup) shows every header's live
RPM and the temperature driving it:

1. **Which fan is loud.** CPU_FAN, SYS_FAN*n* and the pump/OPT header each
   show an RPM. The RX 6600 XT's fans are on no header; the card controls
   them itself, and so does the PSU. If every header reads slow and the noise
   stays, it is one of those.
2. **Control mode per header.** **PWM** for a 4-pin fan, **Voltage** for a
   3-pin one. A 3-pin fan on a header in PWM mode gets full voltage and runs
   flat out whatever the curve says. That is the commonest cause of "always
   full speed". *Auto* usually detects it, but not always.
3. **Fan Speed Control** — if a header says *Full Speed*, that is the answer.
4. **The input temperature.** The CPU fan follows CPU. Case fans following
   CPU too is the usual default, which is what makes them chase it.

**Why a stock curve howls on a 7600X.** Zen 4 reports temperature in spikes:
opening a browser tab takes it from 45 to 70 °C for a second. A curve that
follows it exactly revs constantly. Raise **Temperature Interval** (the
hysteresis: how far the temperature must move before the speed changes), and
keep the curve flat up to ~60–65 °C. And the 7600X boosts until it reaches
95 °C by design, so a curve that hits 100 % at 70 °C is at 100 % whenever
anything compiles. A starting point, *Slope* mode, CPU input: ~30–40 % up to
60 °C, ~70 % at 80 °C, 100 % at 90 °C. Case fans lower, with a larger
interval. Leave *FAN Stop* off on the CPU fan.

**Less heat beats any curve.** A mini-ITX cooler has little headroom. **Eco
Mode** is AMD's preset that runs the 105 W 7600X within a 65 W TDP's power
limits (PPT 142 W → 88 W), in effect making it a non-X 7600. Light-load and
single-core boost are untouched, and only sustained all-core loads clock
lower. It is offered in the PBO / AMD Overclocking menus, and it
costs a few percent of all-core throughput, meaning compiles, costs nothing
measurable in games, and cuts load temperatures sharply. It is the biggest
single lever on noise here. Curve Optimizer ([BIOS tuning](#bios-tuning)
step 5) is the same lever at smaller scale. Try Eco Mode before settling on a
louder curve.

**What the firmware cannot see:**

- **The DIMMs.** They sit in the GPU's exhaust, and BIOS tuning wants them
  under ~55 °C. No header curve can follow a DIMM sensor. *And on this board
  neither can Linux* — `spd5118` binds nothing (2026-09-24), so the
  `programs.coolercontrol.enable` escape hatch this bullet used to offer does
  not exist: there is no DIMM reading for it to follow, and no fan for it to
  drive. If the hot run shows warm DIMMs the remaining levers are firmware
  ones — raise the case fans' floor, or back tREFI off.
- **The dGPU while it is bound to vfio-pci with no guest running.** No driver
  manages its fans then. Most cards fall back to a quiet firmware default,
  but some sit at a fixed high speed until a driver loads. Check it in
  [Phase 4](#phase-4--vfio-and-the-libvirt-host). If it is loud, that is a
  host-side fix (let amdgpu hold it idle, as
  [Lending the dGPU](#lending-the-dgpu-to-the-host-on-demand) already allows),
  not a firmware one.
- **Linux visibility — corrected later on 2026-09-24: yes, with the
  out-of-tree driver.** The paragraph below was right about *mainline* and
  wrong about the conclusion. nixpkgs packages the fork as
  `boot.kernelPackages.it87`; built for 6.18.52 and loaded by hand, it reports
  *Found IT8689E chip at 0xa40, revision 2*, then refuses with *ACPI: OSL:
  Resource conflict* — the firmware's own ACPI claims the same ports. With
  `ignore_resource_conflict=1` it binds and reads five PWM channels (all
  `pwm_enable=2`, the firmware's curves), **fan1 1308 RPM at PWM 66/255,
  fan3 7417 RPM at PWM 63/255**, fan2 and fan5 at 0, and six temperatures.
  Switching a channel to manual (`pwm1_enable=1`) took effect; whether a
  written duty cycle actually moves the fan is **unproven** — the write test
  was stopped there, the channel put back to `2`, and the module unloaded.
  (The fork's README warns that some newer Gigabyte boards route fan
  control through a separate chip, where speeds read but writes do nothing.)
  Two reasons it is not in the config: `ignore_resource_conflict` means
  the driver and ACPI share the chip's index/data ports with no locking, and
  the firmware-first reasoning above stands anyway. **What it buys now is
  diagnosis:** fan3 at ~7400 RPM on a 25 % duty is the prime suspect for the
  noise — a small fast fan, or a 3-pin fan on a header in PWM mode.
  *The original finding:* `sensors`
  on the live USB lists **no fan at all** from the board. `sensors-detect`
  finds the ITE chip but reports *"Found unknown chip with ID 0x8689"*, and
  `modprobe it87` fails with `No such device`: mainline's `it87` does not claim
  this ID. So there is no header RPM and no PWM control from Linux, and the
  out-of-tree [`frankcrawford/it87`](https://github.com/frankcrawford/it87)
  fork would be needed to get any. **This does not change the plan** — fan
  curves were already going in the firmware, for the two-OS reason above; it
  removes the fallback rather than the plan. What `sensors` *does* give, and
  what an OS-side curve could drive from if it ever existed: `k10temp`
  (Tctl/Tccd1), both NVMe composites, the MT7922, both `amdgpu`, and
  `gigabyte_wmi` with six unlabelled board temperatures.
- **The DIMMs, concretely.** `spd5118` binds nothing here either — no DIMM
  temperature sensor appears. *Cause found 2026-09-25: the SMBus driver
  (`i2c_piix4`) is refused because ACPI claims its ports for Gigabyte's WMI
  SMBus pass-through, which only Windows tools call.
  [`hosts/desk/sensors.nix`](../hosts/desk/sensors.nix) sets
  `acpi_enforce_resources=lax` with the reasoning; confirm after the next
  reboot with `sensors | grep -A3 spd5118`.* The "under ~55 °C" check in
  [BIOS tuning](#bios-tuning) therefore has to be read from **HWiNFO under
  bare-metal Windows**, not from `sensors` as that section assumes.

**Written down** with the rest: the curve points and each header's mode go in
`hosts/desk/bios.md`, plus Smart Fan 6's own *Save Fan Profile* (F3) to USB,
since the next firmware update resets them too.

#### Fan control checklist

- [ ] Loud source identified: which header, or the GPU / PSU — *suspect: fan3,
      ~7400 RPM at 25 % duty (read via the out-of-tree `it87`, 2026-09-24).
      Match it to a header in Smart Fan 6*
- [ ] Each header's mode matches its fan (PWM for 4-pin, Voltage for 3-pin)
- [ ] Curves set, Temperature Interval raised; quiet at idle and browsing
- [ ] Eco Mode tried; kept or rejected on compile time vs noise — *2026-09-25:
      switchable from NixOS instead of firmware setup: `eco on` / `eco off` /
      `eco status` ([`hosts/desk/eco.nix`](../hosts/desk/eco.nix), ryzen_smu
      with Zen 4's RSMU PPT/TDC/EDC commands). Leave firmware Eco Mode off.
      First use to confirm: `eco status` reads 142/110/170 at stock, `eco on`
      makes it 88/75/150, and an all-core build holds package power near 88 W*
- [ ] Recorded in `hosts/desk/bios.md`; fan profile saved to USB
- [x] Phase 0: fans visible in `sensors` — *not with mainline `it87` (ITE `0x8689` unclaimed); yes with the out-of-tree fork plus `ignore_resource_conflict=1`, read-only in practice (2026-09-24). Curves stay in firmware*; [ ] Phase 4: dGPU fan sane under vfio-pci

---

## Decisions locked in

| Question | Answer | What it rules out |
| --- | --- | --- |
| GPU topology | AMD iGPU → the NixOS desktop, always. dGPU → guest, **lent to the host on demand** for native/Proton games | Single-GPU teardown hooks; the host never goes headless; the compositor ever holding the dGPU |
| Desktop session | niri, à la carte (waybar, swaync, fuzzel, swayidle); getty autologin, no lock; suspend on idle only if Wake-on-WLAN proves reliable | A display manager; a screen locker; a prebuilt shell |
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
| Board / BIOS | Gigabyte **B650I AORUS ULTRA** (mini-ITX), AMI BIOS **F43c** (2026-07-20), flashed 2026-09-23 from F9d (2023-09) | Mini-ITX has **one** x16 slot: "move the card to another slot" is not an IOMMU-gate fallback here. Board is **rev 1.0** (per the box). F43c is the latest for this revision — [Firmware update](#firmware-update) |
| CPU / RAM | Ryzen 5 **7600X**, 6C/12T, **one CCD**; **32 GB** RAM; SVM enabled in firmware | No cross-CCD concern. Phase 5's numbers were written for a 16-core/64 GB box and are now corrected — guest 4C/8T + 16 GiB, host 2C/4T |
| dGPU | **Radeon RX 6600 XT** (Navi 23, RDNA2) `1002:73ff` + HDMI audio `1002:ab28`, Windows PCI bus 3 fn 0/1 | RDNA2: **no `vendor-reset`**. Both IDs are unique on this box, so `vfio-pci.ids` is safe *for the GPU* |
| iGPU | Raphael `1002:164e` | Host graphics; different ID from the dGPU, so the `vfio-pci.ids` match cannot catch it |
| SSDs | **Both SK hynix Platinum P41** (`SHPP41-1000GM`, `SHPP41-2000GM`), both NVMe, controller ID **`1c5c:1959` on both** | (1) There is no fast/bulk split — same drive family, same performance, so the `fio` worry evaporates and [Risk 7](#risks-ranked) is about capacity, not speed. (2) **[Risk 3](#risks-ranked) is confirmed**: `vfio-pci.ids` would take both controllers — and so would a `new_id` write. Bind by PCI address with `driver_override` — [Phase 4](#phase-4--vfio-and-the-libvirt-host) |
| Windows' drive | `C:` is the **2 TB** P41 (Windows disk 1, CPU-attached controller), 1862 GB NTFS, **89 GB free**. Its partitions: MSR, `C:`, WinRE — **no ESP** | Steam is on `C:` (`C:\Program Files (x86)\Steam`, the only library) and stays. 89 GB free is thin but not a blocker |
| The other drive | The **1 TB** P41 (Windows disk 0, chipset controller) is **not empty**: a 1 GB ESP marked System, plus five Linux-filesystem partitions (31 + 244 + 585 + 39 + 31 GB) | **Two plan-breaking facts** — see [The ESP is on the wrong drive](#the-esp-is-on-the-wrong-drive). Those five partitions are an old Linux install — **disposable, no backup needed** (confirmed 2026-09-21) |
| Windows' RTC | `RealTimeIsUniversal = 1` — Windows already keeps the RTC in **UTC** | `time.hardwareClockInLocalTime = true` would *create* the clock fight it was meant to prevent. Removed from `disko.nix`; NixOS's UTC default is correct |
| Fast Startup | Was **on**; `powercfg /h off` run 2026-09-21, `powercfg /a` now reports hibernation not enabled and Fast Startup unavailable | Done. Re-check after feature updates — [Risk 6](#risks-ranked) |
| BitLocker | `manage-bde -status`: C: **Fully Decrypted**, no key protectors | Nothing to do; the guest will boot without a recovery prompt. Watch for Device Encryption re-enabling itself — [Risk 8](#risks-ranked) |
| Secure Boot | `Confirm-SecureBootUEFI` → **False** | Already off. systemd-boot installs without lanzaboote. **F43c turned it back on** — off again is on the [post-flash checklist](#firmware-update) |
| SMBIOS | system/board manufacturer `Gigabyte Technology Co., Ltd.`, product `B650I AORUS ULTRA`, serials `Default string`, UUID `03560274-043C-0547-E806-FF0700080009` | The `<sysinfo>` block in the licensing section can be filled from this (confirm against `dmidecode` in Phase 0 — Windows byte-swaps the first three UUID fields on some firmware) |
| Network | Windows runs on **Wi-Fi** (MediaTek RZ616 / MT7922, MAC `F0:A6:54:14:9B:0D`); the Intel I225-V wired port (`74:56:3C:47:E8:FF`) is **disconnected** | **Decided: Wi-Fi for everything, for now.** See [Networking on Wi-Fi](#networking-on-wi-fi) |
| WSL | Switched onto this repo 2026-09-21: hostname `wsl`, applies `.#wsl` as locked, `/etc/nixos` stubs removed, SSH key comment `n8@wsl` | Done — nothing on the WSL side gates this plan any more |

### Phase 0, Linux side — measured 2026-09-24

From the NixOS 26.05 live USB. Raw output for every row is committed under
[`docs/desktop-inventory/`](./desktop-inventory/); this table is the reading of
it. **The gate passes on both parts** — see
[the verdict](#the-gate--passed-2026-09-24).

| Item | Measured | Consequence for this plan |
| --- | --- | --- |
| IOMMU | **On.** `AMD-Vi: Interrupt remapping enabled`, `Virtual APIC enabled`, default domain type Translated | The firmware's *IOMMU Enabled* stuck. Nothing to change |
| dGPU | **`03:00.0`** (Navi 23 `1002:73ff`, ASRock board `1849:5216`) + **`03:00.1`** HDMI audio (`1002:ab28`), behind the card's own PCIe switch (`01:00.0` → `02:00.0`) | `<DGPU_ADDR>` resolved. Windows' "bus 3" happens to match Linux's, which is luck, not a rule |
| iGPU | **`12:00.0`** Raphael `1002:164e`, on the CPU's internal root complex with `12:00.1` audio, `12:00.2` PSP, `12:00.3/.4` USB, `12:00.6` HD audio | `<IGPU_ADDR>` resolved. Each function sits in its own IOMMU group, so passing the dGPU never disturbs it |
| **2 TB NVMe (Windows `C:`)** | Controller **`11:00.0`**, `nvme1n1`, `SHPP41-2000GM`, serial `ADC8N56931060986L`. **CPU-attached** — it hangs off the CPU root complex next to the iGPU, not off the chipset switch | `<FAST_NVME_ADDR>` resolved. Partitions read back exactly as Windows reported them: MSR 16 M, NTFS 1.8 T, **ESP 300 M labelled `SYSTEM`**, WinRE 909 M. Independent confirmation that [the new ESP](#the-esp-is-on-the-wrong-drive) is real |
| **1 TB NVMe (NixOS-to-be)** | Controller **`06:00.0`**, `nvme0n1`, `SHPP41-1000GM`, serial `SJB8N565511208H0I`. **Chipset-attached**, behind the 600-series PCIe switch | by-id is **`/dev/disk/by-id/nvme-SHPP41-1000GM_SJB8N565511208H0I`** — what `disko.nix` now references. Holds the old Linux install (1 G ESP `boot`, ext4 `root`/`home`, a 585 G ext4, a `fedora_localhost-live` btrfs, another ext4) — all disposable |
| SMART, both drives | `Percentage Used` **1%** each; `Media and Data Integrity Errors` **0**; `Critical Warning` `0x00`. 1 TB: 12,670 power-on hours, 14.4 TB written. 2 TB: 9,352 hours, 27.8 TB written | Neither drive is worn. The bulk drive taking NixOS root *and* the media volume is fine on wear grounds |
| CPU topology | `lscpu -e`: 12 CPUs, 6 cores, **one NUMA node, one 32 MB L3** (`lstopo` agrees). **SMT sibling of CPU *n* is *n*+6** | Phase 5's pinning assumption is confirmed verbatim. No cross-CCD concern, as expected |
| SMBIOS | system + board manufacturer `Gigabyte Technology Co., Ltd.`, product `B650I AORUS ULTRA`, serials `Default string`, board version `x.x`, UUID **`03560274-043c-0547-e806-ff0700080009`** | **The UUID matches Windows byte for byte** — no byte-swap on this firmware, so the `<sysinfo>` block can be copied straight across. See [Keeping activation stable](#keeping-activation-stable-across-the-crossing) |
| BIOS | AMI **F43c**, release date **07/21/2026** | Confirms the flash. (The vendor page says 2026-07-20; the SMBIOS date is a day later. Cosmetic) |
| Network | **`wlp14s0`** — MediaTek MT7922 `14c3:0616` at `0e:00.0`, MAC `f0:a6:54:14:9b:0d`, associated and carrying v4 + v6. Wired `enp13s0` — Intel I225-V `8086:15f3` at `0d:00.0`, MAC `74:56:3c:47:e8:ff`, NO-CARRIER | `<FILL_ME_WLAN_IF>` resolved to `wlp14s0`, which is what the firewall, Samba and CUPS stanzas now name. Both MACs match the Windows-side record |
| **Wake-on-WLAN** | **Supported.** `iw phy` lists `wake up on magic packet`, plus disconnect, pattern match and net-detect | The [Idle](#idle-screens-off-then-suspend--if-the-wi-fi-can-wake-it) residual clears its *firmware/driver* bar. Suspend-on-idle stays on the table; Phase 8 still has to prove it works end to end |
| Fans and DIMM temps | **Invisible to Linux.** `sensors-detect` finds an ITE chip with **ID `0x8689`**, which mainline `it87` refuses (`No such device`). No `spd5118` DIMM sensors. What *is* visible: `k10temp`, both `nvme`, the MT7922, both `amdgpu`, and `gigabyte_wmi` (six unlabelled board temps) | Answers the Phase 0 fan item in the negative — see [Fan control](#fan-control). Fan curves are firmware-only, which was already the plan |
| **Which GPU the firmware posted on** | **The dGPU.** `boot_vga=1` on `0000:03:00.0`, `0` on the iGPU. The one monitor (3440×1440) is on `card1-HDMI-A-1`, the RX 6600 XT's HDMI; every iGPU connector is disconnected with zero-byte EDID | **The one action item out of this pass.** simpledrm claims the dGPU's framebuffer at boot, which is the `BAR 0: can't reserve` failure [Phase 4](#phase-4--vfio-and-the-libvirt-host) warns about, and it contradicts "the iGPU runs the desktop always". Fix is a cable move — [The monitor is plugged into the wrong GPU](#the-monitor-is-plugged-into-the-wrong-gpu) |
| dGPU fan at idle | `amdgpu-pci-0300`: `fan1` **0 RPM**, `pwm1` **0%**, edge 45 °C | The card zero-RPM idles under `amdgpu`. Encouraging for [Phase 4](#phase-4--vfio-and-the-libvirt-host)'s "is the dGPU loud under vfio-pci with no guest" check, but not an answer to it — that is a different driver state |

### The monitor is plugged into the wrong GPU

**Found 2026-09-24, on the live USB. Nothing is broken; a cable has to move
before Phase 4, and the plan's GPU topology depends on it.** The parallel to
[The ESP is on the wrong drive](#the-esp-is-on-the-wrong-drive) is exact: a
physical fact the plan assumed the other way round, cheap to fix, expensive to
discover late.

Evidence, in
[`docs/desktop-inventory/13-boot-gpu.txt`](./desktop-inventory/13-boot-gpu.txt):

| Reading | Value |
| --- | --- |
| `/sys/bus/pci/devices/0000:03:00.0/boot_vga` (dGPU) | **`1`** |
| `/sys/bus/pci/devices/0000:12:00.0/boot_vga` (iGPU) | `0` |
| dGPU connectors | **`card1-HDMI-A-1: connected`** — one 3440×1440 ultrawide. DP-1/2/3 disconnected |
| iGPU connectors | DP-4, DP-5, DP-6, HDMI-A-2 — **all disconnected, all zero-byte EDID** |
| Boot framebuffer | `/dev/dri/by-path/pci-0000:03:00.0-platform-simple-framebuffer.0-card`, then `amdgpu 0000:03:00.0: [drm] fb0` |

So the single display hangs off the **RX 6600 XT**, and the motherboard's video
outputs have nothing in them at all. The firmware posts on the dGPU because,
with no cable on the board, it has nowhere else to post — *whatever* **Initial
Display Output** is set to. That setting selects a preference; it cannot
conjure a monitor onto an empty port.

**Why this matters, in three places:**

1. **It is exactly the `BAR 0: can't reserve` hazard** the
   [post-flash checklist](#firmware-update) and
   [Phase 4](#phase-4--vfio-and-the-libvirt-host) warn about. The boot
   framebuffer above *is* simpledrm holding the card the guest is supposed to
   get. Left as is, the vfio-pci bind fails.
2. **It contradicts the topology decision** — *"AMD iGPU → the NixOS desktop,
   always"*. The desktop cannot run on the iGPU when no monitor is attached to
   it. niri's `render-drm-device "…12:00.0-render"` would render on a GPU
   driving no screen.
3. **It makes the Status entry for the post-flash checklist half-true.** *Initial
   Display Output IGD* was confirmed in firmware setup on 2026-09-23, and that
   is still what the setting says. The machine posts on the dGPU regardless.
   The setting was never the whole requirement; the cable is.

> **Cable moved 2026-09-24. Half-verified; `boot_vga` still pending.**
> The DRM connector state flipped as soon as the cable moved, and that part
> needs no reboot: `card1-HDMI-A-1` on the dGPU went `connected` →
> **`disconnected`**, and `card2-HDMI-A-2` on the iGPU went `disconnected` →
> **`connected`**. So the monitor is now on the motherboard.
>
> **What is still unverified is the thing that actually matters**, because it
> is only decided at POST: `boot_vga` still reads `1` on `0000:03:00.0` for
> *this* boot, and whether the firmware now posts on the iGPU can only be
> answered after a reboot. Until that check passes, treat
> [Phase 4](#phase-4--vfio-and-the-libvirt-host) as still gated and leave
> niri's GPU pinning commented out.
>
> One oddity to re-check at the same time: `card2-HDMI-A-2` reports
> `connected` but its `edid` reads 0 bytes. Probably just that the connector
> is not driven yet — the console framebuffer is still on the dGPU from this
> boot — but a 0-byte EDID on the display you are about to depend on is worth
> confirming rather than assuming.

**The fix: move the display cable from the graphics card to the motherboard.**
The B650I AORUS ULTRA's rear I/O carries the iGPU's outputs, and the kernel
sees four connectors on `12:00.0` — HDMI-A-2 plus three DP (one of which is the
USB-C port's DP alt mode). The monitor is a 3440×1440 ultrawide, which both
HDMI 2.1 and DP 1.4 drive comfortably at that resolution.

**Then verify, and only then is it done** — re-boot the live USB and check
`boot_vga` has moved to `0000:12:00.0`, that `card*-HDMI-A-*` on the iGPU reads
`connected`, and that no `simple-framebuffer` path under
`/dev/dri/by-path/` names `0000:03:00.0`. That last one is the real test: it is
the thing that has to be absent for Phase 4's bind to work.

**A wrinkle worth deciding before Phase 8, not during it:** with the monitor on
the iGPU, the guest's dGPU output has no screen of its own. That is what
[Phase 7](#phase-7--display-input-audio)'s Looking Glass is for, and this plan
already chose it — but it means bare-metal Windows and the guest reach the
display by different routes, and
[lending the dGPU to the host](#lending-the-dgpu-to-the-host-on-demand) becomes
a render-offload story (DRI_PRIME onto the iGPU's screen) rather than a
different-cable story. Both are already how the plan is written. The thing not
to do is leave the cable on the dGPU and hope.

### Still unknown — closed 2026-09-24

All three were answered on the live USB. Raw output under
`docs/desktop-inventory/`; the summary is
[Phase 0, Linux side](#phase-0-linux-side--measured-2026-09-24).

- ~~**IOMMU groups**~~ — **both clean.** The gate passes. dGPU `03:00.0` alone
  in group 14, its HDMI audio `03:00.1` alone in group 15, and the 2 TB NVMe
  controller `11:00.0` alone in group 28.
- ~~**SMART wear**~~ — both P41s at **`Percentage Used` 1%**, zero media errors.
- ~~Linux CPU numbering~~ — `lscpu -e` confirms it: **SMT sibling of CPU *n* is
  *n*+6**, exactly what Phase 5 assumed.

---

## What this buys the repo

*Superseded 2026-09-24: WSL stays, for Linux on bare-metal Windows
([Phase 9](#phase-9--keep-the-wsl-host-for-bare-metal-windows)), so none of
the deletions below happen. The table is kept as the record of what the WSL
host costs to keep.*

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
    --runtime=30 --time_based --group_reporting --filename=/dev/nvme0n1

# 7. OPTIONAL: USB port -> controller map. Only needed if Phase 7 ever falls
#    back to passing a whole USB controller, which must not be the printer's
#    (see Printer sharing). Cheap to record while the live USB is up.
lsusb -t
for b in /sys/bus/usb/devices/usb*; do
  printf '%s -> %s\n' "${b##*/}" "$(basename "$(readlink -f "$b/..")")"
done
```

### The gate — **PASSED**, 2026-09-24

Run from the live USB; raw output in
[`docs/desktop-inventory/04-iommu-groups.txt`](./desktop-inventory/04-iommu-groups.txt).
Both parts are clean, and cleaner than this plan dared assume: **this board
gives almost every endpoint its own IOMMU group.**

| | Device | Group | Group contains | Verdict |
| --- | --- | --- | --- | --- |
| Part 1 | dGPU `03:00.0` (Navi 23) | **14** | that function, alone | **Clean** |
| Part 1 | dGPU HDMI audio `03:00.1` | **15** | that function, alone | **Clean** |
| Part 2 | 2 TB NVMe controller `11:00.0` | **28** | that controller, alone | **Clean** |

Three things worth recording, because they are what make the verdict safe:

- **The GPU's two functions are in *separate* groups** (14 and 15), not one
  shared group. Both still go to the guest — each group is passed in full, and
  each contains only its own function. Nothing the host needs is dragged along.
- **The 2 TB controller is CPU-attached**, on its own, while the 1 TB controller
  (`06:00.0`) sits in group 17 **together with** the chipset switch's downstream
  port `05:00.0`. The right drive got the clean group. Had it been the other way
  round, the whole VFIO-the-controller design would have needed the
  block-device fallback below. It was not luck that it landed this way — the
  CPU-attached slot was [called as the likelier one](#still-unknown--closed-2026-09-24) —
  but it was not guaranteed either.
- **Group 17's extra member is a PCIe bridge, not an endpoint**, and it belongs
  to the drive the *host* keeps. It would not have blocked passthrough even if
  the drives were swapped — bridges are not assigned to a guest — but that is
  moot now.

So: **no `pcie_acs_override`, no moving cards between slots, no block-device
fallback.** Phase 4's `driver_override` binding of `0000:11:00.0` is exactly
right, and [Risk 3](#risks-ranked) (an ID match taking both controllers) stays
handled by binding the address rather than the ID — both controllers really do
report `1c5c:1959`, as Windows warned.

The original gate, kept for the record:

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

- [x] **The gate** — *both parts clean, 2026-09-24. See
      [the verdict](#the-gate--passed-2026-09-24)*
- [x] `nixos-generate-config --no-filesystems --show-hardware-config` from the
      live USB → this is `hosts/desk/hardware-configuration.nix` — *generated
      2026-09-24 into
      [`docs/desktop-inventory/hardware-configuration.nix`](./desktop-inventory/hardware-configuration.nix);
      Phase 1 moves it to `hosts/desk/`. It is short and unsurprising:
      `kvm-amd`, the AMD microcode line, and `nvme xhci_pci ahci usbhid
      usb_storage sd_mod` in initrd*
- [x] Record `/dev/disk/by-id/` names for every drive (by-id, not `/dev/nvme0n1` —
      by-id is stable across reboots and is what disko should reference) —
      *bulk = `/dev/disk/by-id/nvme-SHPP41-1000GM_SJB8N565511208H0I`, already
      substituted into `disko.nix` below. The 2 TB is
      `nvme-SHPP41-2000GM_ADC8N56931060986L`, which disko must never name*
- [x] `smartctl -a` each SSD: model, capacity, and the wear indicator
      (`Percentage Used` on NVMe). The bulk drive now holds NixOS root as well
      as the media volume, so its wear matters more than it used to — *both at
      **1%**, zero media errors; the bulk drive has 12,670 power-on hours and
      14.4 TB written. No wear objection to the shared-volume plan*
- [x] `ip link`, `iw phy`, `lscpu -e`, `dmidecode`, `sensors` — *2026-09-24, all
      in the [Linux-side table](#phase-0-linux-side--measured-2026-09-24)*
- [ ] Inventory the game library: which titles, and what ProtonDB says about
      each. Every title that runs native under Proton is a title neither boot
      mode has to serve
- [x] Record how much free space the fast drive has — *89 GB free on the 2 TB
      `C:`; Steam's only library is on `C:` and stays there*
- [x] **Update the motherboard firmware** (F9d → latest for the board
      revision) before the Linux pass — *F43c, 2026-09-23* — [Firmware update](#firmware-update)
- [x] **Give Windows its own ESP on the 2 TB drive** and prove it boots —
      *created 2026-09-21; booted, WinRE re-registered, and activation
      confirmed 2026-09-23* —
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
so they go on the unmanaged-state list in [Phase 9](#phase-9--keep-the-wsl-host-for-bare-metal-windows)
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

> **Done, 2026-09-24** — from the live USB rather than the WSL box, which works
> just as well since the phase touches no hardware. `.#desk` evaluates and
> `.#wsl` is undisturbed. See
> [What Phase 1 actually landed](#what-phase-1-actually-landed--2026-09-24) at
> the end of this section for the file list and the checks that were run. The
> rest of this section is the design it was built from.

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
  desktop.nix                 # niri, autologin, PipeWire, fonts, Chrome, keyring, WoWLAN
  ancs.nix                    # Bluetooth + ancs4linux (iPhone notifications)
  pkgs/ancs4linux.nix         # not in nixpkgs; pinned by rev + hash
  gaming.nix                  # steam, gamemode, mangohud, native-Proton side
  vfio.nix                    # IOMMU, vfio-pci binding (dGPU + fast NVMe), kvmfr
  dgpu.nix                    # `dgpu host|vm`: lend the dGPU to the host on demand
  libvirt.nix                 # libvirtd, OVMF, swtpm, the NixVirt domain
  perf-hook.nix               # the while-the-VM-runs tuning (§5)
  secure-boot.nix             # lanzaboote (Phase 2b) — added after the install
  media.nix                   # Samba, btrfs scrub, restic (Media storage)
  windows/                    # the DSC profile Windows pulls and applies (§6)
  home/                       # host-only home modules
    desktop.nix               # waybar, swaync, fuzzel, swayidle, the niri-session exec
    niri.kdl                  # niri's config; `niri validate` runs as a flake check
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

- [x] Move `tailscaled-wsl-rebind` out of `modules/nixos/tailscale.nix` and into
      `hosts/wsl/`. Do it as its own commit, before adding `desk`, so the diff
      that adds the host is not also a refactor. — *done 2026-09-24:
      `hosts/wsl/tailscale-rebind.nix`; `.#wsl`'s toplevel drvPath is
      unchanged by the move*

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

- [x] Add `desk` to the "Evaluate every host" step in
      `.github/workflows/update-flake-lock.yml`, next to `wsl` — the weekly
      lock bump gates only the hosts it is told about. — *done 2026-09-24*

### What Phase 1 actually landed — 2026-09-24

**The installable base, and nothing beyond it.** `.#desk` evaluates, which is
all Phase 1 promised; Phase 2 can install from it as it stands. Committed:

| File | What it carries |
| --- | --- |
| `hosts/desk/default.nix` | hostname, `system.stateVersion = "26.05"`, imports of `modules/nixos` + the two below, **systemd-boot** and `canTouchEfiVariables`, NetworkManager + redistributable firmware for the MT7922, and `networkmanager` on the user |
| `hosts/desk/hardware-configuration.nix` | moved out of `docs/desktop-inventory/`, where Phase 0 generated it |
| `hosts/desk/disko.nix` | the bulk drive only, exactly as specified above |
| `flake.nix` | the `disko` and `NixVirt` inputs, and `nixosConfigurations.desk` |
| `.github/workflows/update-flake-lock.yml` | `desk` joins the eval gate |

Verified on the live USB, not assumed:

- `.#desk` evaluates → `nixos-system-desk-26.11.20260920.44a9189.drv`.
- **`.#wsl` still evaluates** — the new inputs do not disturb it.
- disko generated all four `fileSystems`: `/` (ext4, `disk-bulk-root`), `/boot`
  (vfat, `umask=0077`, `disk-bulk-ESP`), and `/srv/media` + `/srv/games` as
  `subvol=` mounts on `disk-bulk-media`. That is the check worth doing, because
  it is the half of disko `nixos-install` depends on and the half a destroy run
  does not exercise.
- **`disko.devices.disk.bulk.device` resolves to the 1 TB drive**, not the 2 TB
  Windows one.
- `boot.loader.grub.enable` is `false` and systemd-boot `true` — the failure
  Phase 2 would otherwise hit with the drive already wiped.
- `time.hardwareClockInLocalTime` is `false`, as Phase 0 requires.
- Lock: disko `725ea35` (2026-09-18), NixVirt `0.6.0` (2025-05-25).

**Deliberately not landed yet**, because they belong to the phases that
configure them, and a module nothing enables is a module nothing tests:
`desktop.nix` (niri), `gaming.nix`, `vfio.nix`, `dgpu.nix`, `libvirt.nix`,
`perf-hook.nix`, `media.nix`, `ancs.nix`, `secure-boot.nix`. The file tree
above is the target layout, not Phase 1's deliverable. `NixVirt`'s module *is*
imported already — it defines nothing until `virtualisation.libvirt` is
enabled, and adding a flake input mid-install is the thing worth avoiding.

**Consequence for Phase 2: the freshly installed machine has no desktop.** It
boots to a TTY with NetworkManager, SSH, Tailscale and Docker. That is enough
for `nmtui`, `tailscale up`, the `git clone` and the `nixos-rebuild switch`
loop Phase 2 ends with — which is how the desktop arrives.

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

##### WinRE after moving the ESP

**WinRE registration has to be redone after the first boot from the new ESP.**
`reagentc` writes to the BCD of the ESP Windows *booted from*, and the run above
happened while that was still the old one. Once `Get-Partition | ? IsSystem`
reports disk 1 partition 3, re-register WinRE in the new BCD.

The plain `reagentc /disable; reagentc /enable` does **not** do it. What
happened on 2026-09-23: `/disable` reported WinRE already disabled, `/enable`
failed with `Operation failed: 2`, and `/info` showed a BCD identifier but no
location. The cause is `C:\Windows\System32\Recovery\ReAgent.xml`, which still
held `<WinreBCD id="{8aa2fce2-…}"/>` — the WinRE loader in the *old* ESP's BCD.
`bcdboot` built the new BCD without that object, but carried over boot-loader
`recoverysequence` values pointing at it, so
`bcdedit /enum all | Select-String <id>` printed `recoverysequence` lines and no
`identifier` line: a dangling reference. `/enable` looks for the object, finds
nothing, and fails. `Winre.wim` itself was intact in
`C:\Windows\System32\Recovery`, where `/disable` leaves it.

The fix is to blank the stale ID so `/enable` creates a fresh loader:

```powershell
$x = 'C:\Windows\System32\Recovery\ReAgent.xml'
Copy-Item $x "$x.bak"
$s = [IO.File]::ReadAllText($x) -replace '<WinreBCD id="\{[^}]*\}"/>', '<WinreBCD id=""/>'
[IO.File]::WriteAllText($x, $s, (New-Object Text.UTF8Encoding $false))  # no BOM, as found
reagentc /enable; reagentc /info
```

`/enable` moves `Winre.wim` (815 MB) back onto the 909 MB WinRE partition,
creates a new WinRE loader, and points `{current}`'s `recoverysequence` at it.
`bcdedit /enum osloader` should then show exactly two loaders: `{current}` and
"Windows Recovery Environment".

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
    device = "/dev/disk/by-id/nvme-SHPP41-1000GM_SJB8N565511208H0I";
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

### Seed the install before rebooting

```sh
sudo bash /path/to/nix-config/scripts/seed-install.sh
```

**Run this after `nixos-install` and before the reboot**, while `/mnt` is still
mounted and the live session still holds the credentials. It copies onto the
target the four things a public repo cannot carry:

| | Where it lands | Why it cannot be declarative |
| --- | --- | --- |
| The Wi-Fi profile | `/etc/NetworkManager/system-connections/` (600, root) | Contains the PSK. NetworkManager keeps profiles as mutable state, so copying the file *is* the whole job, and it already pins `interface-name=wlp14s0` — the same NIC |
| This repo | `~/natb1/nix-config` | `nixos-install` copies the store closure, not the working tree. Seeding the tree rather than cloning means the branch and anything unpushed come along, and first boot needs no network to start work |
| `~/.claude`, `~/.claude.json` | `~` | A session token. **Not** managed by home-manager — checked, it appears nowhere in `home.file` — so nothing contests it |
| `~/.config/gh/hosts.yml` | `~/.config/gh/` | The gh token. **Only `hosts.yml`:** `config.yml` *is* managed by `modules/home/gh.nix`, so copying that one would just be backed up and replaced on the first switch |

**No secret is in the script.** It is a list of copy operations; the values are
read out of the running live session and written only to the target disk, so
credentials go from RAM to the new drive without passing through git.

Three things it gets right that are easy to get wrong, the first two found by testing it
against a fake target rather than during an install:

- **The user's uid comes from `$TARGET/etc/passwd`, not from assuming 1000.**
  NixOS allocates it during activation. Guessing wrong yields a home directory
  the user cannot write to — which, with autologin straight into niri, is a
  baffling first boot rather than an obvious error.
- **The source home is the *invoking* user's, not root's.** The script needs
  root to write to `/mnt`, and under `sudo` `$HOME` is `/root`, where none of
  the credentials live. The first version of this script exited 0 having
  seeded nothing, reporting each credential as "not present". It now resolves
  `SUDO_USER`'s home, and warns loudly at the end if any credential was not
  found.
- **Every directory it creates belongs to the user, not only the last one.**
  `install -d -o` applies the owner to the final path component alone; the
  first version seeded `.config/gh/hosts.yml` that way and left `~/.config`
  owned by root, so the first switch failed in `home-manager-n8.service` with
  `mkdir: cannot create directory '/home/n8/.config/…': Permission denied`.
  This one was found during the install, not by the fake-target test — which
  pre-created the home and never checked the intermediate directories.

After this, the first boot associates to Wi-Fi on its own and
`cd ~/natb1/nix-config && sudo nixos-rebuild switch --flake .#desk` works
immediately, with no `nmtui`, no clone and no browser logins.

**`nixos-install` ends by prompting for a root password. Set one.** It is the
break-glass for single-user mode if `hosts/desk/` ever stops evaluating. Day
to day it is unused: `n8` has passwordless sudo, for the reason recorded in
`hosts/desk/default.nix` — this repo sets no password for anybody, because
NixOS-WSL arranged its own and nothing here ever had to. On a native host that
inheritance does not apply, and without `security.sudo.wheelNeedsPassword =
false` the freshly installed machine autologins into a desktop where `sudo`
and `su` both prompt for passwords that do not exist. Caught by evaluation
before the install rather than after it; the recovery would have been a live
USB and a chroot.

Then reboot and **verify both boot paths before going further**, while the live
USB is still plugged in:

- [x] NixOS boots from the bulk drive — *booted 2026-09-24. The first boot
      reached only a login prompt (two session bugs, fixed in `249427c`); the
      reboot after that came up in niri on its own*
- [ ] Windows still boots bare metal from the firmware boot menu, and is still
      activated (Settings → System → Activation). Nothing should have changed —
      confirming that is the point
- [ ] Clocks agree after crossing between them — both sides keeping the RTC in
      UTC (`RealTimeIsUniversal = 1` on Windows, the default on NixOS)
- [x] `efibootmgr -o` puts systemd-boot first, so NixOS is the default and
      Windows is the deliberate choice — *already the case after install:
      `BootOrder: 0000,0002,0001,0005`. The stale `Boot0004` for the wiped
      1 TB ESP was removed with `efibootmgr -b 0004 -B`*

Then `sudo tailscale up`, `git clone` the repo to `~/natb1/nix-config`, and from
there it is the same `nixos-rebuild switch --flake .#desk` loop as every other
host.

- [x] Add a `desk` row to the README's host table with its rebuild command —
      *done 2026-09-24, same as item 8 of the after-the-reboot list*

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

**Blocked on [BIOS tuning](#bios-tuning)'s memory steps** (decided
2026-09-24), as well as on [item 4](#after-the-reboot--do-these-in-order).
Memory tuning is the step most likely to end in a CMOS clear, and a CMOS clear
after 2b wipes the enrolled keys too — see
[Why the ordering matters](#why-the-ordering-matters-here).

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

*Landed 2026-09-24 as [`hosts/desk/gdrive.nix`](../hosts/desk/gdrive.nix):* a
user unit running `rclone mount gdrive: /mnt/g --vfs-cache-mode full`
(`Type=notify`, `Restart=on-failure` every 30 s, cache capped at 20 G on the
root filesystem), with `/mnt/g` created n8-owned by tmpfiles so the WSL path
carries over. The system build is checked; the switch and the OAuth are yours,
because the token cannot go in this public repo:

```sh
sudo nixos-rebuild switch --flake ~/natb1/nix-config#desk
rclone config          # n → gdrive → drive → scope "drive" → defaults → auto config: yes
systemctl --user start gdrive
ls /mnt/g && touch /mnt/g/.desk-write-test && rm /mnt/g/.desk-write-test
```

Until `~/.config/rclone/rclone.conf` exists the unit is *skipped* by a
condition, not failed. After that, a broken remote fails it visibly.

- [x] `rclone config` done; `systemctl --user status gdrive` active; `/mnt/g`
      lists Drive and takes a write — *2026-09-24. Configured with
      `rclone config create gdrive drive scope=drive`, which does the OAuth
      without the menus. The mount lists Drive; a file written under `/mnt/g`
      showed up on `rclone lsf gdrive:` within seconds, and deleting it removed
      it there too*
- [x] **Own OAuth client ID for the `gdrive` remote** — *done 2026-09-24: a
      Desktop-app client in the Google Cloud project `nix-config-509614`, set
      with `rclone config update gdrive client_id=… client_secret=…` and
      re-authorised with `rclone config reconnect gdrive: --auto-confirm`. The
      shared-client warning is gone, and a write and a delete through `/mnt/g`
      both reached Drive again. The app is **published** (In production), so
      the refresh token does not hit Testing mode's 7-day expiry, and the
      downloaded `client_secret_*.json` has been deleted — `rclone.conf` is
      the only copy of the secret outside Google Cloud.* If the token ever
      does expire (`invalid_grant`), `rclone config reconnect gdrive:`.
- [x] **`rclone.conf` encrypted, password in gnome-keyring** — *2026-09-24.*
      The refresh token gives full access to Drive, and this host has no disk
      encryption and no screen lock, so, like Chrome's passwords, it sits
      behind the keyring. A random 43-character password is stored under
      `service=rclone`, and the unit and interactive shells get it through
      `RCLONE_PASSWORD_COMMAND` (`secret-tool lookup`). The unit now starts
      with the graphical session, because a locked keyring can only be
      unlocked through its prompt. Verified: rclone reads Drive with the
      command and refuses the config without it. Recorded on the README's
      unmanaged-state list; deliberately not backed up
      The original task, for reference: rclone
      warns on every call that the remote uses its *shared* Google Drive
      client ID, which "is being retired and will stop working during 2026".
      When it goes, the mount stops. Create a client ID in a Google Cloud
      project ([rclone's steps](https://rclone.org/drive/#making-your-own-client-id)),
      then `rclone config update gdrive client_id=… client_secret=…` and
      re-authorise with `rclone config reconnect gdrive:`. The ID and secret
      are credentials: `rclone.conf` only, never this repo. The same remote
      feeds [Media storage Step 3](#step-3--bring-the-media-in), so fix it
      before that pull starts

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
  they never reach `desk`, and stay with `hosts/wsl/`
  ([Phase 9](#phase-9--keep-the-wsl-host-for-bare-metal-windows)).
- `wezterm-mux-server` — **keep**. It is still how the Mac gets a persistent
  remote session into this box, and its `stdenv.hostPlatform.isLinux` guard is
  now correct by design.
- The Tailscale `ssh_domains` auto-discovery — **keep**, unchanged. It picks up
  `desk` for free.
- The Windows branches of the shared Lua (`wsl.exe` tailscale invocation,
  `//wsl$/NixOS/...` identity-file paths) — **keep**: WSL stays
  (Phase 9, decided 2026-09-24), and its Windows WezTerm reads this config.

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
`modules/home/wezterm-pin.nix` stay with the WSL host, which stays (Phase 9,
decided 2026-09-24) — the rest of this section was written when they were
going away. So does the mirroring
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

## The desktop session

Decided 2026-09-23. Like media storage, this needs only Phases 1–2, and it is
what you will touch every day, so it lands with the install rather than after
the VM work. Every choice below is about one machine that is both a desktop
and a small always-on server (Samba, CUPS, restic, the mux server, sometimes
the guest). Where those two jobs conflict, the section says which one won.

### Components

niri is a compositor and nothing else, so the rest is chosen piece by piece.
Each piece is small, in nixpkgs, and configured in this repo, so replacing one
never touches the others.

| Job | Choice | Why this one |
| --- | --- | --- |
| Compositor | **niri** (`programs.niri.enable`, nixpkgs) | Scrolling tiling. The nixpkgs module is enough, so there is no new flake input |
| niri config | `hosts/desk/home/niri.kdl`, **validated at build** | A flake check runs `niri validate -c` on it, so a typo fails `nix flake check`, not the next login |
| Login | **getty autologin** on tty1, `exec niri-session -l` from the login shell | No display manager to configure or break. The cost, accepted: a niri crash drops tty1 to a shell |
| Screen lock | **None** | Decided: nothing sensitive is protected by the session. It sits behind its own encryption |
| Bar | **waybar** | niri workspaces, tray (Steam, Tailscale, blueman), clock, a swaync button |
| Notifications | **swaync** | Pop-ups, plus a history panel and do-not-disturb. The panel matters once a phone is forwarding everything ([ANCS](#iphone-notifications-over-ancs)). Action buttons are drawn, so a notification's actions are clickable |
| Launcher | **fuzzel** | Wayland-native. niri's default config already binds it |
| Idle | **swayidle** | Screens off, then the guarded suspend ([Idle](#idle-screens-off-then-suspend--if-the-wi-fi-can-wake-it)). It honours Wayland idle inhibitors, so a playing video holds it off |
| Secrets | **gnome-keyring** (Secret Service) | What Chrome and most apps expect. Locked at boot (autologin has no password to unlock it with), and it asks for its own password on first use |
| X11 apps | **xwayland-satellite** on `PATH` | niri has no built-in Xwayland and starts this on demand. Steam needs it |
| Portals | `xdg-desktop-portal-gnome` + `-gtk` | Screen sharing and file pickers. The niri module wires these, so there is no choice to make |
| Polkit agent | `polkit_gnome`, as a user service | virt-manager and friends ask for elevation through it |
| Bluetooth / audio / Wi-Fi UI | blueman, pwvucontrol, `nmtui` | Bluetooth is new on this host, for ANCS |
| Screenshots | niri's built-in | Nothing to add |

### Autologin, no lock

```nix
# hosts/desk/desktop.nix
programs.niri.enable = true;
services.getty.autologinUser = "n8";
services.getty.autologinOnce = true;   # tty1, once per boot. Log out and you get a login prompt, not a loop
services.gnome.gnome-keyring.enable = true;
environment.systemPackages = with pkgs; [ xwayland-satellite fuzzel wl-clipboard pwvucontrol ];
```

```nix
# hosts/desk/home/desktop.nix. Only tty1 starts niri. SSH logins and tty2 get a plain shell.
programs.zsh.profileExtra = ''
  if [ -z "$WAYLAND_DISPLAY" ] && [ "$XDG_VTNR" = 1 ] && [ -z "$NIRI_SESSION_STARTED" ]; then
    export NIRI_SESSION_STARTED=1
    exec niri-session -l
  fi
'';
xdg.configFile."niri/config.kdl".source = ./niri.kdl;
```

**`-l` is not optional here.** With no arguments, `niri-session` assumes a
display manager started it and re-execs itself through a login shell to pick up
the profile. That profile is this block, which execs `niri-session` again — a
loop that never reaches `niri.service`, spins tty1 at 50% CPU, and leaves the
screen on `desk login: n8 (automatic login)`. `-l` tells the script it is
already in a login shell. `NIRI_SESSION_STARTED` is the second guard: it
survives an exec, so it breaks the loop even if that flag ever changes meaning.

**Chrome must be told where the keyring is.** Chrome picks its password store
by guessing the desktop from `XDG_CURRENT_DESKTOP`. It does not recognise
`niri`, so it falls back to `basic`, which keeps saved passwords and cookie
keys **on disk with a hard-coded key**. That would quietly defeat the "secondary
encryption" this setup relies on. Pin it:

```nix
(google-chrome.override { commandLineArgs = "--password-store=gnome-libsecret"; })
```

`gpg.nix`'s curses pinentry is unaffected: it runs inside WezTerm as it did
on WSL.

### niri and the two GPUs

niri must render on the iGPU and **never open the dGPU**, even while the dGPU
is [lent to the host](#lending-the-dgpu-to-the-host-on-demand). A compositor
that holds a card's DRM node pins it, and the card cannot go back to vfio-pci
until the compositor exits: in effect, starting the VM would mean logging out.
When the dGPU is lent it appears as a new DRM device (hotplug), and niri opens
new devices unless told not to:

```kdl
// hosts/desk/home/niri.kdl
debug {
    render-drm-device "/dev/dri/by-path/pci-0000:12:00.0-render"
    ignore-drm-device "/dev/dri/by-path/pci-0000:03:00.0-render"
}
```

Both are `debug` options, so check them against the niri wiki for the
pinned version. If `ignore-drm-device` does not accept a `by-path` symlink,
use the node the dGPU gets when lent (`/dev/dri/renderD129`-shaped) and add
a udev rule that makes the name stable. Phase 8 proves that niri stays off
the card, whichever form it takes.

**The monitors hang off the motherboard's outputs** (the iGPU), which is also
what Initial Display Output: IGD assumes. Games rendered on a lent dGPU reach
them by PRIME render offload: rendered on the dGPU, copied to the iGPU for
display. That copy costs a few percent, and it is the price of never having
to log out to start the VM.

### Idle: screens off, then suspend — if the Wi-Fi can wake it

Decided: try suspend, with Wake-on-WLAN as the way back. If that proves
unreliable, fall back to screens off and never suspend. The two jobs conflict
most here: a sleeping desktop saves power, but a sleeping server is not a
server.

**First gate cleared, 2026-09-24.** `iw phy` on the live USB lists
`WoWLAN support` with **`wake up on magic packet`** — plus wake on disconnect,
pattern match (1 pattern, 1–128 bytes) and net-detect (10 match sets). So the
MT7922's driver advertises what this design needs, and suspend is worth
trying rather than dead on arrival. That is a *capability* check and nothing
more: it says the feature exists, not that this card, this firmware and AM5's
s2idle resume cleanly together. The Phase 8 bar below is still the real test.

```nix
# hosts/desk/home/desktop.nix
services.swayidle = {
  enable = true;
  timeouts = [
    { timeout = 600; command = "${pkgs.niri}/bin/niri msg action power-off-monitors"; }
    # Delete this entry to fall back to "screens off, never suspend".
    { timeout = 900; command = "${idleSuspend}";
      resumeCommand = "${pkgs.procps}/bin/pkill -f desk-idle-suspend"; }
  ];
};
```

`idleSuspend` does not suspend blindly. It waits until nothing needs the
machine awake, and the `resumeCommand` kills it the moment you touch a key,
so it can never suspend under you:

```sh
# desk-idle-suspend, runs as n8. virsh, not a libvirt hook, so the
# no-calling-libvirt-from-a-hook rule does not apply.
busy() {
  virsh -c qemu:///system domstate win 2>/dev/null | grep -qx running && return  # suspend + VFIO = no
  fuser -s /dev/dri/by-path/pci-0000:03:00.0-* 2>/dev/null && return      # a game on the lent dGPU; gamepad input is not "activity"
  systemctl is-active --quiet restic-backups-media.service && return
  [ -n "$(lpstat -o)" ] && return                                               # queued print jobs
  [ -n "$(ss -Htn state established '( sport = :445 or sport = :22 )')" ] && return  # SMB client, SSH / the Mac's mux session
  return 1
}
while busy; do sleep 60; done
systemctl suspend
```

The way back:

```nix
# hosts/desk/desktop.nix. Applies to every Wi-Fi connection, including the
# hand-provisioned one.
networking.networkmanager.settings.connection."wifi.wake-on-wlan" = "magic";
```

- **Magic packets come from the LAN only.** From the Mac on the same Wi-Fi:
  `wakeonlan f0:a6:54:14:9b:0d`. Over the tailnet there is nothing to send
  one: a sleeping `desk` is simply offline to Tailscale, Samba, CUPS and the
  mux server until something on the LAN wakes it. This is the real cost of
  suspending, and the reason the fallback exists.
- **The nightly backup wakes the machine itself**: the restic timer has
  `WakeSystem = true`, so the RTC wakes it, restic runs, and swayidle suspends
  it again after 15 idle minutes.
- **Wake source:** AM5 has no firmware switch for PCIe wake (see the
  [firmware checklist](#firmware-update)), so the Wi-Fi card's
  `power/wakeup` must read `enabled` in sysfs, and its root port must be
  enabled in `/proc/acpi/wakeup`. If the magic-packet test fails, check
  there first.
- **No Bluetooth wake.** The iPhone would wake the desk every time it got a
  notification.

**The bar for keeping suspend**, tested in Phase 8: 10 of 10 suspend/resume
cycles come back clean (Wi-Fi reassociates, Tailscale reconnects, no amdgpu
or mt7921e errors in `journalctl -k -b`), and 5 of 5 magic packets from the
Mac wake it. Anything less, delete the second timeout and write down why here.
Both the MT7922's WoWLAN and AM5's s2idle have mixed track records on
Linux, so the bar is set to catch exactly those.

### iPhone notifications over ANCS

**Landed 2026-09-24 with [Tether](https://github.com/zackb/tether), not
ancs4linux** — [`hosts/desk/iphone.nix`](../hosts/desk/iphone.nix). ancs4linux's
README now says its author no longer uses it and points to Tether, which is
actively developed, ships a NixOS module (a flake input, pinned by rev in the
URL so the weekly bump leaves it alone), and does the same ANCS mirroring plus
SMS/iMessage read and reply and contacts (MAP/PBAP). No iPhone app is needed for
any of that; Tether's iOS app only does its Wi-Fi features (clipboard, files),
which stay off because they would need a LAN port and mDNS. Notifications go
through libnotify, so swaync draws them as planned.

What Tether costs, all machine-wide:

- `bluetoothd` runs with `Experimental = true` — BlueZ's bearer API, which ANCS
  needs. It must be on **before** pairing: a bond made without it has no LE
  half and never carries notifications. BlueZ here is 5.87 (≥ 5.86 required).
- `desk` presents as Class of Device **Hands-Free** (`tether-btclass@hci0`),
  the only class iOS offers the notification and contacts permissions to.
- WirePlumber's `bluez5.roles` is cut to `a2dp_source bap_source hfp_ag`
  (Tether's recommendation), so a bonded phone does **not** route its calls,
  music or system sounds to `desk`. Headphones are unaffected.

Two surprises from the first switch, both fixed in `iphone.nix`:

- **`tetherd` lost a race with `bluetoothd`.** It checks for `org.bluez` once at
  start. The switch restarted `bluetoothd` a second later, and Tether sat with
  *"Bluetooth unavailable; messages and notifications are disabled"* until
  restarted. A user unit cannot order after a system one, so `tetherd` now
  waits (up to 60 s) for the bus name before starting.
- **Its Wi-Fi half has no off switch.** `programs.tether.wifi` only configures
  avahi and the firewall; `tetherd` itself always listens on `[::]:5134` and
  publishes `_tether._tcp` over mDNS. It was reachable from the whole tailnet
  (tailscale0 is trusted) and advertised on Wi-Fi. Now fenced from outside:
  avahi's `publish.userServices` is off on `desk` (only Tether used it —
  `desk.local` still resolves), and 5134 is dropped on `tailscale0` ahead of
  the trusted-interface accept.

**Pairing, once, after the switch:** `tether --bt-status` should report full
mode (MAP + PBAP + ANCS). Then pair from the GTK app (`tether-gtk`, Devices) or
`tether --bt-pair <phone address>`; on the iPhone, allow **Show Notifications**
and **Sync Contacts** when asked. `tether --bt-setup` prints anything still
missing. The bond is in `/var/lib/bluetooth` and Tether's settings in
`~/.config/tether`, both unmanaged state (README).

*The ancs4linux design below is kept for the record; its expectations about
range, sleep and one-way flow still hold.*

A use case today: iPhone notifications on the desktop.

iOS does not let apps read other apps' notifications, so KDE Connect and its
kin cannot forward them from an iPhone. The one route Apple allows is **ANCS**
(Apple Notification Center Service), the Bluetooth LE service smartwatches
use. The desktop pairs with the phone as an accessory, and the phone streams
every notification to it: app, title, body, and the notification's
positive/negative actions.

**`ancs4linux`** implements the Linux side on top of BlueZ. It has three parts:
an observer and an advertising service on the system bus (root, talking to
BlueZ), and a desktop-integration user service that turns what the observer
sees into ordinary `org.freedesktop.Notifications` calls. **swaync** is what
draws those notifications. The other parts of this desktop never know the
phone exists.

```nix
# hosts/desk/ancs.nix
{ pkgs, ... }:
let
  ancs4linux = pkgs.callPackage ./pkgs/ancs4linux.nix { };  # buildPythonApplication, pinned rev + hash
in
{
  hardware.bluetooth = { enable = true; powerOnBoot = true; };  # MT7922's BT half; firmware via enableRedistributableFirmware
  services.blueman.enable = true;
  services.dbus.packages = [ ancs4linux ];                       # its system-bus policy
  environment.systemPackages = [ ancs4linux ];                   # ancs4linux-ctl, for pairing

  systemd.services.ancs4linux-observer = {
    wantedBy = [ "bluetooth.target" ];
    after = [ "bluetooth.service" ];
    serviceConfig.ExecStart = "${ancs4linux}/bin/ancs4linux-observer";
  };
  systemd.services.ancs4linux-advertising = {
    wantedBy = [ "bluetooth.target" ];
    after = [ "bluetooth.service" ];
    serviceConfig.ExecStart = "${ancs4linux}/bin/ancs4linux-advertising";
  };
  systemd.user.services.ancs4linux-desktop-integration = {
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig.ExecStart = "${ancs4linux}/bin/ancs4linux-desktop-integration";
  };
}
```

Take the unit names and flags from upstream's autorun files at the pinned
revision, not from this sketch. It is a small, lightly maintained project, so
treat it as experimental. The package pins it by rev and hash, the same
lesson as [WezTerm's Windows GUI pin](#wezterms-windows-gui-pin).

**Pairing, once:** `ancs4linux-ctl enable-advertising` (with the adapter's
address and the name `desk`). On the iPhone, open Settings → Bluetooth → `desk`,
pair, and allow **Share System Notifications** when asked. Then disable
advertising. The bond lives in `/var/lib/bluetooth`, so it is unmanaged state
([Phase 9](#phase-9--keep-the-wsl-host-for-bare-metal-windows)).

What to expect:

- **Range-bound.** BLE, roughly the room. When the phone leaves, nothing
  arrives. When it comes back, the observer should reconnect by itself, and
  Phase 8 checks that it does.
- **Only while NixOS runs.** The Bluetooth adapter stays with the host, the
  same rule as the printer ([Keep the printer on the host](#keep-the-printer-on-the-host)):
  it is never redirected to the guest, so ANCS keeps working while `win` runs.
  Bare-metal Windows has no ANCS. Phone Link can do it there, but that is out
  of scope.
- **Not while asleep.** No Bluetooth wake, by design (above).
- **Actions.** ANCS lets the desktop answer a notification with its positive
  or negative action, which in practice mostly means dismissing it on the phone. Whether
  ancs4linux exposes them as notification actions is to be confirmed. swaync
  draws whatever actions arrive.
- **One-way otherwise.** Dismissing in swaync does not clear the phone unless
  that action exists, and nothing flows desktop → phone. That is the
  [ntfy follow-up](#optional-follow-ups), if it is ever wanted.

### Desktop session checklist

- [x] Power on → niri on tty1 with no password; `loginctl` shows the
      session on seat0; tty2 is a plain shell — *2026-09-24: autologin opens
      the session with no password and `niri.service` comes up on its own;
      `loginctl` shows it on seat0 on tty1. tty2 is a plain shell (seen at the
      console the same day)*
- [x] `nix flake check` fails on a deliberately broken `niri.kdl` — *2026-09-24.
      The check did not exist until `249427c`, which is why the
      `focus-follows-mouse off` parse error reached a switch. It was verified
      both ways: it passes on the fixed config and fails on the original typo*
- [x] Chrome: `chrome://version` shows `--password-store=gnome-libsecret`,
      and a saved password survives a reboot after one keyring prompt —
      *2026-09-24, flag confirmed at the console*
- [x] fuzzel launches (`Mod+D`), and `Mod+Return` gives WezTerm — *2026-09-24*
- [ ] waybar tray shows Steam, Tailscale and blueman
- [x] `notify-send test` pops up in swaync and lands in its history —
      *2026-09-24, with two fixes on the way. swaync was started twice, by
      niri's `spawn-at-startup` and by the unit `services.swaync.enable`
      generates; the spawned copy won the `org.freedesktop.Notifications` bus
      name and the unit sat failed on a start-limit. And `notify-send` itself
      was never packaged, so this check could not be run as written —
      `libnotify` is now in `hosts/desk/desktop.nix`. Proved end to end by
      calling `Notify` over the bus: swaync returned an id and
      `swaync-client --count` went to 1. The pop-ups were then seen on screen,
      and they stay in the `Mod+N` panel*
      - Useful detail if this recurs: swaync's "An instance of
        SwayNotificationCenter is already running!" is a **bus-name** check,
        not a process check, and the process is named `.swaync-wrapped` — so
        `pkill -x swaync` and `pgrep -ax swaync` both miss it and make it look
        as though nothing is running. `busctl --user list | grep -i notif`
        names the real owner.
- [ ] iPhone paired: a text message appears in swaync within seconds. Walk out
      of range and back, and the next one still arrives without re-pairing —
      *Tether landed 2026-09-24 (`hosts/desk/iphone.nix`); pairing is next*
- [ ] Tether: `tether --bt-status` shows full mode; a reply sent from the
      desktop arrives on the other end; a call on the phone stays on the phone —
      *paired 2026-09-24: full mode, Bearer API confirmed, bond BR/EDR + LE;
      `--bt-connection` shows Messages (MAP), Contacts (PBAP, 146 pulled) and
      Notifications all yes, mirroring active. The MAP/PBAP "forbidden" errors
      in the log were from before the phone's permissions were granted.
      Calls (HFP) reads no — not a goal. `tetherd` also wanted `btmgmt` on
      PATH for its secure-connections probe; added. A text arrived in swaync;
      its **Reply** button only dismissed it, because Reply runs
      `tether-gtk --thread=…` from tetherd's PATH, where it was missing. Fixed,
      and tetherd now starts with graphical-session.target so what it launches
      has WAYLAND_DISPLAY. Reply opens the thread in tether-gtk, not an inline
      field in swaync — **confirmed working after the switch.** Reconnect is
      automatic: the bond is in `/var/lib/bluetooth`, `bluetooth.json` names
      the phone with `enabled`, and tetherd re-supervised it by itself after a
      restart. Still to try: a reboot.* *Out of range and back, 2026-09-24:
      half passed.* Away 16:40–18:20, the phone stayed at the edge of range:
      the LE link came up and dropped 115 times (mirroring briefly active 11
      times) while MAP held. From 18:13 the iPhone stopped answering LE at
      all, so texts (MAP) kept arriving and email (ANCS) did not;
      `tether --bt-connection` said "The iPhone is not answering on LE".
      Turning Bluetooth off and on **in the iPhone's Settings** fixed it at
      once. Tether's BLUETOOTH.md (2026-08-19) records the same iPhone-side
      wedge, likely provoked by a burst of connect attempts, with the same
      and only remedy — nothing on desk can clear it. Open question: does a
      clean absence (phone well out of range) recover by itself? If the wedge
      recurs every time, report it upstream with `tetherd.log`. *Alert added
      the same day:* the `tether-ancs-watch` user service (in `iphone.nix`)
      polls `tether --bt-connection` each minute and posts one swaync alert
      after five minutes of BR/EDR up with Notifications down. *Second
      absence, 2026-09-24 19:14 → next morning: failed the same way, and it
      answers the open question.* LE dropped at 19:16, within two minutes of
      walking off, and mirroring rebuilt itself once; BR/EDR went at 19:18
      and flapped at the edge of range until 20:03. From then on the phone
      was in range all night — BR/EDR up, MAP working — and never answered LE
      again, although tetherd solicited ANCS every three minutes for twelve
      hours. A Bluetooth cycle on the phone at about 08:15 cleared it (LE and
      mirroring back by 08:30). So the wedge is set **on the way out**, while
      crossing the edge of range, and time in range does not clear it: two
      departures, two wedges. Next: an iOS automation that cycles Bluetooth
      when the phone joins the home Wi-Fi. *No upstream report: this is the
      wedge Tether's BLUETOOTH.md already documents, and a phone-side cycle
      fixes it — the case Tether asks about is one a cycle does not fix. The
      kernel's `hci_conn_timeout` refcount WARNING and the "Unable to disable
      Address Resolution: -16" lines were checked on 2026-09-25 and are not a
      desk-side cause: the latter come from Tether's own StartDiscovery calls
      (the log timestamps match), the former from the same connect/drop churn.*
      *2026-09-25:
      the alert did fire overnight and was waiting in the panel. The
      automation is declined — a manual cycle on seeing the alert is enough —
      so the alert now withdraws itself once notifications flow again*

- [ ] A screen share (Chrome → Meet) sees the niri outputs through the portal
- [ ] Idle: monitors off at 10 min; with nothing busy, suspend at 15; the
      suspend bar in [Idle](#idle-screens-off-then-suspend--if-the-wi-fi-can-wake-it)
      met or suspend removed. Everything else is in Phase 8

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

**SMB, not NFS.** The clients are the MacBook, the iPhone and Windows — in
either boot mode; the guest reaches it over the virtual network. (*Decided
2026-09-24: tailnet-only* — see the landed note below. Bare metal reaches the
share through Tailscale on Windows, not over the LAN.) NFS on macOS is a long-standing
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
  networking.firewall.interfaces."wlp14s0" = {
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

*Landed 2026-09-24 as [`hosts/desk/media.nix`](../hosts/desk/media.nix)*, as
above plus three things the draft missed: a tmpfiles rule handing `/srv/media`
to n8 (disko created it `root:root`, and with `force user = n8` the share would
have refused every write), `nmbd` and `winbindd` switched off (both default on;
NetBIOS and domain membership serve nothing here), and a note that the one
`autoScrub` entry covers `/srv/games` too, since both are subvolumes of one
filesystem. The build is checked; the switch and the Samba password are yours:

```sh
sudo nixos-rebuild switch --flake ~/natb1/nix-config#desk
sudo smbpasswd -a n8                      # its own password, not a Unix one
systemctl status samba-smbd samba-wsdd    # both active
stat -c '%U' /srv/media                   # n8
smbclient -L localhost -U n8              # lists `media`
```

Then from the Mac: Finder → Go → Connect to Server → `smb://desk/media`
(MagicDNS, over the tailnet).

*Verified 2026-09-24 after the switch:* `samba-smbd`, `samba-wsdd` and
`srv-media.mount` active; `/srv/media` is `n8:users`; smbd on 445 and wsdd on
5357; `btrfs-scrub@srv-media.timer` first fires 2026-10-01; the `media` share
lists from both `localhost` and the Wi-Fi address; nothing failed. **One gap
found:** nixpkgs builds samba with `enableMDNS = false`, so smbd never
registered `_smb._tcp` with avahi and Finder's sidebar would not show `desk`
(`multicast dns register = Yes` is a silent no-op). Fixed with a static
`services.avahi.extraServiceFiles.smb`; `avahi-browse -rt _smb._tcp` confirms
it after the next switch — *confirmed 2026-09-24:* `desk` publishes
`_smb._tcp` on 445 over Wi-Fi (IPv4 and IPv6). *Then removed the same day,
with the LAN — below.*

**Tailnet-only, decided 2026-09-24.** `tailscale ping` from `desk` to the Mac
went direct over the home network, not through a DERP relay, so a LAN mount
would add no speed, only a second way in. That way in was also the IPv6 hole
below. So the `wlp14s0` firewall rule and the mDNS advertisement are gone;
the share is reachable from the tailnet (`tailscale0` is trusted) and from
the guest's `virbr0`, and `hosts allow` is exactly loopback,
`192.168.122.0/24`, `100.64.0.0/10` and `fd7a:115c:a1e0::/48`, with
`hosts deny = ALL`. Given up: Finder's sidebar discovery (use
`smb://desk/media`) and bare-metal Windows without Tailscale — install
Tailscale there rather than reopening Wi-Fi.

*Verified after the switch, 2026-09-24:* new connections from the Wi-Fi's
IPv4 and global IPv6 addresses are refused by smbd
(`NT_STATUS_INVALID_NETWORK_RESPONSE`; the IPv6 one listed shares before),
while `100.121.40.74` and localhost list `media`. Those probes come in over
loopback, so they test `hosts allow`/`deny` alone; separately, `iptables -S`
and `ip6tables -S` show no `wlp14s0` rule — only `tailscale0` (trusted) and
`virbr0` (445, 5357, 3702). Two layers, each closed on its own. Open SMB
sessions survived the switch: smbd reloads config without dropping them.

**iPhone:** the Tailscale app, signed into the same tailnet, then Files →
⋯ → *Connect to Server* → `smb://100.121.40.74/media` (desk's tailnet
address; `smb://desk/media` works too if MagicDNS resolves in Files), as
*Registered User* n8 with the Samba password. Files plays and previews
most media; VLC or Infuse browse the same SMB share if Files' player is not
enough.

- [x] **Mac mounts the share itself** — *2026-09-24, from
      [`hosts/mba/desk.nix`](../hosts/mba/desk.nix)*: a launchd agent mounts
      `smb://n8@desk/media` at login and every five minutes if it has dropped,
      using the password in the login keychain. It mounted on the first
      `darwin-rebuild switch` (`smbstatus` here showed the Mac on `media`).
      Not finding it at first was a Finder setting, not a failure: with no mDNS,
      `desk` never appears under Network, only under Locations when *Settings →
      Sidebar → Connected servers* is on, or at `/Volumes/media`

- [x] **`hosts allow` does not cover IPv6** — *resolved 2026-09-24 by going
      tailnet-only (above) and `hosts deny = ALL`.* Its entries are all IPv4, and
      `hosts deny = 0.0.0.0/0` matches only IPv4, so an IPv6 client is let
      through: `smbclient -L` against the Wi-Fi's global `2607:…` address
      lists shares. The wlp14s0 firewall rule opens 445 on IPv6 too. What
      stands in the way today is the gateway (if it drops unsolicited inbound
      IPv6, unverified) and the Samba password. The tempting fix — allow only
      `::1 fe80::/10 fd7a:115c:a1e0::/48` (link-local plus the tailnet) — may
      lock the Mac out if Finder reaches `desk.local` over the global
      address, whose prefix is ISP-assigned and changes. Decide after the Mac
      test shows which address it uses (`smbutil statshares -a` on the Mac,
      or `smbstatus` here)

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
      WakeSystem = true;   # RTC-wake from suspend to run — see The desktop session's Idle
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

- [x] Bulk drive partitioned as btrfs by disko (§1), with `autoScrub` enabled —
      *2026-09-24: `autoScrub` is in `hosts/desk/media.nix`, monthly*
- [x] `hosts/desk/media.nix`, imported from `hosts/desk/default.nix` — *2026-09-24*
- [x] `smbpasswd -a n8`; mount from the Mac over the tailnet (the LAN was
      dropped, above) —
      *tailnet done 2026-09-24:* `smbstatus` showed n8 from `100.86.15.63`
      (IPv4) on SMB3_11 with `media` open, and Finder's `.DS_Store` landed
      in `/srv/media` as `n8:users 0644`, so auth, the ownership fix and
      writes all work. Unencrypted at the SMB layer, which is fine inside
      WireGuard
- [x] iPhone mounts `media` through Files over Tailscale — *2026-09-24,
      `smb://desk/media` (MagicDNS resolves in Files); `smbstatus` showed n8
      from `iphone-13-mini` at `100.70.251.123` on SMB3_11*
- **Step 2 postponed 2026-09-24**, by choice. That also holds Step 3: nothing
      irreplaceable lands on `/srv/media` without a proven restore. The
      share itself is in use for anything that has another copy
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
      also lives under `Photos from <year>/` — *so far (2026-09-24): Google
      Drive 22.1 GiB in 2,884 files (`rclone size`, Google Docs excluded);
      Google Photos 8.2 GB archived. GCS, the MacBook and Flickr to go*
- [ ] Record the Google Photos item count **before** requesting Takeout — it is
      the only verification the export admits, and it is unreadable afterwards
      if the library has moved on
- [ ] Request the Flickr data export early — it is prepared asynchronously
- [ ] Request the Google Takeout export early, **delivered to Google Drive** —
      also asynchronous, and its download links expire after 7 days. Check the
      Google One quota first: the archive lands in Drive against the same
      quota Photos already fills, so it needs free space equal to the library.
      No headroom → download-link delivery, pulled inside the window, or a
      month of extra storage — *2026-09-24: ready, delivered as an emailed
      download link instead (7.6 GB, so one `.tgz` part), which **expires
      2026-10-01**. The link needs a signed-in Google session, so it is a
      browser download into `/srv/media/takeout/`, then `tar -tzf` on the
      part. Downloading is not gated on BIOS tuning (a corrupt copy fails the
      gzip CRC and Google still holds the original); unpacking and the
      sidecar merge are.* *Downloaded and checked the same evening:
      `/srv/media/takeout/takeout-20260924T222726Z-1-001.tgz`, 8.16 GB,
      `tar -tzf` clean; 3,012 entries, of which 1,306 are originals under
      `Photos from 2012` … `2022` (no `-edited`, no `.json`) plus 124 under
      `Archive`. The library ends in 2022, and photos.google.com agrees —
      confirmed the same evening, so the archive is the whole library*
- [ ] [BIOS tuning](#bios-tuning) validated — memory proven stable before
      irreplaceable data passes through it
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
  networking.firewall.interfaces."wlp14s0".allowedTCPPorts = [ 631 ];
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

### What landed — 2026-09-24

`hosts/desk/printing.nix`, with three deviations from the sketch above, all
following the media share's tailnet-only decision:

- **No Wi-Fi.** No `wlp14s0` firewall rule, and `allowFrom` is loopback,
  `virbr0`, and the tailnet's IPv4 **and IPv6** ranges (the sketch's
  `192.168.0.0/16` also left IPv6 out). CUPS's `Order allow,deny` denies
  anything unlisted, so there is no IPv6 hole like Samba's.
- **No advertisement:** `browsing = false`. mDNS would announce on Wi-Fi a
  queue Wi-Fi cannot reach. The Mac adds the queue by address; the guest's
  is declared by address already.
- **Not socket-activated** (`startWhenNeeded = false`, fixed after the first
  switch). systemd's single dual-stack socket delivers IPv4 clients as
  `::ffff:a.b.c.d`, which CUPS does not match against IPv4 `Allow` ranges:
  the tailnet's IPv4 got **403** while its IPv6 and localhost got 200, so the
  Mac's printer probe failed and *Use* offered no AirPrint. 403s are not
  logged at the default level, so the journal showed nothing. The switch
  alone did not fix it: cupsd kept running on the inherited socket until
  `sudo systemctl restart cups`. After that it holds its own `0.0.0.0:631` and
  `[::]:631`, tailnet IPv4 returns 200, and `ipptool get-printer-attributes`
  over IPv4 shows `urf-supported` and `application/pdf` — what macOS needs to
  offer *AirPrint*.
- **`cups-browsed` off.** It defaults on wherever avahi is, discovers *other*
  machines' printers, and is the daemon the 2024 CUPS RCE chain ran through.

The cost is discovery, not printing. The Mac adds the queue by address. **The
iPhone does too, through a configuration profile:** iOS has no settings screen
for a printer by address, but its `com.apple.airprint` payload takes a hostname
and resource path and is installable by hand, no MDM (Apple's schema:
`supervised: false`, `allowmanualinstall: true`).
[`hosts/desk/airprint-desk.mobileconfig`](../hosts/desk/airprint-desk.mobileconfig)
is that profile: AirDrop it from the Mac, then *Settings → Profile Downloaded →
Install*. (An earlier note here said the iPhone could not print at all; that
was wrong.) Opening Wi-Fi is a firewall rule, a LAN range in `allowFrom`, and
`browsing = true`.

Checked before the switch: the printer is on USB `5-2` with serial
`U66480F3N341782`, and brlaser 6.2.8 has `brl2305.ppd` for `HL-L2305 series`.

### Checklist

- [x] After Phase 2: `lpinfo -v` shows the `usb://Brother/HL-L2305%20series?serial=…`
      URI exactly as in `printing.nix`; fix the string if the backend reports
      it differently — *2026-09-24, exact match*
- [x] `lpstat -t` → `brother` enabled, accepting, default; `lp -d brother /etc/os-release` prints
      — *2026-09-24: enabled, accepting, default; job `brother-1` printed*
- [x] iPhone: `airprint-desk.mobileconfig` installed, and a page prints from
      the share sheet over Tailscale — *2026-09-24. There is no default
      printer to set: iOS has no such setting, and the AirPrint payload has no
      key for one (only address, path, port, TLS). The print sheet preselects
      the last printer used*
- [ ] ~~From the Mac on the LAN~~ — *dropped 2026-09-24, tailnet-only*
- [x] From the Mac over Tailscale, off the LAN: the `ipp://desk.<tailnet>.ts.net`
      queue prints — *2026-09-24: a page printed. The queue is now declared in
      [`hosts/mba/desk.nix`](../hosts/mba/desk.nix), which runs the same
      `lpadmin` on every `darwin-rebuild switch`, as does the media share's
      mount. **By hand, add it from Terminal, not the Add Printer window**:
      `lpadmin -p desk_brother -D "Brother (desk)" -E -v ipp://100.121.40.74/printers/brother -m everywhere`.
      The window's IP tab never offered *AirPrint* under Use, by name or by
      IP, although `curl` got 200 and `ipptool get-printer-attributes` passed
      from the same Mac, and a `tailscale0` capture showed its connections
      arriving. `-m everywhere` is the same thing the AirPrint choice does:
      it builds the queue from the printer's own IPP attributes*
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
  echo vfio-pci > /sys/bus/pci/devices/0000:11:00.0/driver_override
  echo 0000:11:00.0 > /sys/bus/pci/drivers_probe
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

#### Lending the dGPU to the host, on demand

Decided 2026-09-23. `vfio-pci.ids` above binds the RX 6600 XT to vfio-pci at
boot, and as the plan first stood it stayed there, so the host-side Steam
library ([`/srv/games`](#where-the-steam-library-lives)) would have run on the
Raphael iGPU's 2 CUs. Instead, the card stays with vfio-pci **until you
ask for it**. `sudo dgpu host` hands function 0 to amdgpu for native and
Proton games. `dgpu vm`, or simply starting `win`, takes it back.

**Does defaulting to the iGPU save power?** Yes, though the saving comes mostly
from one place: **the desktop never runs on the dGPU.** An RDNA2 card driving
a desktop, especially several monitors or a high refresh rate, often holds
its memory clock at maximum and idles at tens of watts, while the iGPU idles
at a few. The monitors are on the motherboard's outputs either way. The
second question, whether an *unused* dGPU draws less parked on vfio-pci or
idling under amdgpu, matters less: vfio-pci puts an unused device in
D3hot, and amdgpu's runtime power management may or may not do as well on
a desktop card. That difference is single-digit watts and unmeasured, so
hand the card back after gaming (`dgpu vm`) and read the difference off a
wall meter once, in Phase 8. It is not worth more thought than that.

Only **function 0** (the GPU) is lent. The HDMI-audio function (`.1`) stays on
vfio-pci for good: the host's sound goes out of the motherboard, and if
PipeWire opened the card's audio it would pin the card just as a compositor
does. The IOMMU group is still viable for the guest when it starts, because
by then both functions are back on vfio-pci.

```nix
# hosts/desk/dgpu.nix
{ pkgs, lib, ... }:
let
  dgpu = "0000:03:00.0";   # function 0 only, from Phase 0
  dgpuSwitch = pkgs.writeShellScriptBin "dgpu" ''
    set -eu
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.psmisc pkgs.libvirt pkgs.gnugrep ]}
    dev=/sys/bus/pci/devices/${dgpu}
    current() { [ -e $dev/driver ] && basename "$(readlink $dev/driver)" || echo none; }
    # Per-device, like the NVMe binding: driver_override, never an ID match.
    rebind() {
      [ -e $dev/driver ] && echo ${dgpu} > $dev/driver/unbind
      echo "$1" > $dev/driver_override
      echo ${dgpu} > /sys/bus/pci/drivers_probe
      [ "$(current)" = "$1" ] || { echo "dgpu: $1 did not bind" >&2; exit 1; }
    }
    case "''${1:-status}" in
      status) current ;;
      host)
        [ "$(current)" = amdgpu ] && exit 0
        # Safe here: this branch never runs inside a libvirt hook.
        if virsh -c qemu:///system domstate win 2>/dev/null | grep -qx running; then
          echo "dgpu: win is running and owns the card" >&2; exit 1
        fi
        rebind amdgpu ;;
      vm)
        [ "$(current)" = vfio-pci ] && exit 0
        # Unbinding amdgpu under an open DRM node is how the host crashes.
        # Refuse, and say who is holding it.
        nodes=$(ls /dev/dri/by-path/pci-${dgpu}-* 2>/dev/null || true)
        if [ -n "$nodes" ] && fuser -s $nodes; then
          echo "dgpu: in use; close these first:" >&2
          fuser -v $nodes || true
          exit 1
        fi
        rebind vfio-pci ;;
      *) echo "usage: dgpu [status|host|vm]" >&2; exit 2 ;;
    esac
  '';
in
{
  environment.systemPackages = [ dgpuSwitch ];

  # Starting `win` takes the card back. Sorted before 10-win-perf, so a
  # refusal stops the start before any cores are fenced off. Must not call
  # virsh: a hook that calls back into libvirtd deadlocks it.
  virtualisation.libvirtd.hooks.qemu."05-win-dgpu" = pkgs.writeShellScript "win-dgpu" ''
    [ "$1" = win ] && [ "$2/''${3:-}" = prepare/begin ] || exit 0
    exec ${dgpuSwitch}/bin/dgpu vm
  '';

  # Games pick the dGPU when it is lent and fall back to the iGPU when it is
  # not. Mesa's DRI_PRIME covers GL, and Vulkan through the device-select layer.
  programs.steam.package = pkgs.steam.override {
    extraEnv.DRI_PRIME = "pci-0000_03_00_0";
  };
}
```

The rule this buys, stated once: **quit Steam (and any other game) before
starting the VM.** Anything that has opened the dGPU (a game, or Steam's
own client if it picked the card) holds it, and the hook refuses the start with
the list of holders rather than crashing the host. A refused start is the
system working as designed.

amdgpu hot-unbind is the least-trodden path in this plan. It has worked
properly since roughly kernel 5.14, and RDNA2 resets cleanly, but it is still
the least exercised. If Phase 8's round trips oops, the fallback is the plan
as it stood: the dGPU stays on vfio-pci, and host-side titles play in the
guest. Nothing else here depends on lending.

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

What *is* unmanaged state is listed in [Phase 9](#phase-9--keep-the-wsl-host-for-bare-metal-windows):
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
- [ ] No machine-check errors since cutover: `journalctl -k -b -g 'mce|Hardware Error'`
      empty on the host, no **WHEA-Logger** events in Windows — the
      [BIOS tuning](#bios-tuning) holds under the real workload, not just the
      synthetic one. Check again after a week
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

**Desktop session**: the [Desktop session checklist](#desktop-session-checklist),
in full, and then the parts that only show up under load:

- [ ] **Lending round trip, five times:** `sudo dgpu host` → `dgpu status` says
      `amdgpu` → a Proton game runs, and `MESA_VK_DEVICE_SELECT=list vkcube` or
      the game's own overlay names the 6600 XT → quit it → `sudo dgpu vm` →
      `vfio-pci`. No amdgpu oops in `journalctl -k -b`. Then start `win`: the
      dGPU works in the guest after having been lent
- [ ] **niri never holds the card:** while it is lent,
      `fuser -v /dev/dri/by-path/pci-0000:03:00.0-*` lists no `niri`
- [ ] **A refused start is a clean refusal:** lend the card, leave a game
      running, `virsh start win` → fails, naming the game. Host still fine,
      no cores fenced off (`systemctl show user.slice -p AllowedCPUs` empty)
- [ ] **Power, once, at the wall:** idle desktop with the dGPU on vfio-pci vs
      lent and idle. Write both numbers here. They decide whether "hand it back
      after gaming" is worth remembering
- [ ] **The suspend bar**: 10/10 clean suspend/resume cycles, 5/5 magic-packet
      wakes from the Mac, per
      [Idle](#idle-screens-off-then-suspend--if-the-wi-fi-can-wake-it). Plus:
      no suspend while `win` runs, while restic runs, while the Mac has an SMB
      mount or a mux pane open. Miss any, and suspend comes out
- [ ] After an RTC wake for the nightly backup, the machine suspends again on
      its own

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


## Phase 9 — Keep the WSL host, for bare-metal Windows

**Decided 2026-09-24: WSL is not retired.** It stays as Linux for bare-metal
Windows — the anti-cheat boot mode, when `desk` is not running. This phase used
to delete `hosts/wsl/` once Phase 8 passed; what is left of it is the
housekeeping that still applies.

What stays, unchanged:

- `hosts/wsl/` and the `nixosConfigurations.wsl` output, including the
  modules [What this buys the repo](#what-this-buys-the-repo) once marked for
  deletion: `mounts.nix`, the WezTerm Windows GUI install and its
  copy-to-Windows config, and `claude-in-chrome.nix`.
- `modules/home/wezterm-pin.nix`'s Windows half, the Windows-zip mirroring in
  `scripts/sync-wezterm.sh`, and the Windows branches of the shared WezTerm
  Lua — the Windows WezTerm GUI is still WSL's front end.
- The `wsl` Tailscale node, its `known_hosts` entry on the Mac, and the
  `n8@wsl` key in `modules/home/default.nix`. `desk` gets its own key added
  alongside when it needs one, rather than taking `wsl`'s.
- The WSL-specific wezterm checks, so
  [Risk 15](#risks-ranked) no longer applies.

Two hosts, one machine: `wsl` and `desk` are never up at the same time, and
each pulls and switches from `main` when it is the one running. They share
`flake.lock`, and the weekly bump already evaluates both.

WSL is a bare-metal tool here. In the guest it needs nested virtualization,
which nothing in Phase 4 sets up for it — do not plan on it there.

Still to do, after Phase 8:

- [ ] README: replace the "A future native NixOS host" section with the real one
- [ ] Update the "State this repo does not manage" list. The Windows-side
      WezTerm install and the `G:` volume **stay** (WSL still uses them). New
      entries are the Microsoft
      account the digital license hangs off (no product key — see
      [Secrets](#secrets)), everything on Windows' own drive, rclone
      credentials (*already listed, 2026-09-24: the encrypted `rclone.conf`
      and its keyring password*), the Wi-Fi PSK, the Samba password database
      (*already listed, 2026-09-24*),
      `/etc/restic/{media.password,id_ed25519}`, the Secure Boot keys in
      `/var/lib/sbctl` (backed up off-machine — [Phase 2b](#phase-2b--restore-secure-boot)),
      and the guest's TPM and firmware state —
      `/var/lib/libvirt/swtpm/<uuid>/` and `/var/lib/libvirt/qemu/nvram/win_VARS.fd`
      ([Two TPMs, one install](#two-tpms-one-install)), the iPhone's Bluetooth
      bond in `/var/lib/bluetooth` and the gnome-keyring contents in
      `~/.local/share/keyrings` ([The desktop session](#the-desktop-session))
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
15. *No longer applies — WSL stays (2026-09-24).* **`nix flake check` coverage drops.** Deleting the WSL host takes the
    WSL-specific half of the sixteen wezterm checks with it — the
    activation-script suite and the `wslHost = true` cases — while the
    native-Linux and macOS cases stay. The stale-`rendered/` check in
    [Phase 6](#phase-6--managing-the-one-windows-install) recovers some of it;
    whatever else replaces them should land in the same PR as the deletion, or
    it never lands.
16. **A marginal memory tune.** Not a crash — those get noticed — but a rare
    bit flip that corrupts a file *before* btrfs checksums it, so scrub,
    restic and Hetzner all preserve the damage faithfully. Ranked low because
    [BIOS tuning](#bios-tuning) validates before the media lands and the
    WHEA/MCE check in Phase 8 keeps watching; worth listing because it defeats
    every other integrity mechanism in this plan. If in doubt, the rated profile alone, or none.
17. **A lent dGPU that will not come back.** amdgpu hot-unbind under an open
    DRM node, or a niri that opened the card despite `ignore-drm-device`,
    leaves the card stuck on the host or oopses the kernel. `dgpu vm` refuses
    while anything holds the card, and Phase 8 runs the round trip five times.
    The fallback is to never lend, which costs host-side game performance
    and nothing else.
18. **A sleeping `desk` that nobody can wake.** Suspend takes Samba, CUPS,
    the mux server and Tailscale offline together, and only a magic packet
    from the LAN brings them back. That cost is accepted, but it only stays
    acceptable if the wake is reliable. The bar in
    [Idle](#idle-screens-off-then-suspend--if-the-wi-fi-can-wake-it) is what
    turns this from a slow annoyance into a decision. Below it, suspend comes
    out.

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
- **WezTerm on Windows from winget.** WSL's own Windows GUI install stays
  with the WSL host ([Phase 9](#phase-9--keep-the-wsl-host-for-bare-metal-windows));
  the Windows *profile* adds none. A winget build would be unpinned and could only
  mismatch the pinned mux server — [Phase 3](#wezterms-windows-gui-pin). If
  one is ever wanted, it comes from the mirror release by hash.
- **A screen lock, or a display manager.** Decided 2026-09-23: the session
  protects nothing that is not already behind its own encryption, so a lock
  would be friction without a threat model. getty autologin replaces the
  display manager, which is one less thing to configure or break.
- **Bluetooth wake.** The paired iPhone would wake the desk on every
  notification.

## Optional follow-ups

Not part of the cutover. Each is recorded so the reasoning isn't lost, and
none is scheduled.

### Push alerts to the phone (ntfy)

The other direction from [ANCS](#iphone-notifications-over-ancs): `desk`
telling the phone something, wherever the phone is. Not a use case today,
which is why it is here and not in the plan. What it would fill is the
`<FILL_ME_notify_unit>` in [Media storage](#step-2--backup-for-when-the-bulk-ssd-dies):
a backup that fails while you are away from the desk is exactly the alert a
desktop pop-up cannot deliver.

- **Shape:** a templated `notify@.service` that `curl`s an ntfy topic (ntfy.sh,
  or self-hosted) with `%i` as the failing unit's name, and
  `OnFailure = "notify@%n.service"` on restic, `btrfs-scrub-*` and anything
  else that should page. The ntfy iOS app shows it.
- **State:** the topic name (and access token, if the server requires one) is a secret, so it joins
  the unmanaged-state list alongside the restic credentials.
- **Together with ANCS it is two one-way pipes, not a sync.** Dismissing on
  one side does not clear the other. And there is an **echo loop** to close:
  an ntfy alert posted on the iPhone is itself a notification, which ANCS
  forwards straight back to the desk. Drop the ntfy app's notifications on the
  Linux side by their ANCS app identifier (read it off the first forwarded
  alert) in the desktop-integration step, or in a swaync rule.
