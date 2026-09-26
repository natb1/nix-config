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
    property string error: ""

    readonly property string summary: {
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
        action.command = cmd;
        action.running = true;
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
        onExited: code => {
            if (code !== 0 && root.backend === "")
                root.error = statusErr.text.trim().split("\n")[0] || "tailscale failed";
        }
    }

    Process {
        id: action
        stderr: StdioCollector {
            onStreamFinished: {
                const msg = text.trim();
                if (msg !== "")
                    root.error = msg.split("\n")[0];
            }
        }
        onExited: root.refresh()
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
