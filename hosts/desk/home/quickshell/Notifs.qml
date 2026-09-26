pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Notifications

// The notification daemon: owns org.freedesktop.Notifications, keeps the
// history the panel lists, and decides what pops up.
//
// Every notification is tracked, so it stays in the history until it is
// dismissed there or its sender closes it (tether-ancs-watch withdraws its
// alert with CloseNotification). A pop-up is only a view onto one: it times
// out, the notification stays. Critical ones never time out — the pop-up
// stays on screen until dismissed, which is what the iPhone, iCloud and
// backup alerts rely on (hosts/desk/iphone.nix: a normal pop-up let a 16 h
// outage go unseen).
Singleton {
    id: root

    // Newest first.
    readonly property var history: server.trackedNotifications.values.slice().reverse()
    // What is on screen as a pop-up right now, newest first.
    property var popups: []
    // Do not disturb: no pop-ups except critical ones. History still fills.
    property bool dnd: false
    // Arrival time by id; the protocol carries none.
    property var arrived: ({})

    // For relative times ("5m"), ticking once a minute.
    readonly property date now: clock.date
    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    NotificationServer {
        id: server
        keepOnReload: true
        persistenceSupported: true
        bodySupported: true
        bodyMarkupSupported: true
        bodyHyperlinksSupported: true
        actionsSupported: true
        imageSupported: true

        onNotification: n => {
            n.tracked = true;
            root.arrived[n.id] = new Date();
            n.closed.connect(() => root.hide(n));
            if (!root.dnd || root.isCritical(n))
                root.popups = [n].concat(root.popups);
        }
    }

    function isCritical(n) {
        return n.urgency === NotificationUrgency.Critical;
    }

    // How long a pop-up stays, in ms; 0 is "until dismissed". The sender's
    // expire_timeout is honoured when it sets one.
    function popupTimeout(n) {
        if (isCritical(n) || n.resident)
            return 0;
        return n.expireTimeout > 0 ? n.expireTimeout * 1000 : 6000;
    }

    function hide(n) {
        popups = popups.filter(p => p && p !== n);
    }

    // A pop-up's timer ran out. Transient notifications are not meant to be
    // kept, so they leave the history too.
    function timedOut(n) {
        hide(n);
        if (n.transient)
            n.expire();
    }

    function hideAllPopups() {
        popups = [];
    }

    function clearAll() {
        for (const n of server.trackedNotifications.values.slice())
            n.dismiss();
    }

    // The action a click on the notification's body runs, if it has one.
    function defaultAction(n) {
        return n.actions.find(a => a.identifier === "default") ?? null;
    }

    function ago(n) {
        const t = arrived[n.id];
        if (!t)
            return "";
        const mins = Math.floor((now - t) / 60000);
        if (mins < 1)
            return "now";
        if (mins < 60)
            return mins + "m";
        if (mins < 24 * 60)
            return Math.floor(mins / 60) + "h";
        return Qt.formatDateTime(t, "d MMM");
    }
}
