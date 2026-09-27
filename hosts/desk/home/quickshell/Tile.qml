import QtQuick
import QtQuick.Layouts

// One status tile: a glyph, a title and a line of detail. Lit when `on`.
// Left click is the tile's main action, right click its secondary one.
Rectangle {
    id: tile

    property string icon
    property string title
    property string detail
    property bool on: false

    signal clicked
    signal rightClicked

    Layout.fillWidth: true
    implicitHeight: 60
    radius: 12
    color: on ? Theme.accent : (mouse.containsMouse ? Theme.cardHover : Theme.card)

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 10
        spacing: 10

        Text {
            text: tile.icon
            font.family: Theme.iconFont
            font.pixelSize: 22
            color: tile.on ? Theme.accentFg : Theme.fg
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1

            Text {
                Layout.fillWidth: true
                text: tile.title
                elide: Text.ElideRight
                font.family: Theme.font
                font.pixelSize: 13
                font.weight: Font.DemiBold
                color: tile.on ? Theme.accentFg : Theme.fg
            }
            Text {
                Layout.fillWidth: true
                text: tile.detail
                visible: text !== ""
                elide: Text.ElideRight
                font.family: Theme.font
                font.pixelSize: 11
                color: tile.on ? Theme.accentFg : Theme.dim
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: e => e.button === Qt.RightButton ? tile.rightClicked() : tile.clicked()
    }
}
