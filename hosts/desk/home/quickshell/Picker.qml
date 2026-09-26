import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// A dmenu-style list whose rows can be several lines, opened over IPC by a
// script that waits for the answer (see shell.qml; the rebuild menu,
// hosts/desk/rebuild-menu.nix, is the one user):
//
//   rows  a file, one row per line: a key, then the lines to show, all
//         tab-separated; the first line shown is the bright one
//   out   a FIFO the script is reading; the chosen row's key is written to
//         it, or an empty line when cancelled
//
// The script can rewrite `rows` while the list is open and call reload(),
// so a list can open at once and fill in as the script learns more. The
// selection follows its key across a reload.
//
// Typing filters: each space-separated word must appear, letters in order,
// somewhere in the row. Enter picks, Escape or a click outside cancels.
PanelWindow {
    id: picker

    property bool open: false
    property string out: ""
    property string prompt: ""
    property string mesg: ""
    property string query: ""
    property string selectedKey: ""

    readonly property var rows: rowsFile.text().split("\n")
        .filter(line => line !== "")
        .map((line, index) => {
            const fields = line.split("\t");
            return { index: index, key: fields[0], lines: fields.slice(1) };
        })
    readonly property var matches: filter(rows, query)

    function show(rowsPath, outPath, promptText) {
        if (open)
            answer("");
        rowsFile.path = rowsPath;
        rowsFile.reload();
        out = outPath;
        prompt = promptText;
        mesg = "";
        field.text = "";
        selectedKey = rows.length > 0 ? rows[0].key : "";
        open = true;
    }

    function reload(mesgText) {
        if (!open)
            return;
        mesg = mesgText;
        rowsFile.reload();
    }

    function answer(key) {
        if (!open)
            return;
        open = false;
        // The script is blocked reading the FIFO, so this write completes.
        Quickshell.execDetached(["sh", "-c", 'printf "%s\\n" "$1" >"$2"', "picker", key, out]);
    }

    // How far into `text` the letters of `word` are spread (0 when they are
    // one run), or -1 when they aren't all there in order.
    function spread(text, word) {
        if (text.indexOf(word) >= 0)
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
            const text = row.lines.join(" ").toLowerCase();
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

    function select(i) {
        if (i >= 0 && i < matches.length)
            selectedKey = matches[i].key;
    }

    function move(by) {
        list.currentIndex = Math.max(0, Math.min(list.count - 1, list.currentIndex + by));
        select(list.currentIndex);
    }

    // Keep the selected row selected when the rows change under it; fall
    // back to the first.
    onMatchesChanged: {
        const i = matches.findIndex(r => r.key === selectedKey);
        list.currentIndex = Math.max(0, i);
        if (i < 0)
            select(0);
    }

    visible: open
    color: Theme.scrim
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-picker"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    FileView {
        id: rowsFile
        blockLoading: true
    }

    MouseArea {
        anchors.fill: parent
        onClicked: picker.answer("")
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
                    text: picker.prompt
                    visible: text !== ""
                    color: Theme.accent
                    font.family: Theme.font
                    font.pixelSize: 18
                }

                TextInput {
                    id: field
                    Layout.fillWidth: true
                    focus: picker.open
                    color: Theme.fg
                    selectionColor: Theme.accent
                    selectedTextColor: Theme.accentFg
                    font.family: Theme.font
                    font.pixelSize: 18
                    onTextChanged: {
                        picker.query = text;
                        picker.select(0);
                        list.currentIndex = 0;
                    }

                    Keys.onPressed: event => {
                        const ctrl = event.modifiers & Qt.ControlModifier;
                        const page = Math.max(1, Math.floor(list.height / 76));
                        if (event.key === Qt.Key_Escape || (ctrl && event.key === Qt.Key_C))
                            picker.answer("");
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            picker.answer(list.count > 0 ? picker.selectedKey : "");
                        else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J)))
                            picker.move(1);
                        else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K)))
                            picker.move(-1);
                        else if (event.key === Qt.Key_PageDown)
                            picker.move(page);
                        else if (event.key === Qt.Key_PageUp)
                            picker.move(-page);
                        else
                            return;
                        event.accepted = true;
                    }
                }

                Text {
                    text: picker.matches.length + "/" + picker.rows.length
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 13
                    font.features: { "tnum": 1 }
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                text: picker.mesg
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
                implicitHeight: Math.min(contentHeight, picker.height * 0.7)
                clip: true
                spacing: 2
                model: picker.matches
                highlightMoveDuration: 0
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: item

                    required property var modelData
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
                            model: item.row.lines

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
                        onClicked: picker.answer(item.row.key)
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
