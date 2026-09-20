# Plan — WSL → native NixOS with a GPU-passthrough Windows VM

Written 2026-09-20. This is the *second* migration this repo tracks: [TODO.md](../TODO.md)
is about finishing the move off `commons.systems`. This one is about the
desktop stopping being a Windows box that hosts NixOS, and becoming a NixOS box
that hosts Windows.

Sequencing: **finish TODO.md §1–§3 first.** Switching the WSL host onto this
repo is the cheap, reversible change that proves the repo works. Wiping the
machine is neither. Do not stack them.

---

## Decisions locked in

| Question | Answer | What it rules out |
| --- | --- | --- |
| GPU topology | Discrete card → VM, AMD iGPU → NixOS | Single-GPU hook gymnastics; the host never goes headless |
| Anti-cheat | No kernel anti-cheat titles | Dual-boot as a permanent escape hatch; hypervisor-hiding hacks |
| Windows config rigor | Rebuildable image — Nix generates the answer file and provisioner, the disk is a build artifact | Treating `C:\` as a pet |

Three consequences worth stating up front:

1. **The disk can be wiped.** No anti-cheat means no bare-metal Windows
   partition to preserve, so `disko` can own the whole drive and the install is
   a clean declarative one. (Disko explicitly does not support dual-boot; that
   would have meant hand-partitioning.)
2. **Do not hide the hypervisor.** The `<kvm><hidden state='on'/></kvm>` +
   spoofed `vendor_id` trick exists to dodge anti-cheat, and it *costs*
   performance because it disables the Hyper-V enlightenments Windows uses to
   run fast under KVM. Skip it entirely and take the enlightenments.
3. **Check ProtonDB before building any of this.** Every title that runs native
   under Proton is a title the VM does not have to serve. If the list comes back
   mostly green, the VM shrinks from "daily driver" to "occasional escape
   hatch", and several phases below get much less important.

### Still unknown — resolved in Phase 0

- The exact discrete GPU (vendor + PCI IDs). If it is a **Radeon**, check
  whether it needs `vendor-reset` for the AMD reset bug (Polaris/Vega do;
  RDNA2+ generally do not). If it is **NVIDIA**, Code 43 has not been a real
  problem since the 465 driver.
- Whether the IOMMU groups isolate the dGPU cleanly.
- Ryzen core/CCD layout, for pinning.
- Whether there is a second NVMe for the game library.

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
output somewhere that survives the wipe (the Mac, or the Drive folder).

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
  has neither, this plan is dead and dual-boot is the answer.

Also in Phase 0, before anything is wiped:

- [ ] `nixos-generate-config --no-filesystems --show-hardware-config` from the
      live USB → this is `hosts/desk/hardware-configuration.nix`
- [ ] Record `/dev/disk/by-id/` names for every drive (by-id, not `/dev/nvme0n1` —
      by-id is stable across reboots and is what disko should reference)
- [ ] Inventory the game library: which titles, and what ProtonDB says about each
- [ ] Inventory what is on `C:\` that matters and is not in Drive or git
- [ ] Note the Windows product key (`wmic path SoftwareLicensingService get OA3xOriginalProductKey`
      from the current Windows install) — a digital-entitlement key tied to this
      board may reactivate in the VM, but do not count on it

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

### Disk layout

```nix
# hosts/desk/disko.nix — device names from Phase 0, by-id only
{
  disko.devices.disk = {
    main = {
      device = "/dev/disk/by-id/nvme-<FILL_ME>";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";   # NixOS keeps every generation's kernel here; 512M fills up
            type = "EF00";
            content = {
              type = "filesystem"; format = "vfat";
              mountpoint = "/boot"; mountOptions = [ "umask=0077" ];
            };
          };
          root = {
            size = "100%";
            content = { type = "filesystem"; format = "ext4"; mountpoint = "/"; };
          };
        };
      };
    };
  };
}
```

**Split the Windows storage in two.** This is the design decision that makes the
"rebuildable image" choice survivable:

- `win-os.qcow2` — the C: drive. Small (~120 GB), disposable, regenerated by the
  image build. Losing it costs 30 minutes.
- a separate large volume (raw file, LVM volume, or a passed-through second
  NVMe) mounted as the Steam library. **Persistent.** Never touched by a
  rebuild.

Steam re-adopts an existing library folder after a Windows reinstall — it
validates and moves on. Without this split, "rebuild the image" means
re-downloading the entire library and nobody does that twice, which is how
declarative setups quietly become pets.

---

## Phase 2 — Install

```sh
# from the live USB, after Phase 0's gate passes
nix --extra-experimental-features 'nix-command flakes' \
  run github:nix-community/disko -- --mode disko \
  --flake /path/to/nix-config#desk

nixos-install --flake /path/to/nix-config#desk
```

Then reboot, `sudo tailscale up`, `git clone` the repo to `~/natb1/nix-config`,
and from there it is the same `nixos-rebuild switch --flake .#desk` loop as
every other host.

- [ ] Add a `desk` row to the README's host table with its rebuild command

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

## Phase 6 — Declarative Windows: the options

### The honest framing

