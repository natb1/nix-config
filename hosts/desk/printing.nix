# The Brother HL-L2305, plugged into desk over USB and shared from here.
# docs/desktop-migration.md, "Printer sharing", is the design.
#
# IPP from CUPS, not Samba printer sharing: CUPS renders on the host and
# offers an IPP Everywhere queue, which macOS adds with no driver and the
# Windows guest adds with its inbox IPP class driver. The printer itself
# speaks neither (USB class 07/01/02, no IPP-over-USB), so the host
# translating is the point.
#
# Tailnet-only, plus the Windows guest over virbr0 — the same scope as the
# media share (hosts/desk/media.nix), and for the same reason: nothing on
# Wi-Fi reaches it, so nothing on Wi-Fi is told about it. What that gives up
# is AirPrint discovery on the home network — the Mac adds the queue once by
# address, and an iPhone, which cannot add a printer by address, cannot print.
# Opening Wi-Fi is a firewall rule, an allowFrom range and `browsing = true`.

{ pkgs, ... }:

{
  services.printing = {
    enable = true;
    # The maintained Owl-Maintain fork; upstream brlaser stops at the
    # HL-L2300D. Brother's own driver is a 32-bit .deb.
    drivers = [ pkgs.brlaser ];

    # Listen everywhere; reachability is allowFrom plus the per-interface
    # firewall below, the split media.nix uses and for the same reason:
    # tailscale0 and virbr0 both appear after boot.
    listenAddresses = [ "*:631" ];
    # CUPS writes `Order allow,deny` around these — anything unlisted is
    # denied, IPv6 included, unlike Samba's `hosts allow`. Loopback, libvirt's
    # default NAT network, and the tailnet's IPv4 and IPv6 ranges.
    allowFrom = [
      "localhost"
      "192.168.122.0/24"
      "100.64.0.0/10"
      "[fd7a:115c:a1e0::]/48"
    ];
    defaultShared = true;

    # No mDNS advertisement: it would announce on Wi-Fi a queue Wi-Fi cannot
    # reach, and mDNS does not cross the tailnet or virbr0's NAT anyway. The
    # guest's queue is declared by address (Phase 6), the Mac's by hand.
    browsing = false;
    # cups-browsed defaults on wherever avahi is. It discovers *other*
    # machines' printers, which desk has no use for, and it is the daemon the
    # 2024 CUPS remote-code-execution chain went through.
    browsed.enable = false;

    # CUPS rejects a request whose Host: header is not one of its own names.
    # Clients arrive as desk, desk.<tailnet>.ts.net and 192.168.122.1;
    # allowFrom, not the name, decides who gets in.
    extraConf = ''
      ServerAlias *
    '';
  };

  # Declarative queue, re-asserted by lpadmin every time cups starts, so
  # there is no hand-run setup to list as unmanaged state. The URI is keyed
  # on the serial, so it survives the printer moving to another port.
  hardware.printers = {
    ensureDefaultPrinter = "brother";
    ensurePrinters = [
      {
        name = "brother";
        description = "Brother HL-L2305";
        location = "desk";
        deviceUri = "usb://Brother/HL-L2305%20series?serial=U66480F3N341782";
        model = "drv:///brlaser.drv/brl2305.ppd";
        ppdOptions = {
          PageSize = "Letter";
          # Not a PPD option, but lpadmin takes it as -o like one. Explicit
          # because DefaultShared only applies when a queue is first created.
          printer-is-shared = "true";
        };
      }
    ];
  };

  # tailscale0 is trusted (modules/nixos/tailscale.nix), so the tailnet needs
  # no rule. No rule for wlp14s0: that is what keeps the queue off the LAN.
  # virbr0 arrives with libvirt (Phase 4); until then this rule is inert.
  networking.firewall.interfaces.virbr0.allowedTCPPorts = [ 631 ];
}
