import QtQuick
import QtQuick.Window
import Quickshell
import qs.Commons
import "Plugin" as Daybook

ShellRoot {
    id: test
    property int phase: 0
    property int taskId: 0
    property double firstTime: 0
    property int ticks: 0
    function check(condition, message) {
        if (!condition) { console.error("TEST FAILED:", message); Qt.exit(1) }
    }
    Window {
        width: 500; height: 680; visible: true; color: Color.popups.background
        Daybook.DaybookContent { anchors.fill: parent; anchors.margins: 20; service: service }
    }
    Daybook.Service { id: service }
    Timer {
        interval: 200; running: true; repeat: true
        onTriggered: {
            if (++test.ticks > 75) { test.check(false, "Timed out; " + service.error); return }
            if (!service.ready || service.pending) return
            var tasks = service.state.tasks
            if (test.phase === 0) {
                service.send("add", {title: "Integration <b>plain text</b> ✓"}); test.phase = 1
            } else if (test.phase === 1) {
                test.check(tasks.length === 1 && tasks[0].elapsed_ms === 0, "Immediate zero-time save")
                test.taskId = tasks[0].task_id
                service.send("start", {taskId: test.taskId}); test.phase = 2
            } else if (test.phase === 2 && tasks[0].elapsed_ms >= 1000) {
                service.send("complete", {taskId: test.taskId}); test.phase = 3
            } else if (test.phase === 3) {
                test.check(tasks[0].completed === 1 && !service.state.active, "Complete saves and stops")
                test.firstTime = tasks[0].elapsed_ms
                service.send("reopen", {taskId: test.taskId}); test.phase = 4
            } else if (test.phase === 4) {
                test.check(tasks[0].elapsed_ms === test.firstTime && !tasks[0].completed, "Reopen preserves total")
                service.send("start", {taskId: test.taskId}); test.phase = 5
            } else if (test.phase === 5 && tasks[0].elapsed_ms >= test.firstTime + 1000) {
                service.send("pause"); test.phase = 6
            } else if (test.phase === 6) {
                test.check(!service.state.active && tasks[0].elapsed_ms > test.firstTime, "Resume appends time")
                service.send("export"); test.phase = 7
            } else if (test.phase === 7) {
                test.check(service.exported.endsWith(".csv"), "CSV exported")
                var yesterday = new Date(service.state.today + "T12:00:00")
                yesterday.setDate(yesterday.getDate() - 1)
                service.send("snapshot", {date: Qt.formatDate(yesterday, "yyyy-MM-dd")}); test.phase = 8
            } else if (test.phase === 8) {
                test.check(service.state.tasks.length === 0 && service.state.today_tasks.length === 1, "History independent from today's tasks")
                console.log("INTEGRATION PASSED: add, zero-time save, start, complete, reopen, append, pause, export, history")
                Qt.quit()
            }
        }
    }
}
