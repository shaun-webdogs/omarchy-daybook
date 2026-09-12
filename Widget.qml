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

    // Panel size: the saved preference wins, the live drag overrides it until the save is confirmed.
    readonly property var panelPref: service && service.state.panel ? service.state.panel : ({width: 0, height: 0})
    property bool resizing: false
    property int liveWidth: 0
    property int liveHeight: 0
    property int resizeRequest: 0
    property int opacityRequest: 0
    property real previewOpacity: -1
    readonly property real panelOpacity: previewOpacity >= 0 ? previewOpacity : (panelPref.opacity === undefined ? 100 : panelPref.opacity) / 100
    function clampWidth(w) { return Math.round(Math.min(Math.max(260, w), popup.screen ? popup.screen.width - Style.space(30) : w)) }
    function clampHeight(h) { return Math.round(Math.min(Math.max(250, h), popup.screen ? popup.screen.height - Style.space(70) : h)) }

    function open() { opened = true }
    function close() { opened = false }
    function toggle() { opened = !opened }
    function closeForPopoutSwitch() {
        popoutSwitchClosing = true
        close()
        Qt.callLater(() => { root.popoutSwitchClosing = false })
    }

    Connections {
        target: root.service
        function onAcknowledged(requestId, success) {
            if (requestId === root.resizeRequest) root.resizing = false
            if (requestId === root.opacityRequest) root.previewOpacity = -1
        }
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
        contentWidth: root.clampWidth(root.resizing ? root.liveWidth : root.panelPref.width || Style.space(500))
        contentHeight: root.clampHeight(root.resizing ? root.liveHeight : root.panelPref.height || Style.space(680))
        focusTarget: content
        DaybookContent {
            id: content
            anchors.fill: parent
            service: root.service
            onCloseRequested: root.close()
            onResizeBy: (dx, dy) => {
                if (!root.resizing) { root.liveWidth = popup.contentWidth; root.liveHeight = popup.contentHeight; root.resizing = true }
                root.liveWidth = root.clampWidth(root.liveWidth + dx)
                root.liveHeight = root.clampHeight(root.liveHeight + dy)
            }
            onResizeFinished: {
                if (!root.resizing || !root.service) return
                root.resizeRequest = root.service.send("setPanel", {width: root.liveWidth, height: root.liveHeight})
                if (!root.resizeRequest) root.resizing = false
            }
            onResizeReset: if (root.service) root.service.send("setPanel", {width: 0, height: 0})
            onOpacityPreview: value => root.previewOpacity = value
            onOpacityCommit: value => {
                if (!root.service) return
                root.previewOpacity = value
                root.opacityRequest = root.service.send("setPanel", {opacity: Math.round(value * 100)})
                if (!root.opacityRequest) root.previewOpacity = -1
            }
        }
        // The panel card sits two levels above our content; tint it without changing the shared component.
        Binding {
            target: content.parent && content.parent.parent && content.parent.parent.borderSpec !== undefined ? content.parent.parent : null
            property: "color"
            value: Qt.alpha(Color.popups.background, root.panelOpacity)
        }
    }

}
