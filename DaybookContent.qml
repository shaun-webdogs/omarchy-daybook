import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui as Ui

FocusScope {
    id: root
    required property var service
    signal closeRequested()
    property bool history: false
    property int addRequest: 0
    property string submittedTitle: ""
    readonly property var state: service ? service.state : ({})
    readonly property var rows: (history ? state.tasks : state.today_tasks || state.tasks) || []
    readonly property string today: state.today || Qt.formatDate(new Date(), "yyyy-MM-dd")
    readonly property string selected: history ? state.selected || today : today
    readonly property bool viewingToday: selected === today && !history
    readonly property bool editable: service && service.ready && !service.pending
    readonly property color foreground: Color.popups.text
    readonly property color secondary: Qt.alpha(foreground, 0.58)
    readonly property int completed: rows.filter(t => t.completed && !t.archived).length
    readonly property int taskCount: rows.filter(t => !t.archived).length
    readonly property double totalTime: rows.reduce((sum, t) => sum + t.elapsed_ms, 0)
    readonly property var active: state.active || null
    readonly property string fontFamily: Style.font.family
    implicitWidth: Style.space(460)
    implicitHeight: Style.space(636)

    function duration(ms) { return service ? service.duration(ms) : "00:00:00" }
    function dateLabel(day, format) { return Qt.formatDate(new Date(day + "T12:00:00"), format) }
    function selectDay(day) {
        if (!editable) return
        service.send("snapshot", {date: day === today && !history ? "" : day})
    }
    function moveDay(amount) {
        var date = new Date(selected + "T12:00:00")
        date.setDate(date.getDate() + amount)
        selectDay(Qt.formatDate(date, "yyyy-MM-dd"))
    }
    function addTask() {
        if (!newTask.text.trim() || !editable) return
        submittedTitle = newTask.text
        addRequest = service.send("add", {title: submittedTitle})
    }
    function syncRows() {
        var wanted = rows.filter(t => !viewingToday || !t.archived)
        var same = taskModel.count === wanted.length
        if (same) for (var i = 0; i < wanted.length; ++i) if (taskModel.get(i).task_id !== wanted[i].task_id) { same = false; break }
        if (!same) {
            taskModel.clear()
            for (var j = 0; j < wanted.length; ++j) taskModel.append(wanted[j])
        } else {
            for (var k = 0; k < wanted.length; ++k) {
                for (var field in wanted[k]) if (taskModel.get(k)[field] !== wanted[k][field]) taskModel.setProperty(k, field, wanted[k][field])
            }
        }
    }
    onRowsChanged: syncRows()
    onViewingTodayChanged: syncRows()
    Component.onCompleted: syncRows()
    Keys.onEscapePressed: closeRequested()

    Connections {
        target: root.service
        function onAcknowledged(requestId, success) {
            if (requestId === root.addRequest && success) {
                if (newTask.text === root.submittedTitle) newTask.text = ""
                newTask.forceActiveFocus()
            }
        }
    }
    ListModel { id: taskModel }

    ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(14)

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)
            Rectangle {
                Layout.preferredWidth: Style.space(36)
                Layout.preferredHeight: Style.space(36)
                radius: Style.cornerRadius
                color: Qt.alpha(Color.accent, 0.12)
                Text { anchors.centerIn: parent; text: "󰄬"; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.space(22) }
            }
            ColumnLayout {
                spacing: Style.space(2)
                Text { text: "Daybook"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.space(21); font.weight: Font.DemiBold }
                Text { text: "A little focus, every day."; color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            }
            Item { Layout.fillWidth: true }
            ActionButton { text: "×"; hint: "Close · Escape"; subtle: true; onClicked: root.closeRequested() }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(114)
            color: Qt.alpha(Color.accent, 0.07)
            radius: Style.cornerRadius
            border.color: Qt.alpha(Color.accent, 0.18)
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Style.space(16)
                spacing: Style.space(4)
                RowLayout {
                    Text {
                        text: root.viewingToday ? "TODAY’S FOCUS" : "DAILY FOCUS"
                        color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.letterSpacing: 1.5
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        visible: !!root.active
                        Layout.preferredWidth: liveLabel.implicitWidth + Style.space(16)
                        Layout.preferredHeight: Style.space(21)
                        radius: Style.cornerRadius
                        color: Qt.alpha(Color.accent, 0.14)
                        Text { id: liveLabel; anchors.centerIn: parent; text: "● LIVE"; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                    }
                }
                Text {
                    text: root.duration(root.totalTime)
                    color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.space(35); font.weight: Font.Medium; font.letterSpacing: 1
                }
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: root.active ? "↳ " + root.active.title : root.completed > 0 && root.completed === root.taskCount ? "All done. Make some room for yourself." : "One task at a time. You’ve got this."
                        color: root.active ? Color.accent : root.secondary
                        font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight; textFormat: Text.PlainText
                    }
                    ActionButton {
                        visible: !!root.active
                        text: "Pause"; hint: "Pause the running task"; subtle: true
                        implicitHeight: Style.space(23)
                        enabled: root.editable
                        onClicked: root.service.send("pause")
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(5)
            ActionButton {
                text: "Today"; accent: !root.history; subtle: root.history; enabled: root.editable
                onClicked: { root.history = false; root.selectDay(root.today) }
            }
            ActionButton {
                text: "History"; accent: root.history; subtle: !root.history; enabled: root.editable
                onClicked: { root.history = true; root.selectDay(root.selected) }
            }
            Item { Layout.fillWidth: true }
            Text { text: root.dateLabel(root.selected, "ddd, d MMM"); color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
        }

        RowLayout {
            visible: root.history
            Layout.fillWidth: true
            spacing: Style.space(6)
            ActionButton { text: "‹"; hint: "Previous day"; enabled: root.editable; onClicked: root.moveDay(-1) }
            Ui.TextField {
                id: dateField
                Layout.fillWidth: true
                text: root.selected
                placeholderText: "YYYY-MM-DD"
                maximumLength: 10
                Accessible.name: "History date, YYYY-MM-DD"
                onAccepted: root.selectDay(text)
            }
            ActionButton { text: "Go"; hint: "Show entered date"; enabled: root.editable; onClicked: root.selectDay(dateField.text) }
            ActionButton { text: "›"; hint: "Next day"; enabled: root.editable && root.selected < root.today; onClicked: root.moveDay(1) }
        }

        RowLayout {
            visible: root.history
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(56)
            spacing: Style.space(6)
            Repeater {
                model: root.state.week || []
                delegate: Rectangle {
                    id: dayCell
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: dayMouse.containsMouse ? Qt.alpha(Color.accent, 0.09) : "transparent"
                    radius: Style.cornerRadius
                    readonly property double peak: Math.max(1, ...(root.state.week || []).map(d => d.elapsed_ms))
                    Rectangle {
                        anchors.bottom: dayName.top
                        anchors.bottomMargin: Style.space(7)
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width * 0.54
                        height: Math.max(Style.space(2), Style.space(30) * dayCell.modelData.elapsed_ms / dayCell.peak)
                        radius: Math.min(Style.cornerRadius, 3)
                        color: dayCell.modelData.day === root.selected ? Color.accent : Qt.alpha(Color.accent, 0.36)
                    }
                    Text {
                        id: dayName
                        anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
                        text: root.dateLabel(dayCell.modelData.day, "ddd")
                        color: dayCell.modelData.day === root.selected ? Color.accent : root.secondary
                        font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                    }
                    MouseArea {
                        id: dayMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        enabled: root.editable
                        onClicked: root.selectDay(dayCell.modelData.day)
                    }
                    Controls.ToolTip.visible: dayMouse.containsMouse
                    Controls.ToolTip.text: dayCell.modelData.day + " · " + root.duration(dayCell.modelData.elapsed_ms)
                }
            }
        }

        RowLayout {
            visible: !root.history
            Layout.fillWidth: true
            spacing: Style.space(7)
            Ui.TextField {
                id: newTask
                Layout.fillWidth: true
                implicitHeight: Style.space(38)
                placeholderText: "What would you like to work on?"
                maximumLength: 240
                Accessible.name: "New task"
                onAccepted: root.addTask()
            }
            ActionButton { text: "+ Add"; accent: true; implicitHeight: Style.space(38); enabled: root.editable && newTask.text.trim() !== ""; onClicked: root.addTask() }
        }

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: root.history ? "TASKS · " + root.dateLabel(root.selected, "d MMMM yyyy").toUpperCase() : "YOUR TASKS"
                color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.letterSpacing: 1
            }
            Item { Layout.fillWidth: true }
            Text { text: root.completed + " / " + root.taskCount + " done"; color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: Style.space(100)
            ListView {
                id: taskList
                anchors.fill: parent
                clip: true
                spacing: Style.space(7)
                model: taskModel
                boundsBehavior: Flickable.StopAtBounds
                Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                delegate: Rectangle {
                    id: taskRow
                    required property int task_id
                    required property string title
                    required property double elapsed_ms
                    required property int completed
                    required property int archived
                    required property bool running
                    property bool editing: false
                    width: taskList.width - Style.space(8)
                    height: Style.space(70)
                    radius: Style.cornerRadius
                    color: running ? Qt.alpha(Color.accent, 0.09) : Qt.alpha(root.foreground, 0.025)
                    border.color: running ? Qt.alpha(Color.accent, 0.4) : Qt.alpha(root.foreground, 0.08)
                    Rectangle { visible: taskRow.running; width: Style.space(3); height: parent.height * 0.48; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; color: Color.accent }
                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: Style.space(10)
                        spacing: Style.space(9)
                        ActionButton {
                            visible: root.viewingToday
                            text: taskRow.completed ? "✓" : "○"
                            hint: taskRow.completed ? "Reopen task, keeping its saved time" : "Complete task and save time"
                            accent: !!taskRow.completed
                            implicitWidth: Style.space(30)
                            leftPadding: 0; rightPadding: 0
                            enabled: root.editable
                            onClicked: root.service.send(taskRow.completed ? "reopen" : "complete", {taskId: taskRow.task_id})
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(5)
                            Text {
                                visible: !taskRow.editing
                                Layout.fillWidth: true
                                text: taskRow.title; textFormat: Text.PlainText
                                color: taskRow.completed ? root.secondary : root.foreground
                                font.family: root.fontFamily; font.pixelSize: Style.font.body; font.strikeout: !!taskRow.completed
                                elide: Text.ElideRight
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: root.viewingToday && root.editable
                                    hoverEnabled: true
                                    onDoubleClicked: { taskRow.editing = true; renameField.text = taskRow.title; renameField.forceActiveFocus(); renameField.selectAll() }
                                    Controls.ToolTip.visible: containsMouse
                                    Controls.ToolTip.text: taskRow.title + "\nDouble-click to rename"
                                }
                            }
                            Ui.TextField {
                                id: renameField
                                visible: taskRow.editing
                                Layout.fillWidth: true
                                maximumLength: 240
                                Accessible.name: "Rename task"
                                onAccepted: {
                                    if (root.editable && text.trim()) {
                                        root.service.send("rename", {taskId: taskRow.task_id, title: text})
                                        taskRow.editing = false
                                    }
                                }
                                Keys.onEscapePressed: event => { taskRow.editing = false; event.accepted = true }
                            }
                            Text {
                                text: root.duration(taskRow.elapsed_ms) + (taskRow.running ? "  ·  focusing" : taskRow.archived ? "  ·  archived" : taskRow.completed ? "  ·  completed" : "  ·  unfinished")
                                color: taskRow.running ? Color.accent : root.secondary
                                font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                            }
                        }
                        ActionButton {
                            text: !root.viewingToday ? "To today" : taskRow.completed ? "Reopen" : taskRow.running ? "Ⅱ" : "▶"
                            hint: !root.viewingToday ? "Bring this task to today; preserve previous days" : taskRow.completed ? "Reopen to append more time" : taskRow.running ? "Pause timer" : "Start timer; pause any other task"
                            accent: taskRow.running
                            enabled: root.editable
                            onClicked: root.service.send(!root.viewingToday ? "restore" : taskRow.completed ? "reopen" : taskRow.running ? "pause" : "start", {taskId: taskRow.task_id})
                        }
                        ActionButton {
                            visible: root.viewingToday
                            text: "×"; hint: "Archive task; keep all history"; subtle: true
                            leftPadding: Style.space(4); rightPadding: Style.space(4)
                            enabled: root.editable
                            onClicked: root.service.send("archive", {taskId: taskRow.task_id})
                        }
                    }
                }
            }
            Column {
                visible: taskModel.count === 0
                anchors.centerIn: parent
                width: parent.width
                spacing: Style.space(10)
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.history ? "󰃭" : "󰄬"; color: Qt.alpha(Color.accent, 0.7); font.family: root.fontFamily; font.pixelSize: Style.space(34) }
                Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: root.history ? "A quiet day." : "A fresh page for your day."; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title }
                Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: root.history ? "No tasks recorded on this date." : "Add a task above. Start whenever you’re ready."; color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Qt.alpha(root.foreground, 0.1) }
        Text {
            visible: text !== ""
            Layout.fillWidth: true
            text: root.service ? root.service.error || root.state.notice || (root.service.exported ? "Exported to " + root.service.exported : "") : "Connecting to Daybook…"
            color: root.service && root.service.error ? Color.urgent : root.secondary
            font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WrapAnywhere; textFormat: Text.PlainText
        }
        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: !root.service || !root.service.ready ? "Connecting…" : root.service.pending ? "Saving…" : "●  Saved on this device · even at 00:00"
                color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
            }
            ActionButton { text: "Export ↗"; hint: "Export all daily task times to CSV"; subtle: true; enabled: root.editable; onClicked: root.service.send("export") }
        }
    }
}
