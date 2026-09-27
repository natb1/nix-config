import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets

// One notification, as a pop-up or as a row of the panel's history.
// A click on the body runs its default action; × dismisses it (from the
// history too); its other actions are buttons.
Rectangle {
    id: card

    required property var notif
    // Pop-ups time out (unless critical); history rows do not.
    property bool popup: false

    readonly property bool critical: Notifs.isCritical(notif)
    readonly property var defaultAction: Notifs.defaultAction(notif)
    // The notification's image, else its app icon. Either can be a themed
    // icon name (notify-send -i puts the name in the image hint), and a name
    // the theme lacks would draw Qt's missing-icon checkerboard, so it falls
    // back to the name's -symbolic variant and then to no icon at all.
    readonly property string iconSource: {
        for (const src of [notif.image, notif.appIcon]) {
            if (!src)
                continue;
            if (src.startsWith("/"))
                return "file://" + src;
            const name = src.startsWith("image://icon/") ? src.slice(13).split("?")[0] : src;
            if (name === src && src.includes("://"))
                return src;
            for (const n of [name, name + "-symbolic"])
                if (Quickshell.hasThemeIcon(n))
                    return Quickshell.iconPath(n);
        }
        return "";
    }

    implicitHeight: body.implicitHeight + 24
    radius: 12
    color: hover.hovered ? Theme.cardHover : Theme.card
    border.width: critical ? 2 : 1
    border.color: critical ? Theme.critical : Theme.border

    HoverHandler {
        id: hover
    }

    Timer {
        interval: Math.max(Notifs.popupTimeout(card.notif), 1)
        running: card.popup && Notifs.popupTimeout(card.notif) > 0 && !hover.hovered
        onTriggered: Notifs.timedOut(card.notif)
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: card.defaultAction ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
            if (card.defaultAction)
                card.defaultAction.invoke();
            else if (card.popup)
                Notifs.hide(card.notif);
        }
    }

    RowLayout {
        id: body
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            margins: 12
        }
        spacing: 12

        IconImage {
            id: icon
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 2
            implicitSize: 36
            source: card.iconSource
            visible: card.iconSource !== ""
            // Symbolic icons are drawn dark, for light themes; tint them.
            layer.enabled: card.iconSource.includes("-symbolic")
            layer.effect: MultiEffect {
                brightness: 1
                colorization: 1
                colorizationColor: card.critical ? Theme.critical : Theme.fg
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 3

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    Layout.fillWidth: true
                    text: [card.notif.appName || "", Notifs.ago(card.notif)].filter(s => s !== "").join(" · ")
                    elide: Text.ElideRight
                    font.family: Theme.font
                    font.pixelSize: 11
                    color: card.critical ? Theme.critical : Theme.dim
                }

                Text {
                    text: Theme.icons.close
                    font.family: Theme.iconFont
                    font.pixelSize: 16
                    color: closeMouse.containsMouse ? Theme.fg : Theme.dim

                    MouseArea {
                        id: closeMouse
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: card.notif.dismiss()
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: card.notif.summary
                visible: text !== ""
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                font.family: Theme.font
                font.pixelSize: 14
                font.weight: Font.DemiBold
                color: Theme.fg
            }

            Text {
                Layout.fillWidth: true
                text: card.notif.body
                visible: text !== ""
                textFormat: Text.StyledText
                wrapMode: Text.Wrap
                maximumLineCount: card.popup ? 4 : 8
                elide: Text.ElideRight
                font.family: Theme.font
                font.pixelSize: 13
                color: Theme.fg
                linkColor: Theme.accent
                onLinkActivated: link => Qt.openUrlExternally(link)
            }

            Flow {
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 6
                visible: actionRepeater.count > 0

                Repeater {
                    id: actionRepeater
                    model: card.notif.actions.filter(a => a.identifier !== "default")

                    Rectangle {
                        required property var modelData
                        implicitWidth: label.implicitWidth + 20
                        implicitHeight: 28
                        radius: 8
                        color: actionMouse.containsMouse ? Theme.accent : Theme.border

                        Text {
                            id: label
                            anchors.centerIn: parent
                            text: parent.modelData.text
                            font.family: Theme.font
                            font.pixelSize: 12
                            color: actionMouse.containsMouse ? Theme.accentFg : Theme.fg
                        }

                        MouseArea {
                            id: actionMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: parent.modelData.invoke()
                        }
                    }
                }
            }
        }
    }
}
