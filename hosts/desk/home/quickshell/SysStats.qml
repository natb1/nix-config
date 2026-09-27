pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// CPU and memory use, read from /proc while the panel is open — what
// waybar's cpu and memory modules showed.
Singleton {
    id: root

    property bool active: false
    property real cpu: 0      // 0..1, over the last interval
    property real mem: 0      // 0..1, of MemTotal not available
    property real memUsedGiB: 0

    property var last: null

    Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: root.active
        onTriggered: if (!read.running) read.running = true
    }

    Process {
        id: read
        command: ["cat", "/proc/stat", "/proc/meminfo"]
        stdout: StdioCollector {
            onStreamFinished: root.parse(text)
        }
    }

    function parse(text) {
        const lines = text.split("\n");
        const f = lines[0].trim().split(/\s+/).slice(1).map(Number);
        // idle + iowait count as idle.
        const idle = f[3] + f[4];
        const total = f.reduce((a, b) => a + b, 0);
        if (last && total > last.total)
            cpu = 1 - (idle - last.idle) / (total - last.total);
        last = { idle, total };

        const kb = key => {
            const l = lines.find(x => x.startsWith(key + ":"));
            return l ? Number(l.split(/\s+/)[1]) : 0;
        };
        const memTotal = kb("MemTotal");
        const used = memTotal - kb("MemAvailable");
        if (memTotal > 0) {
            mem = used / memTotal;
            memUsedGiB = used / 1048576;
        }
    }
}
