import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Wayland

// The desktop's one list to pick from, dmenu-style: the launcher (Mod+D,
// Launcher.qml) and, through `pick` (hosts/desk/pick), the rebuild and
// power menus. A row can be several lines, and have an icon.
//
// show(prompt, rows, callback) opens it; rows are { key, lines, icon? }, and
// callback gets the chosen row's key, or "" when cancelled (including when
// something else opens the list over it). `rows` and `busy` can change while
// it is open — a list can open at once and fill in — and the selection
// follows its key.
//
// Typing filters: each space-separated word must appear, letters in order,
// somewhere in the row. The first ten rows are numbered; with nothing typed,
// or with Alt, a digit picks its row. Enter picks, Escape or a click
// outside cancels.
PanelWindow {
    id: picker

    property bool open: false
    property string prompt: ""
    property var rows: []
    // Shown as a spinning icon: the rows are still being worked out.
    property bool busy: false
    property var callback: null
    // Who opened it, for them to recognise their list later; show() clears it.
    property string owner: ""
    property string query: ""
    property string selectedKey: ""

    readonly property var matches: filter(rows, query)

    function show(promptText, newRows, onPicked) {
        finish("");
        prompt = promptText;
        rows = newRows;
        busy = false;
        owner = "";
        callback = onPicked;
        field.text = "";
        selectedKey = rows.length > 0 ? rows[0].key : "";
        list.currentIndex = 0;
        open = true;
    }

    function finish(key) {
        if (!open)
            return;
        open = false;
        busy = false;
        const cb = callback;
        callback = null;
        cb(key);
    }

    // `pick`'s rows: one per line, a key and then the lines to show, all
    // tab-separated.
    function parse(text) {
        return text.split("\n").filter(line => line !== "").map(line => {
            const fields = line.split("\t");
            return { key: fields[0], lines: fields.slice(1) };
        });
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
        rows.forEach((row, index) => {
            const text = row.lines.join(" ").toLowerCase();
            let score = 0;
            for (const word of words) {
                const s = spread(text, word);
                if (s < 0)
                    return;
                score += s;
            }
            scored.push({ row: row, score: score, index: index });
        });
        scored.sort((a, b) => a.score - b.score || a.index - b.index);
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

    MouseArea {
        anchors.fill: parent
        onClicked: picker.finish("")
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
                        const alt = event.modifiers & Qt.AltModifier;
                        const page = Math.max(1, Math.floor(list.height / 76));
                        const digit = event.key >= Qt.Key_0 && event.key <= Qt.Key_9;
                        if (event.key === Qt.Key_Escape || (ctrl && event.key === Qt.Key_C))
                            picker.finish("");
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            picker.finish(list.count > 0 ? picker.selectedKey : "");
                        else if (digit && (alt || field.text === "")) {
                            // 1–9, then 0 for the tenth.
                            const i = (event.key - Qt.Key_0 + 9) % 10;
                            if (i < picker.matches.length)
                                picker.finish(picker.matches[i].key);
                        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J)))
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
                    text: Theme.icons.sync
                    visible: picker.busy
                    color: Theme.dim
                    font.family: Theme.iconFont
                    font.pixelSize: 16

                    RotationAnimation on rotation {
                        running: picker.busy
                        from: 0
                        to: 360
                        duration: 1000
                        loops: Animation.Infinite
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
                    required property int index
                    readonly property var row: modelData
                    readonly property bool current: ListView.isCurrentItem

                    width: list.width
                    implicitHeight: Math.max(lines.implicitHeight, 32) + 16
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

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 14
                        spacing: 12

                        Text {
                            Layout.preferredWidth: 14
                            Layout.alignment: Qt.AlignVCenter
                            horizontalAlignment: Text.AlignHCenter
                            text: item.index < 10 ? String((item.index + 1) % 10) : ""
                            color: item.current ? Theme.accent : Theme.dim
                            font.family: Theme.font
                            font.pixelSize: 13
                            font.features: { "tnum": 1 }
                        }

                        IconImage {
                            visible: !!item.row.icon
                            source: item.row.icon ?? ""
                            implicitSize: 32
                            Layout.alignment: Qt.AlignVCenter
                        }

                        ColumnLayout {
                            id: lines
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 2

                            Repeater {
                                model: item.row.lines

                                Text {
                                    required property string modelData
                                    required property int index
                                    Layout.fillWidth: true
                                    visible: modelData !== ""
                                    text: modelData
                                    elide: Text.ElideRight
                                    color: index === 0 ? Theme.fg : Theme.dim
                                    font.family: Theme.font
                                    font.pixelSize: index === 0 ? 15 : 13
                                    font.weight: index === 0 ? Font.Medium : Font.Normal
                                }
                            }
                        }
                    }

                    MouseArea {
                        id: hover
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: picker.finish(item.row.key)
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                // Not while `pick`'s rows are still loading.
                visible: list.count === 0 && picker.rows.length > 0
                text: "No match"
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: 13
            }
        }
    }
}
