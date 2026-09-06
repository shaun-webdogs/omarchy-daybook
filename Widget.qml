import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "shahin.daybook"
    readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
    readonly property var active: service ? service.state.active : null
    readonly property string focusTime: {
        if (!service || !service.ready) return "–:––"
        var minutes = Math.floor((service.state.summary.elapsed_ms || 0) / 60000)
        return String(Math.floor(minutes / 60)) + ":" + String(minutes % 60).padStart(2, "0")
    }
    property bool opened: false
    property bool popoutSwitchClosing: false
    readonly property real openPanelIndicatorWidth: button.labelWidth
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function open() { opened = true }
    function close() { opened = false }
    function toggle() { opened = !opened }
    function closeForPopoutSwitch() {
        popoutSwitchClosing = true
        close()
        Qt.callLater(() => { root.popoutSwitchClosing = false })
    }

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        active: !!root.active
        activeColor: Color.accent
        fontSize: Style.font.bodySmall
        horizontalMargin: 5
        text: root.vertical ? "󰄬\n" + root.focusTime : "󰄬 " + root.focusTime
        tooltipText: "Daybook · Today’s focus: " + (root.service ? root.service.duration(root.service.state.summary.elapsed_ms) : "Connecting…")
            + (root.active ? "\n" + root.active.title + " · Right-click to pause" : "\nClick for tasks and daily history")
        onPressed: button => {
            if (button === Qt.RightButton && root.active && root.service) root.service.send("pause")
            else root.toggle()
        }
    }

    KeyboardPanel {
        id: popup
        anchorItem: button
        bar: root.bar
        owner: root
        open: root.opened
        popoutSwitchClosing: root.popoutSwitchClosing
        padding: Style.space(20)
        contentWidth: Math.min(Style.space(500), Math.max(260, screen ? screen.width - Style.space(30) : 500))
        contentHeight: Math.min(Style.space(680), Math.max(250, screen ? screen.height - Style.space(70) : 680))
        focusTarget: content
        DaybookContent {
            id: content
            anchors.fill: parent
            service: root.service
            onCloseRequested: root.close()
        }
    }

}
