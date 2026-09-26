import QtQuick
import Quickshell
import Quickshell.Wayland

// The wallpaper, one background-layer window per screen. The image is
// chosen in hosts/desk/home/desktop.nix and passed as DESK_WALLPAPER; without
// it (the flake check) the screen is plain Theme.bg.
Variants {
    model: Quickshell.screens

    PanelWindow {
        required property var modelData
        screen: modelData

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.namespace: "quickshell-wallpaper"
        color: Theme.bg

        Image {
            anchors.fill: parent
            source: Quickshell.env("DESK_WALLPAPER") ?? ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
        }
    }
}
