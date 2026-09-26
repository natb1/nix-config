pragma Singleton

import QtQuick
import Quickshell

// Colours and fonts, in one place. The accent is niri's focus ring
// (niri.kdl), so the panel reads as part of the same desktop.
Singleton {
    readonly property color scrim: "#66000000"
    readonly property color bg: "#f0181b21"
    readonly property color card: "#23272f"
    readonly property color cardHover: "#2b303a"
    readonly property color border: "#343a46"
    readonly property color fg: "#e6e8ee"
    readonly property color dim: "#9aa1ad"
    readonly property color accent: "#7fc8ff"
    readonly property color accentFg: "#0d1b26"
    readonly property color critical: "#ff6b6b"

    readonly property string font: "Noto Sans"
    // Nerd Font glyphs (Material Design range). The font is installed
    // system-wide by hosts/desk/desktop.nix.
    readonly property string iconFont: "JetBrainsMono Nerd Font Propo"

    readonly property var icons: ({
        tailscale: String.fromCodePoint(0xF0582),   // vpn
        bluetooth: String.fromCodePoint(0xF00AF),
        bluetoothOff: String.fromCodePoint(0xF00B2),
        wifi: String.fromCodePoint(0xF05A9),
        wifiOff: String.fromCodePoint(0xF05AA),
        volume: String.fromCodePoint(0xF057E),
        volumeOff: String.fromCodePoint(0xF0581),
        cpu: String.fromCodePoint(0xF0EE0),
        bell: String.fromCodePoint(0xF009A),
        bellOff: String.fromCodePoint(0xF009B),
        play: String.fromCodePoint(0xF040A),
        pause: String.fromCodePoint(0xF03E4),
        next: String.fromCodePoint(0xF04AD),
        prev: String.fromCodePoint(0xF04AE),
        close: String.fromCodePoint(0xF0156),
        music: String.fromCodePoint(0xF075A)
    })
}