Windows has no store, no closure, and no atomic rollback. Every tool below is
**convergent**, not declarative in the Nix sense: applying a config moves the
system toward a state, but deleting a line from the config does *not* remove
what it installed. There is no `nixos-rebuild switch` that garbage-collects a
registry key.

So "declarative Windows" decomposes into five separate problems, each with
different tooling and a different achievable ceiling:

| # | Layer | Ceiling | Options |
| --- | --- | --- | --- |
| 1 | **VM definition** — domain XML, VFIO binding, pinning, hugepages | **Fully declarative.** It is all Nix. | NixVirt · Nix-generated XML + a `virsh define` unit · virt-manager by hand |
| 2 | **OS install** — edition, partitioning, user, locale, skip OOBE/MS-account | **Fully declarative.** The answer file is generated data. | `Autounattend.xml` from Nix attrs · `GenerateAnswerFile` · hand-written XML in git |
| 3 | **Driver injection** — virtio storage/net/balloon | **Fully declarative**, hash-pinned. | `pkgs.virtio-win` · `NixVirt.lib.guest-install.virtio-win.iso` |
| 4 | **Apps & settings inside Windows** | **Convergent only.** | WinGet DSC (`winget configure`) · Chocolatey · Scoop · Ansible over SSH/WinRM |
| 5 | **Drift repair** | This is where you choose | **Rebuild the image** · re-run the convergence on a timer · snapshot-and-restore |

**Layer 5 is the actual decision, and you have made it: rebuild.** That choice
is what rescues layer 4 from being a lie. Convergence tools cannot guarantee
state, but if the disk is a build artifact you can throw away, you do not need
them to — a wrong state is fixed by regenerating, exactly like `nix-collect-garbage`
plus a switch.

This is also why the OS/library disk split in Phase 1 is load-bearing. Rebuild
is only a credible repair path if it is cheap.

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

### Layers 2–4 — the image build

Shape, with the Windows ISO kept out of git and out of the cache:

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
      <!-- windowsPE: disk layout, edition, product key -->
      <!-- oobeSystem: local account ${cfg.username}, skip MS account, skip telemetry -->
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

**Alternatives for layer 4, if WinGet DSC disappoints:**

- **Chocolatey** — broader package coverage than winget for older/niche
  software, and `choco install` from a Nix-generated package list is dead simple.
- **Ansible over SSH** — once `OpenSSH.Server` is enabled in the guest, the
  NixOS host can run a playbook against it. Genuinely idempotent, far richer
  than DSC for settings and registry work, and the playbook lives in this repo
  next to everything else. This is the strongest option if you ever want to
  converge a *running* Windows rather than only rebuild it. Cost: a whole second
  config language in the repo.
- **Scoop** — user-scope, no admin, good for CLI tools; wrong shape for games.

### Secrets

The product key and any credentials in the answer file must not land in git.
Either keep them in a `requireFile`'d fragment alongside the ISO, or bring in
`sops-nix`/`agenix` if you want them encrypted in the repo. This is the same
category as `~/.config/nix/access-tokens.conf` in the README's "state this repo
does not manage" list — add the answer-file secrets to that list either way.

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

**Guest**

- [ ] `virsh list` shows `win` running; Device Manager shows no unknown devices
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

**The rebuild path — test it before you need it**

- [ ] Delete `win-os.qcow2`, re-run `build-windows-image`, confirm the guest
      comes back with the same packages and the game library intact. If this
      does not work, the "declarative" claim is decorative.

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
      install and the `G:` volume are gone; the Windows ISO, product key and
      rclone credentials are new

---

## Risks, ranked

1. **IOMMU groups are dirty.** Found in Phase 0, before anything is destroyed.
   This is why Phase 0 is a gate and not a formality.
2. **The Windows image build is a long feedback loop.** 30+ minutes per attempt,
   and an answer-file typo fails near the end. Iterate on the answer file against
   a *plain* VM with no passthrough first — separate the two variables.
3. **The performance hook does not revert.** A crashed VM leaving the host
   pinned to four cores is the kind of bug you diagnose three weeks later as
   "NixOS feels slow lately". The `virsh destroy` test in Phase 8 exists for
   exactly this.
4. **Steam library on a disposable volume by accident.** Phase 1's split
   prevents it; verify with the Phase 8 rebuild test.
5. **`nix flake check` coverage drops.** Deleting the wezterm Windows tests
   removes 15 checks' worth of real assertions. Whatever replaces them — image
   build smoke test, domain XML eval test — should land in the same PR as the
   deletion, or it never lands.

## Deliberately not doing

- **Dual-boot.** No anti-cheat titles means no reason to pay for it, and disko
  does not support it. If a future game demands Vanguard or similar — which as
  of the June 2026 on-demand release wants Secure Boot, TPM 2.0, IOMMU, VBS and
  HVCI *on bare metal* — that is a re-partition, not a tweak. Leaving unallocated
  space on the drive now makes that cheap later.
- **Hypervisor hiding.** Costs performance, buys nothing here.
- **Moving the desktop modules into `modules/nixos/`.** One desktop host does not
  justify the abstraction; the repo's own host-vs-platform rule says so.
