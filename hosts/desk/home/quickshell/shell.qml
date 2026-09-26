//@ pragma UseQApplication
// UseQApplication: tray menus (QsMenuAnchor) are drawn as Qt widget menus.

// desk's desktop shell: notifications and status in one panel, no bar.
// Deployed by hosts/desk/home/desktop.nix as the "desk" Quickshell config.
//
//   qs -c desk ipc call panel toggle      Mod+Shift+N (niri.kdl)
//   qs -c desk ipc call notifications dnd
//   qs -c desk ipc call notifications clear
//
// docs/desktop-migration.md, "The desktop session", is the design.

import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    Wallpaper {}

    Panel {
        id: panel
    }

    Popups {
        panelOpen: panel.open
    }

    IpcHandler {
        target: "panel"

        function toggle(): void {
            panel.open = !panel.open;
        }
        function open(): void {
            panel.open = true;
        }
        function close(): void {
            panel.open = false;
        }
    }

    IpcHandler {
        target: "notifications"

        function dnd(): void {
            Notifs.dnd = !Notifs.dnd;
        }
        function clear(): void {
            Notifs.clearAll();
        }
    }
}
