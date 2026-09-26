// `pick`: a dmenu-style list, like `fuzzel --dmenu --index`, whose rows can
// be several lines. Run one-shot by the `pick` wrapper (./default.nix), not
// part of the desk shell; Theme.qml is copied in from ../home/quickshell.
//
//   PICK_ROWS    file with one row per line; its tab-separated fields are
//                drawn as the row's lines, the first one bright
//   PICK_OUT     where the chosen row's index (from 0) is written
//   PICK_PROMPT  shown before the query
//   PICK_MESG    a line under the query, if set
//
// Typing filters: each space-separated word must appear, letters in order,
// somewhere in the row. Enter picks, Escape or a click outside cancels.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property var rows: input.text().split("\n")
        .filter(line => line !== "")
        .map((line, index) => ({ index: index, fields: line.split("\t") }))
    readonly property string mesg: Quickshell.env("PICK_MESG") ?? ""
    property string query: ""
    readonly property var matches: filter(rows, query)

    // How far into `text` the letters of `word` are spread (0 when they are
    // one run), or -1 when they aren't all there in order.
    function spread(text, word) {
        const at = text.indexOf(word);
        if (at >= 0)
            return 0;
        let from = 0, first = -1;
        for (const c of word) {
            const i = text.indexOf(c, from);
            if (i < 0)
                return -1;
            if (first < 0)
                first = i;
            from = i + 1;
        }
        return from - first - word.length;
    }

    // Rows every word matches, tightest matches first; ties keep input order.
    function filter(rows, query) {
        const words = query.toLowerCase().split(" ").filter(w => w !== "");
        if (words.length === 0)
            return rows;
        const scored = [];
        for (const row of rows) {
            const text = row.fields.join(" ").toLowerCase();
            let score = 0;
            for (const word of words) {
                const s = spread(text, word);
                if (s < 0) {
                    score = -1;
                    break;
                }
                score += s;
            }
            if (score >= 0)
                scored.push({ row: row, score: score });
        }
        scored.sort((a, b) => a.score - b.score || a.row.index - b.row.index);
        return scored.map(s => s.row);
    }

    function finish(index) {
        if (index >= 0)
            output.setText(index + "\n");
        Qt.quit();
    }

    FileView {
        id: input
        path: Quickshell.env("PICK_ROWS")
        blockLoading: true
    }

    FileView {
        id: output
        path: Quickshell.env("PICK_OUT")
        blockWrites: true
    }

    PanelWindow {
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        color: Theme.scrim
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-pick"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        MouseArea {
            anchors.fill: parent
            onClicked: root.finish(-1)
        }

        Rectangle {
            id: box
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(parent.height * 0.12)
            width: Math.min(900, parent.width - 64)
            height: layout.implicitHeight + 24
            radius: 14
            color: Theme.bg
            border.color: Theme.border

            // Clicks on the box itself don't cancel.
            MouseArea {
                anchors.fill: parent
            }

            ColumnLayout {
                id: layout
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 8
                    Layout.rightMargin: 8
                    Layout.topMargin: 4
                    spacing: 8

                    Text {
                        text: Quickshell.env("PICK_PROMPT") ?? ""
                        visible: text !== ""
                        color: Theme.accent
                        font.family: Theme.font
                        font.pixelSize: 18
                    }

                    TextInput {
                        id: field
                        Layout.fillWidth: true
                        focus: true
                        color: Theme.fg
                        selectionColor: Theme.accent
                        selectedTextColor: Theme.accentFg
                        font.family: Theme.font
                        font.pixelSize: 18
                        onTextChanged: {
                            root.query = text;
                            list.currentIndex = 0;
                        }

                        Keys.onPressed: event => {
                            const ctrl = event.modifiers & Qt.ControlModifier;
                            const page = Math.max(1, Math.floor(list.height / 76));
                            if (event.key === Qt.Key_Escape || (ctrl && event.key === Qt.Key_C))
                                root.finish(-1);
                            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                root.finish(list.currentItem ? list.currentItem.row.index : -1);
                            else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J)))
                                list.currentIndex = Math.min(list.count - 1, list.currentIndex + 1);
                            else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K)))
                                list.currentIndex = Math.max(0, list.currentIndex - 1);
                            else if (event.key === Qt.Key_PageDown)
                                list.currentIndex = Math.min(list.count - 1, list.currentIndex + page);
                            else if (event.key === Qt.Key_PageUp)
                                list.currentIndex = Math.max(0, list.currentIndex - page);
                            else
                                return;
                            event.accepted = true;
                        }
                    }

                    Text {
                        text: root.matches.length + "/" + root.rows.length
                        color: Theme.dim
                        font.family: Theme.font
                        font.pixelSize: 13
                        font.features: { "tnum": 1 }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 8
                    text: root.mesg
                    visible: text !== ""
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 1
                    color: Theme.border
                }

                ListView {
                    id: list
                    Layout.fillWidth: true
                    implicitHeight: Math.min(contentHeight, box.parent.height * 0.7)
                    clip: true
                    spacing: 2
                    model: root.matches
                    highlightMoveDuration: 0
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                        id: item

                        required property var modelData
                        required property int index
                        readonly property var row: modelData
                        readonly property bool current: ListView.isCurrentItem

                        width: list.width
                        implicitHeight: lines.implicitHeight + 16
                        radius: 10
                        color: current ? Theme.cardHover : (hover.containsMouse ? Theme.card : "transparent")

                        Rectangle {
                            visible: item.current
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: 3
                            height: parent.height - 20
                            radius: 2
                            color: Theme.accent
                        }

                        ColumnLayout {
                            id: lines
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            spacing: 2

                            Repeater {
                                model: item.row.fields

                                Text {
                                    required property string modelData
                                    required property int index
                                    Layout.fillWidth: true
                                    text: modelData
                                    elide: Text.ElideRight
                                    color: index === 0 ? Theme.fg : Theme.dim
                                    font.family: Theme.font
                                    font.pixelSize: index === 0 ? 15 : 13
                                    font.weight: index === 0 ? Font.Medium : Font.Normal
                                }
                            }
                        }

                        MouseArea {
                            id: hover
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.finish(item.row.index)
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 8
                    visible: list.count === 0
                    text: "No match"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 13
                }
            }
        }
    }
}
