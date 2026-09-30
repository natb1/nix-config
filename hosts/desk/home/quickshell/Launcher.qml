import QtQuick
import Quickshell
import Quickshell.Io

// The application launcher, Mod+D (niri.kdl): the installed applications in
// the Picker, most launched first. Terminal apps (Terminal=true) run in
// xdg-terminal-exec.
Scope {
    id: launcher

    required property var picker

    // Launches per desktop entry id, kept in Quickshell's state directory.
    property var counts: ({})

    FileView {
        id: countsFile
        path: Quickshell.statePath("launcher-counts.json")
        blockLoading: true
        printErrors: false
        onLoaded: {
            try {
                launcher.counts = JSON.parse(text());
            } catch (e) {
                launcher.counts = {};
            }
        }
    }

    // Each app runs in a scope of its own, as niri's spawns do. Started
    // plainly (entry.execute()) it would stay in quickshell.service's cgroup
    // and be killed with the shell, which restarts on every change to this
    // config (X-Restart-Triggers, home/desktop.nix) and after a crash.
    function launch(entry) {
        counts = Object.assign({}, counts, { [entry.id]: (counts[entry.id] ?? 0) + 1 });
        countsFile.setText(JSON.stringify(counts));
        const cmd = entry.runInTerminal ? ["xdg-terminal-exec", ...entry.command] : entry.command;
        Quickshell.execDetached({
            command: ["systemd-run", "--user", "--scope", "--collect", "--quiet", "--", ...cmd],
            workingDirectory: entry.workingDirectory
        });
    }

    // Apps with their own key in niri.kdl — Ghostty on Mod+Return, Chrome on
    // Mod+3 — are left out of the list.
    readonly property var hotkeyed: ["com.mitchellh.ghostty", "google-chrome", "com.google.Chrome"]

    // Read here, not when the launcher opens: Quickshell scans for desktop
    // entries on first use, and the first list would be empty.
    readonly property var entries: DesktopEntries.applications.values
        .filter(e => !e.noDisplay && !hotkeyed.includes(e.id))
        .sort((a, b) => (counts[b.id] ?? 0) - (counts[a.id] ?? 0) || a.name.localeCompare(b.name))
    readonly property var rows: entries.map(e => ({
        key: e.id,
        lines: [e.name, e.genericName || e.comment],
        icon: e.icon ? Quickshell.iconPath(e.icon, true) : ""
    }))

    // An application installed or removed while the list is open.
    onRowsChanged: {
        if (picker.open && picker.owner === "launcher")
            picker.rows = rows;
    }

    function open() {
        picker.show("run ›", rows, key => {
            const entry = entries.find(e => e.id === key);
            if (entry)
                launch(entry);
        });
        picker.owner = "launcher";
    }

    function toggle() {
        if (picker.open)
            picker.finish("");
        else
            open();
    }
}
