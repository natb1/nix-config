pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Tailscale's state, from `tailscale status --json`, polled while the panel
// is open. Up/down and the exit node go through the CLI too; they need no
// sudo because desk sets operator=n8 (hosts/desk/desktop.nix).
Singleton {
    id: root

    // Polls only while something is looking.
    property bool active: false

    // BackendState: Running, Stopped, NeedsLogin, Starting…; "" if the
    // daemon did not answer.
    property string backend: ""
    readonly property bool up: backend === "Running"
    property string exitNode: ""
    // [{ name, ip, online, current }] for peers offering an exit node.
    property var exitNodes: []
    property int peers: 0
    property int peersOnline: 0
    // Why the last poll failed, if it did.
    property string error: ""
    // Why the last up/down or exit-node change failed, until the next one
    // or the panel closes. Apart from `error`, which the poll that follows
    // every change would clear before it could be read.
    property string actionError: ""

    readonly property string summary: {
        if (actionError !== "")
            return actionError;
        if (error !== "")
            return error;
        if (backend === "")
            return "…";
        if (!up)
            return backend === "Stopped" ? "Off" : backend;
        let s = `${peersOnline}/${peers} peers online`;
        if (exitNode !== "")
            s = `exit via ${exitNode} · ` + s;
        return s;
    }

    function refresh() {
        if (!status.running)
            status.running = true;
    }

    function toggle() {
        run(["tailscale", up ? "down" : "up"]);
    }

    // ip "" clears the exit node.
    function setExitNode(ip) {
        run(["tailscale", "set", "--exit-node=" + ip]);
    }

    function run(cmd) {
        actionError = "";
        action.command = cmd;
        action.running = true;
    }

    onActiveChanged: {
        if (!active)
            actionError = "";
    }

    Timer {
        interval: 5000
        repeat: true
        triggeredOnStart: true
        running: root.active
        onTriggered: root.refresh()
    }

    Process {
        id: status
        command: ["tailscale", "status", "--json"]
        stdout: StdioCollector {
            onStreamFinished: root.parse(text)
        }
        stderr: StdioCollector {
            id: statusErr
        }
        // A failure has no JSON to parse (parse() leaves everything as it
        // was), so drop the last answer here: a stopped daemon is not still
        // "up" with its peers. The collectors finish before this runs.
        onExited: code => {
            if (code === 0)
                return;
            root.backend = "";
            root.exitNode = "";
            root.exitNodes = [];
            root.peers = 0;
            root.peersOnline = 0;
            root.error = statusErr.text.trim().split("\n")[0] || "tailscale failed";
        }
    }

    Process {
        id: action
        stderr: StdioCollector {
            id: actionErr
        }
        onExited: code => {
            if (code !== 0)
                root.actionError = actionErr.text.trim().split("\n")[0] || "tailscale failed";
            root.refresh();
        }
    }

    function parse(text) {
        let s;
        try {
            s = JSON.parse(text);
        } catch (e) {
            return;
        }
        error = "";
        backend = s.BackendState ?? "";
        const peerList = Object.values(s.Peer ?? {});
        peers = peerList.length;
        peersOnline = peerList.filter(p => p.Online).length;
        const current = peerList.find(p => p.ExitNode);
        exitNode = current ? current.HostName : "";
        exitNodes = peerList.filter(p => p.ExitNodeOption).map(p => ({
                    name: p.HostName,
                    ip: (p.TailscaleIPs ?? [])[0] ?? "",
                    online: p.Online,
                    current: !!p.ExitNode
                }));
    }
}
