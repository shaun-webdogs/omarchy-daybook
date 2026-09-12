import QtQuick
import QtQuick.Window
import Quickshell
import qs.Commons
import "Plugin" as Daybook

ShellRoot {
    component PreviewService: Item {
        property bool ready: true
        property int pending: 0
        property string error: ""
        property string exported: ""
        signal acknowledged(int requestId, bool success)
        property var state: ({
            today: "2026-09-06", selected: "2026-09-06", notice: "",
            active: {task_id: 1, title: "Design the reading corner", elapsed_ms: 2538000},
            summary: {total: 3, completed: 1, elapsed_ms: 5238000},
            tasks: [
                {task_id: 1, title: "Design the reading corner", elapsed_ms: 2538000, completed: 0, archived: 0, running: true, note: "Measure the alcove first. Lamp on the left, shelf no deeper than 25 cm.", tag: ""},
                {task_id: 2, title: "Plan meals for the week", elapsed_ms: 0, completed: 0, archived: 0, running: false, note: "", tag: "Awaiting Client"},
                {task_id: 3, title: "Morning pages", elapsed_ms: 2700000, completed: 1, archived: 0, running: false, note: "", tag: ""}],
            panel: {width: 0, height: 0}, tags: ["Awaiting Client", "In Progress", "Blocked"],
            week: [
                {day: "2026-08-31", elapsed_ms: 4000000}, {day: "2026-09-01", elapsed_ms: 7200000},
                {day: "2026-09-02", elapsed_ms: 5200000}, {day: "2026-09-03", elapsed_ms: 9400000},
                {day: "2026-09-04", elapsed_ms: 2300000}, {day: "2026-09-05", elapsed_ms: 7800000},
                {day: "2026-09-06", elapsed_ms: 5238000}]
        })
        function duration(ms) {
            var seconds = Math.floor((ms || 0) / 1000)
            return String(Math.floor(seconds / 3600)).padStart(2, "0") + ":"
                + String(Math.floor(seconds / 60) % 60).padStart(2, "0") + ":"
                + String(seconds % 60).padStart(2, "0")
        }
    }
    PreviewService { id: todayService }
    PreviewService {
        id: historyService
        Component.onCompleted: {
            var snapshot = JSON.parse(JSON.stringify(state))
            snapshot.active = null
            snapshot.selected = "2026-09-05"
            snapshot.tasks = [
                {task_id: 1, title: "Read & take notes", elapsed_ms: 5100000, completed: 1, archived: 0, running: false, note: "", tag: ""},
                {task_id: 2, title: "A walk, then a fresh draft", elapsed_ms: 2700000, completed: 1, archived: 0, running: false, note: "", tag: ""}]
            state = snapshot
        }
    }
    Window {
        width: 1048; height: 760; visible: true
        Rectangle {
            id: capture
            anchors.fill: parent
            color: Color.background
            Row {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 16
                spacing: 10
                Text { text: "󰄬 1:27"; color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
            }
            Row {
                anchors.top: parent.top
                anchors.topMargin: 48
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 16
                Rectangle {
                    width: 500; height: 688
                    color: Color.popups.background
                    border.color: Color.popups.border
                    border.width: 1
                    radius: Style.cornerRadius
                    Daybook.DaybookContent { anchors.fill: parent; anchors.margins: 20; service: todayService }
                }
                Rectangle {
                    width: 500; height: 688
                    color: Color.popups.background
                    border.color: Color.popups.border
                    border.width: 1
                    radius: Style.cornerRadius
                    Daybook.DaybookContent { anchors.fill: parent; anchors.margins: 20; service: historyService; history: true }
                }
            }
        }
        Timer {
            interval: 700; running: true
            onTriggered: capture.grabToImage(function(result) {
                if (!result.saveToFile(Quickshell.env("DAYBOOK_PREVIEW_PATH"))) Qt.exit(1)
                console.log("PREVIEW SAVED")
                Qt.quit()
            })
        }
    }
}
