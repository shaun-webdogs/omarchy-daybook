import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root
    property var shell: null
    property var manifest: null
    property string omarchyPath: ""
    property var state: ({tasks: [], dates: [], week: [], summary: {elapsed_ms: 0, total: 0, completed: 0}, active: null})
    property bool ready: false
    property string error: ""
    property string exported: ""
    property int sequence: 0
    property int pending: 0
    signal acknowledged(int requestId, bool success)

    function send(action, values) {
        if (!ready || !backend.running || pending) return 0
        var request = values || {}
        request.action = action
        request.requestId = ++sequence
        pending = request.requestId
        error = ""
        backend.write(JSON.stringify(request) + "\n")
        watchdog.restart()
        return request.requestId
    }

    function duration(ms) {
        var seconds = Math.floor((ms || 0) / 1000)
        return String(Math.floor(seconds / 3600)).padStart(2, "0") + ":"
            + String(Math.floor(seconds / 60) % 60).padStart(2, "0") + ":"
            + String(seconds % 60).padStart(2, "0")
    }

    Process {
        id: backend
        command: ["/usr/bin/python3", "-B", "-u", decodeURIComponent(Qt.resolvedUrl("daybook.py").toString().replace(/^file:\/\//, "")), "--serve"]
        stdinEnabled: true
        running: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    var response = JSON.parse(data)
                    if (response.state) {
                        root.state = response.state
                        root.ready = true
                    }
                    if (!response.ok) root.error = response.error || "Unable to save. Please try again."
                    if (response.exported) root.exported = response.exported
                    if (response.requestId) {
                        if (root.pending === response.requestId) {
                            root.pending = 0
                            watchdog.stop()
                        }
                        root.acknowledged(response.requestId, response.ok)
                    }
                } catch (error) { root.error = "Unable to read the task service response." }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim()) console.warn("Daybook: " + text.trim())
        }
        onExited: {
            root.ready = false
            root.pending = 0
            root.error = "Task service stopped. Your saved history is safe. Reconnecting…"
            retry.restart()
        }
    }
    Timer { id: retry; interval: 3000; onTriggered: backend.running = true }
    Timer {
        id: watchdog
        interval: 10000
        onTriggered: {
            root.error = "The save has not been confirmed. Reconnecting; please check the task before retrying."
            backend.running = false
        }
    }
}
