//@ pragma UseQApplication
// UseQApplication: tray menus (QsMenuAnchor) are drawn as Qt widget menus.

// desk's desktop shell: notifications and status in one panel, no bar.
// Deployed by hosts/desk/home/desktop.nix as the "desk" Quickshell config.
//
//   qs -c desk ipc call panel toggle      Mod+Shift+N (niri.kdl)
//   qs -c desk ipc call notifications dnd
//   qs -c desk ipc call notifications clear
//   qs -c desk ipc call launcher toggle   Mod+D (niri.kdl)
//   qs -c desk ipc call picker …          `pick` (hosts/desk/pick)
//
// docs/desktop-migration.md, "The desktop session", is the design.

import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    Wallpaper {}

    Panel {
        id: panel
    }

    Popups {
        panelOpen: panel.open
    }

    Picker {
        id: picker
    }

    Launcher {
        id: launcher
        picker: picker
    }

    // `pick`'s rows. Its rows file, unique to each run, names its list:
    // a `pick` whose list was replaced (by the launcher, or another `pick`)
    // can't change the one showing. The rows are shown once loaded; a reload
    // that `pick` asked for also ends `busy`.
    property bool pickReloading: false

    FileView {
        id: pickRows
        onLoaded: {
            if (!picker.open || picker.owner !== path)
                return;
            picker.rows = picker.parse(text());
            if (root.pickReloading)
                picker.busy = false;
            root.pickReloading = false;
        }
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

    IpcHandler {
        target: "launcher"

        function toggle(): void {
            launcher.toggle();
        }
    }

    IpcHandler {
        target: "picker"

        function open(rows: string, out: string, prompt: string): void {
            picker.show(prompt, [], key => {
                // `pick` is blocked reading the FIFO, so this write completes.
                Quickshell.execDetached(["sh", "-c", 'printf "%s\\n" "$1" >"$2"', "pick", key, out]);
            });
            picker.owner = rows;
            root.pickReloading = false;
            if (pickRows.path === rows)
                pickRows.reload();
            else
                pickRows.path = rows;
        }
        function busy(rows: string): void {
            if (picker.open && picker.owner === rows)
                picker.busy = true;
        }
        function reload(rows: string): void {
            if (!picker.open || picker.owner !== rows)
                return;
            root.pickReloading = true;
            pickRows.reload();
        }
    }
}
