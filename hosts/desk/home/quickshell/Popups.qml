import QtQuick
import Quickshell
import Quickshell.Wayland

// Pop-ups, stacked down the top-right corner. Hidden while the panel is open,
// since the panel lists the same notifications.
//
// The window is the full height of the screen and only the cards take
// input (the mask); resizing a layer surface to fit the stack lagged a card
// behind and clipped it.
PanelWindow {
    id: popups

    property bool panelOpen: false

    visible: !panelOpen && Notifs.popups.length > 0
    color: "transparent"
    anchors {
        top: true
        bottom: true
        right: true
    }
    margins {
        top: 8
        right: 8
    }
    implicitWidth: 400
    mask: Region {
        item: stack
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-popups"

    Column {
        id: stack
        width: parent.width
        spacing: 8

        Repeater {
            // Five at most; the rest are in the panel. A ScriptModel, not the
            // array itself: a new array would recreate every card, and so
            // restart every pop-up's timer, at each arrival or hide.
            model: ScriptModel {
                values: Notifs.popups.slice(0, 5)
            }

            NotificationCard {
                required property var modelData
                notif: modelData
                popup: true
                width: stack.width
            }
        }
    }
}
