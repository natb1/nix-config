import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Services.SystemTray
import Quickshell.Widgets

// The Mod+Shift+N panel: clock, status tiles, volume, what is playing, any
// tray icons, and the notification history, all on one sheet down the right
// edge. There is no bar; this is the whole of the desktop's chrome.
//
// It covers the screen while open so that a click anywhere else, or Esc,
// closes it.
PanelWindow {
    id: panel

    property bool open: false

    function close() {
        open = false;
    }

    // Launch something from the panel, and get out of its way. In a scope of
    // its own, so a shell restart doesn't kill it (see Launcher.qml).
    function launch(cmd) {
        Quickshell.execDetached(["systemd-run", "--user", "--scope", "--collect", "--quiet", "--", ...cmd]);
        close();
    }

    visible: open
    onOpenChanged: {
        if (open)
            Notifs.hideAllPopups();
        showExitNodes = false;
    }

    color: "transparent"
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-panel"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Binding {
        target: Tailscale
        property: "active"
        value: panel.open
    }
    Binding {
        target: SysStats
        property: "active"
        value: panel.open
    }

    readonly property var btAdapter: Bluetooth.defaultAdapter
    readonly property var btConnected: btAdapter ? btAdapter.devices.values.filter(d => d.connected) : []
    readonly property var wifi: Networking.devices.values.find(d => d.type === DeviceType.Wifi) ?? null
    readonly property var wifiNetwork: wifi ? wifi.networks.values.find(n => n.connected) ?? null : null
    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var player: Mpris.players.values.find(p => p.isPlaying) ?? Mpris.players.values[0] ?? null
    // blueman's icon is the Bluetooth tile now. Anything else that asks for
    // a tray icon (Steam) still gets one.
    readonly property var trayItems: SystemTray.items.values.filter(i => !/blueman/i.test(i.id))
    property bool showExitNodes: false

    PwObjectTracker {
        objects: [panel.sink]
    }

    Shortcut {
        sequence: "Escape"
        onActivated: panel.close()
    }

    // The scrim: click outside the sheet to close.
    Rectangle {
        anchors.fill: parent
        color: Theme.scrim

        MouseArea {
            anchors.fill: parent
            onClicked: panel.close()
        }
    }

    Rectangle {
        id: sheet
        anchors {
            top: parent.top
            bottom: parent.bottom
            right: parent.right
            margins: 8
        }
        width: 440
        radius: 16
        color: Theme.bg
        border.color: Theme.border

        // Swallow clicks so they do not reach the scrim.
        MouseArea {
            anchors.fill: parent
        }


        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 12

            // Clock. With no bar, this is the only one on screen.
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 4

                SystemClock {
                    id: clock
                    precision: SystemClock.Minutes
                }

                Text {
                    text: Qt.formatDateTime(clock.date, "HH:mm")
                    font.family: Theme.font
                    font.pixelSize: 34
                    font.weight: Font.Light
                    color: Theme.fg
                }
                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 8
                    text: Qt.formatDateTime(clock.date, "dddd\nd MMMM")
                    font.family: Theme.font
                    font.pixelSize: 12
                    color: Theme.dim
                }
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 8
                rowSpacing: 8

                // Left: up/down. Right: choose an exit node.
                Tile {
                    icon: Theme.icons.tailscale
                    title: "Tailscale"
                    detail: Tailscale.summary
                    on: Tailscale.up
                    onClicked: Tailscale.toggle()
                    onRightClicked: panel.showExitNodes = !panel.showExitNodes
                }

                // Status only: turning Bluetooth off would also cut the
                // iPhone's notifications (hosts/desk/iphone.nix), so a click
                // opens blueman instead of toggling power.
                Tile {
                    icon: panel.btAdapter?.enabled ? Theme.icons.bluetooth : Theme.icons.bluetoothOff
                    title: "Bluetooth"
                    detail: {
                        const a = panel.btAdapter;
                        if (!a)
                            return "No adapter";
                        if (!a.enabled)
                            return "Off";
                        if (panel.btConnected.length === 0)
                            return "Nothing connected";
                        return panel.btConnected.map(d => d.name + (d.batteryAvailable ? ` ${Math.round(d.battery * 100)}%` : "")).join(", ");
                    }
                    on: panel.btAdapter?.enabled ?? false
                    onClicked: panel.launch(["blueman-manager"])
                }

                // Status only, for the same reason: Wi-Fi is desk's only
                // link, and the Mac reaches it over that.
                Tile {
                    icon: panel.wifiNetwork ? Theme.icons.wifi : Theme.icons.wifiOff
                    title: panel.wifiNetwork ? panel.wifiNetwork.name : "Wi-Fi"
                    detail: {
                        const n = panel.wifiNetwork;
                        if (!Networking.wifiEnabled)
                            return "Off";
                        if (!n)
                            return "Not connected";
                        return `${Math.round(n.signalStrength * 100)}% signal`;
                    }
                    on: panel.wifiNetwork !== null
                    onClicked: panel.launch(["xdg-terminal-exec", "nmtui"])
                }

                Tile {
                    icon: Theme.icons.cpu
                    title: `CPU ${Math.round(SysStats.cpu * 100)}%`
                    detail: `Memory ${Math.round(SysStats.mem * 100)}% · ${SysStats.memUsedGiB.toFixed(1)} GiB`
                    onClicked: panel.launch(["xdg-terminal-exec", "top"])
                }
            }

            // Exit nodes, under the Tailscale tile's right click.
            ColumnLayout {
                Layout.fillWidth: true
                visible: panel.showExitNodes
                spacing: 2

                Repeater {
                    model: [{ name: "No exit node", ip: "", online: true, current: Tailscale.exitNode === "" }].concat(Tailscale.exitNodes)

                    Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 30
                        radius: 8
                        color: exitMouse.containsMouse ? Theme.cardHover : "transparent"

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            text: (parent.modelData.current ? "● " : "○ ") + parent.modelData.name + (parent.modelData.online ? "" : " (offline)")
                            font.family: Theme.font
                            font.pixelSize: 13
                            color: parent.modelData.current ? Theme.accent : Theme.fg
                        }

                        MouseArea {
                            id: exitMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                Tailscale.setExitNode(parent.modelData.ip);
                                panel.showExitNodes = false;
                            }
                        }
                    }
                }

                Text {
                    Layout.leftMargin: 12
                    visible: Tailscale.exitNodes.length === 0
                    text: "No peer offers an exit node"
                    font.family: Theme.font
                    font.pixelSize: 12
                    color: Theme.dim
                }
            }

            // Volume: the glyph mutes, the bar sets, the name opens the mixer.
            RowLayout {
                Layout.fillWidth: true
                visible: panel.sink !== null && panel.sink.audio !== null
                spacing: 10

                Text {
                    text: panel.sink?.audio?.muted ? Theme.icons.volumeOff : Theme.icons.volume
                    font.family: Theme.iconFont
                    font.pixelSize: 22
                    color: Theme.fg

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.sink.audio.muted = !panel.sink.audio.muted
                    }
                }

                Item {
                    id: slider
                    Layout.fillWidth: true
                    implicitHeight: 24

                    readonly property real value: Math.min(panel.sink?.audio?.volume ?? 0, 1)

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 6
                        radius: 3
                        color: Theme.border

                        Rectangle {
                            width: parent.width * slider.value
                            height: parent.height
                            radius: 3
                            color: panel.sink?.audio?.muted ? Theme.dim : Theme.accent
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        function set(x) {
                            panel.sink.audio.volume = Math.max(0, Math.min(1, x / width));
                        }
                        onPressed: e => set(e.x)
                        onPositionChanged: e => set(e.x)
                        onWheel: e => panel.sink.audio.volume = Math.max(0, Math.min(1, slider.value + (e.angleDelta.y > 0 ? 0.05 : -0.05)))
                    }
                }

                Text {
                    text: Math.round((panel.sink?.audio?.volume ?? 0) * 100) + "%"
                    font.family: Theme.font
                    font.pixelSize: 12
                    color: Theme.dim
                    Layout.preferredWidth: 36

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.launch(["pwvucontrol"])
                    }
                }
            }

            // Now playing, when anything is.
            Rectangle {
                Layout.fillWidth: true
                visible: panel.player !== null
                implicitHeight: 56
                radius: 12
                color: Theme.card

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 8
                    spacing: 10

                    Text {
                        text: Theme.icons.music
                        font.family: Theme.iconFont
                        font.pixelSize: 20
                        color: Theme.dim
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        Text {
                            Layout.fillWidth: true
                            text: panel.player?.trackTitle || panel.player?.identity || ""
                            elide: Text.ElideRight
                            font.family: Theme.font
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            color: Theme.fg
                        }
                        Text {
                            Layout.fillWidth: true
                            text: panel.player?.trackArtist ?? ""
                            visible: text !== ""
                            elide: Text.ElideRight
                            font.family: Theme.font
                            font.pixelSize: 11
                            color: Theme.dim
                        }
                    }

                    Repeater {
                        model: [
                            { icon: Theme.icons.prev, enabled: panel.player?.canGoPrevious ?? false, act: () => panel.player.previous() },
                            { icon: panel.player?.isPlaying ? Theme.icons.pause : Theme.icons.play, enabled: panel.player?.canTogglePlaying ?? false, act: () => panel.player.togglePlaying() },
                            { icon: Theme.icons.next, enabled: panel.player?.canGoNext ?? false, act: () => panel.player.next() }
                        ]

                        Text {
                            required property var modelData
                            text: modelData.icon
                            font.family: Theme.iconFont
                            font.pixelSize: 22
                            color: modelData.enabled ? Theme.fg : Theme.border

                            MouseArea {
                                anchors.fill: parent
                                enabled: parent.modelData.enabled
                                cursorShape: Qt.PointingHandCursor
                                onClicked: parent.modelData.act()
                            }
                        }
                    }
                }
            }

            // Tray icons, for apps that insist on one. Left click activates,
            // right click is the app's menu.
            Flow {
                Layout.fillWidth: true
                visible: panel.trayItems.length > 0
                spacing: 6

                Repeater {
                    model: panel.trayItems

                    Rectangle {
                        id: trayButton
                        required property var modelData
                        implicitWidth: 36
                        implicitHeight: 36
                        radius: 10
                        color: trayMouse.containsMouse ? Theme.cardHover : Theme.card

                        IconImage {
                            anchors.centerIn: parent
                            implicitSize: 20
                            source: trayButton.modelData.icon
                        }

                        QsMenuAnchor {
                            id: trayMenu
                            menu: trayButton.modelData.menu
                            anchor.item: trayButton
                            anchor.edges: Edges.Bottom
                        }

                        MouseArea {
                            id: trayMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: e => {
                                const item = trayButton.modelData;
                                if (e.button === Qt.RightButton || item.onlyMenu) {
                                    if (item.hasMenu)
                                        trayMenu.open();
                                } else {
                                    item.activate();
                                }
                            }
                        }
                    }
                }
            }

            // Notification history.
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                Layout.leftMargin: 4
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: "Notifications" + (Notifs.history.length ? `  ${Notifs.history.length}` : "")
                    font.family: Theme.font
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                    color: Theme.fg
                }

                Rectangle {
                    implicitWidth: dndRow.implicitWidth + 16
                    implicitHeight: 28
                    radius: 8
                    color: Notifs.dnd ? Theme.accent : (dndMouse.containsMouse ? Theme.cardHover : Theme.card)

                    Row {
                        id: dndRow
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            text: Notifs.dnd ? Theme.icons.bellOff : Theme.icons.bell
                            font.family: Theme.iconFont
                            font.pixelSize: 15
                            color: Notifs.dnd ? Theme.accentFg : Theme.fg
                        }
                        Text {
                            text: "Do not disturb"
                            font.family: Theme.font
                            font.pixelSize: 12
                            color: Notifs.dnd ? Theme.accentFg : Theme.fg
                        }
                    }

                    MouseArea {
                        id: dndMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Notifs.dnd = !Notifs.dnd
                    }
                }

                Rectangle {
                    visible: Notifs.history.length > 0
                    implicitWidth: clearText.implicitWidth + 16
                    implicitHeight: 28
                    radius: 8
                    color: clearMouse.containsMouse ? Theme.cardHover : Theme.card

                    Text {
                        id: clearText
                        anchors.centerIn: parent
                        text: "Clear"
                        font.family: Theme.font
                        font.pixelSize: 12
                        color: Theme.fg
                    }

                    MouseArea {
                        id: clearMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Notifs.clearAll()
                    }
                }
            }

            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 8
                model: Notifs.history
                boundsBehavior: Flickable.StopAtBounds

                delegate: NotificationCard {
                    required property var modelData
                    notif: modelData
                    width: ListView.view.width
                }

                Text {
                    anchors.centerIn: parent
                    visible: parent.count === 0
                    text: "No notifications"
                    font.family: Theme.font
                    font.pixelSize: 13
                    color: Theme.dim
                }
            }
        }
    }
}
