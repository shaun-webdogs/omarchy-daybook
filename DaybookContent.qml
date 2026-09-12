import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui as Ui

FocusScope {
    id: root
    required property var service
    signal closeRequested()
    signal resizeBy(real dx, real dy)
    signal resizeFinished()
    signal resizeReset()
    signal opacityPreview(real value)
    signal opacityCommit(real value)
    property bool history: false
    property bool settings: false
    property int tagMenuTask: 0
    property string tagMenuCurrent: ""
    property point tagMenuPos: Qt.point(0, 0)
    readonly property var tagList: state.tags || []
    function openTagMenu(item, taskId, current) {
        var pos = item.mapToItem(root, 0, item.height + Style.space(4))
        tagMenuPos = Qt.point(Math.max(0, Math.min(pos.x, root.width - tagMenu.width)), Math.min(pos.y, root.height - tagMenu.height))
        tagMenuCurrent = current
        tagMenuTask = taskId
    }
    function chooseTag(tag) {
        if (editable && tagMenuTask) service.send("setTag", {taskId: tagMenuTask, tag: tag})
        tagMenuTask = 0
    }
    readonly property real panelOpacity: state.panel && state.panel.opacity !== undefined ? state.panel.opacity / 100 : 1
    property int addRequest: 0
    property string submittedTitle: ""
    property string localError: ""
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
    readonly property bool sortByTime: (state.sort || "time") === "time"
    readonly property string fontFamily: Style.font.family
    implicitWidth: Style.space(460)
    implicitHeight: Style.space(636)

    function duration(ms) { return service ? service.duration(ms) : "00:00:00" }
    function dateLabel(day, format) { return Qt.formatDate(new Date(day + "T12:00:00"), format) }
    // Accepts 1:30, 1:30:00, 1h30m, 45m, 90s, or a bare number of minutes. Returns -1 when unreadable.
    function parseDuration(text) {
        var s = String(text).trim().toLowerCase().replace(/\s+/g, "")
        var m
        if ((m = s.match(/^(\d+):(\d{1,2})(?::(\d{1,2}))?$/)))
            return (Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3] || 0)) * 1000
        if ((m = s.match(/^(?:(\d+(?:\.\d+)?)h)?(?:(\d+(?:\.\d+)?)m)?(?:(\d+)s)?$/)) && s !== "")
            return Math.round((Number(m[1] || 0) * 3600 + Number(m[2] || 0) * 60 + Number(m[3] || 0)) * 1000)
        if ((m = s.match(/^(\d+(?:\.\d+)?)$/))) return Math.round(Number(m[1]) * 60000)
        return -1
    }
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
    // Keep delegates (and their open editors) alive: move rows into place rather than rebuilding on reorder.
    function syncRows() {
        var wanted = rows.filter(t => !viewingToday || !t.archived)
        for (var w = 0; w < wanted.length; ++w) {
            if (wanted[w].note === undefined) wanted[w].note = ""
            if (wanted[w].tag === undefined) wanted[w].tag = ""
        }
        var present = {}
        for (var i = 0; i < taskModel.count; ++i) present[taskModel.get(i).task_id] = true
        if (taskModel.count !== wanted.length || !wanted.every(t => present[t.task_id])) {
            taskModel.clear()
            for (var j = 0; j < wanted.length; ++j) taskModel.append(wanted[j])
            return
        }
        for (var k = 0; k < wanted.length; ++k) {
            if (taskModel.get(k).task_id !== wanted[k].task_id)
                for (var m = k + 1; m < taskModel.count; ++m)
                    if (taskModel.get(m).task_id === wanted[k].task_id) { taskModel.move(m, k, 1); break }
            for (var field in wanted[k]) if (taskModel.get(k)[field] !== wanted[k][field]) taskModel.setProperty(k, field, wanted[k][field])
        }
    }
    onRowsChanged: syncRows()
    onViewingTodayChanged: syncRows()
    Component.onCompleted: syncRows()
    Keys.onEscapePressed: tagMenuTask ? tagMenuTask = 0 : settings ? settings = false : closeRequested()

    Connections {
        target: root.service
        function onAcknowledged(requestId, success) {
            if (success) root.localError = ""
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
            ActionButton {
                text: "󰒓"; hint: root.settings ? "Back to tasks" : "Settings"; subtle: !root.settings; accent: root.settings
                leftPadding: Style.space(7); rightPadding: Style.space(7)
                font.pixelSize: Style.font.icon
                focusPolicy: Qt.NoFocus
                onClicked: root.settings = !root.settings
            }
            ActionButton { text: "×"; hint: "Close · Escape"; subtle: true; onClicked: root.closeRequested() }
        }

        ColumnLayout {
            visible: root.settings
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(14)
            Text { text: "SETTINGS"; color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.letterSpacing: 1 }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: opacityColumn.implicitHeight + Style.space(28)
                radius: Style.cornerRadius
                color: Qt.alpha(root.foreground, 0.025)
                border.color: Qt.alpha(root.foreground, 0.08)
                ColumnLayout {
                    id: opacityColumn
                    anchors.fill: parent
                    anchors.margins: Style.space(14)
                    spacing: Style.space(8)
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "Background opacity"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                        Item { Layout.fillWidth: true }
                        Text { text: Math.round(opacitySlider.liveValue * 100) + "%"; color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                    }
                    Ui.PanelSlider {
                        id: opacitySlider
                        Layout.fillWidth: true
                        minimum: 0.2; maximum: 1; step: 0.05
                        value: root.panelOpacity
                        enabled: root.editable
                        fillColor: Color.accent
                        knobColor: Color.accent
                        trackColor: Qt.alpha(root.foreground, 0.15)
                        onMoved: value => root.opacityPreview(value)
                        onReleased: value => root.opacityCommit(value)
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "Lets your wallpaper and windows show through the panel. Text stays fully opaque."
                        color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)
                ActionButton { text: "Reset opacity"; subtle: true; enabled: root.editable && root.panelOpacity !== 1; onClicked: root.opacityCommit(1) }
                ActionButton { text: "Reset panel size"; subtle: true; enabled: root.editable; onClicked: root.resizeReset() }
                Item { Layout.fillWidth: true }
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: Style.space(120)
                radius: Style.cornerRadius
                color: Qt.alpha(root.foreground, 0.025)
                border.color: Qt.alpha(root.foreground, 0.08)
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(14)
                    spacing: Style.space(8)
                    Text { text: "Tags"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                    Text {
                        Layout.fillWidth: true
                        text: "Each task can carry one tag, picked from this list with 󰓹. Removing a tag clears it from tasks."
                        color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(7)
                        Ui.TextField {
                            id: newTag
                            Layout.fillWidth: true
                            placeholderText: "New tag, e.g. Awaiting Client"
                            maximumLength: 40
                            Accessible.name: "New tag"
                            onAccepted: addTagButton.clicked()
                        }
                        ActionButton {
                            id: addTagButton
                            text: "+ Add"; accent: true
                            enabled: root.editable && newTag.text.trim() !== ""
                            onClicked: {
                                var tags = root.tagList.slice()
                                var name = newTag.text.trim()
                                if (tags.some(t => t.toLowerCase() === name.toLowerCase())) { root.localError = "That tag is already in the list."; return }
                                tags.push(name)
                                root.service.send("setTags", {tags: tags})
                                newTag.text = ""
                            }
                        }
                    }
                    Flickable {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        contentHeight: tagFlow.implicitHeight
                        boundsBehavior: Flickable.StopAtBounds
                        Flow {
                            id: tagFlow
                            width: parent.width
                            spacing: Style.space(6)
                            Repeater {
                                model: root.tagList
                                delegate: Rectangle {
                                    required property string modelData
                                    required property int index
                                    width: tagRow.implicitWidth + Style.space(16)
                                    height: Style.space(26)
                                    radius: Style.cornerRadius
                                    color: Qt.alpha(Color.accent, 0.12)
                                    border.color: Qt.alpha(Color.accent, 0.3)
                                    RowLayout {
                                        id: tagRow
                                        anchors.centerIn: parent
                                        spacing: Style.space(6)
                                        Text { text: modelData; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                                        Text {
                                            text: "×"; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                                            opacity: removeMouse.containsMouse ? 1 : 0.6
                                            MouseArea {
                                                id: removeMouse
                                                anchors.fill: parent; anchors.margins: -Style.space(4)
                                                hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                enabled: root.editable
                                                onClicked: root.service.send("setTags", {tags: root.tagList.filter((t, i) => i !== index)})
                                                Controls.ToolTip.visible: containsMouse
                                                Controls.ToolTip.text: "Remove tag and clear it from tasks"
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            visible: !root.settings
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
            visible: !root.settings
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
            visible: root.history && !root.settings
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
            visible: root.history && !root.settings
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
            visible: !root.history && !root.settings
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
            visible: !root.settings
            Layout.fillWidth: true
            spacing: Style.space(12)
            Text {
                text: root.history ? "TASKS · " + root.dateLabel(root.selected, "d MMMM yyyy").toUpperCase() : "YOUR TASKS"
                color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.letterSpacing: 1
            }
            Item { Layout.fillWidth: true }
            Text {
                text: root.sortByTime ? "󰓅 Most time first" : "󰒺 My order"
                color: Color.accent
                opacity: root.editable ? 1 : 0.5
                font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                font.underline: sortMouse.containsMouse
                Accessible.name: "Task order"
                MouseArea {
                    id: sortMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: root.editable
                    onClicked: root.service.send("setSort", {sort: root.sortByTime ? "manual" : "time"})
                    Controls.ToolTip.visible: containsMouse
                    Controls.ToolTip.delay: 650
                    Controls.ToolTip.text: root.sortByTime ? "Tasks with the most recorded time rise to the top as you work. Click for your own order." : "Tasks stay where you put them with ▲ ▼. Click to sort by recorded time."
                }
            }
            Text { text: root.completed + " / " + root.taskCount + " done"; color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
        }

        Item {
            visible: !root.settings
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: Style.space(100)
            ListView {
                id: taskList
                objectName: "taskList"
                anchors.fill: parent
                clip: true
                spacing: Style.space(7)
                model: taskModel
                boundsBehavior: Flickable.StopAtBounds
                Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                move: Transition { NumberAnimation { properties: "y"; duration: 160; easing.type: Easing.OutCubic } }
                moveDisplaced: Transition { NumberAnimation { properties: "y"; duration: 160; easing.type: Easing.OutCubic } }
                delegate: Rectangle {
                    id: taskRow
                    required property int task_id
                    required property string title
                    required property double elapsed_ms
                    required property int completed
                    required property int archived
                    required property bool running
                    required property string note
                    required property string tag
                    property bool editing: false
                    property bool editingTime: false
                    property bool showNote: false
                    readonly property bool canMove: root.viewingToday && !archived && !root.sortByTime
                    width: taskList.width - Style.space(8)
                    height: Style.space(70) + (showNote ? noteBox.height + Style.space(10) : 0)
                    Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    clip: true
                    radius: Style.cornerRadius
                    color: running ? Qt.alpha(Color.accent, 0.09) : Qt.alpha(root.foreground, 0.025)
                    border.color: running ? Qt.alpha(Color.accent, 0.4) : Qt.alpha(root.foreground, 0.08)
                    Rectangle { visible: taskRow.running; width: Style.space(3); height: Style.space(34); anchors.left: parent.left; anchors.top: parent.top; anchors.topMargin: Style.space(18); color: Color.accent }

                    function openNote() {
                        showNote = true
                        noteField.text = note
                        noteField.forceActiveFocus()
                        noteField.cursorPosition = noteField.length
                    }
                    function saveNote() {
                        if (!root.editable) return
                        if (noteField.text.trim() !== note) root.service.send("setNote", {taskId: task_id, note: noteField.text})
                    }
                    function saveTime() {
                        var ms = root.parseDuration(timeField.text)
                        if (ms < 0 || ms > 86400000) { root.localError = "Enter a time like 1:30, 1h30m, 45m or 90 (minutes)."; return }
                        if (root.editable) root.service.send("setTime", {taskId: task_id, elapsed_ms: ms, day: root.selected})
                        editingTime = false
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Style.space(10)
                        spacing: Style.space(10)
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Style.space(50)
                            spacing: Style.space(8)
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
                                    onActiveFocusChanged: if (!activeFocus) taskRow.editing = false
                                }
                                RowLayout {
                                    spacing: Style.space(4)
                                    Text {
                                        visible: !taskRow.editingTime
                                        text: root.duration(taskRow.elapsed_ms)
                                        color: taskRow.running ? Color.accent : root.secondary
                                        font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                                        font.underline: timeMouse.containsMouse
                                        MouseArea {
                                            id: timeMouse
                                            anchors.fill: parent
                                            enabled: root.editable
                                            hoverEnabled: true
                                            cursorShape: Qt.IBeamCursor
                                            onClicked: { taskRow.editingTime = true; timeField.text = root.duration(taskRow.elapsed_ms); timeField.forceActiveFocus(); timeField.selectAll() }
                                            Controls.ToolTip.visible: containsMouse
                                            Controls.ToolTip.text: "Click to edit recorded time"
                                        }
                                    }
                                    Ui.TextField {
                                        id: timeField
                                        visible: taskRow.editingTime
                                        implicitWidth: Style.space(96)
                                        implicitHeight: Style.space(22)
                                        verticalPadding: 1
                                        font.pixelSize: Style.font.bodySmall
                                        maximumLength: 12
                                        Accessible.name: "Recorded time"
                                        onAccepted: taskRow.saveTime()
                                        Keys.onEscapePressed: event => { taskRow.editingTime = false; event.accepted = true }
                                        onActiveFocusChanged: if (!activeFocus) taskRow.editingTime = false
                                    }
                                    Text {
                                        visible: !taskRow.editingTime
                                        text: taskRow.running ? "·  focusing" : taskRow.archived ? "·  archived" : taskRow.completed ? "·  completed" : "·  unfinished"
                                        color: taskRow.running ? Color.accent : root.secondary
                                        font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                                    }
                                    Rectangle {
                                        visible: !taskRow.editingTime && taskRow.tag !== ""
                                        Layout.preferredWidth: tagLabel.implicitWidth + Style.space(12)
                                        Layout.preferredHeight: Style.space(17)
                                        Layout.leftMargin: Style.space(4)
                                        radius: Style.cornerRadius
                                        color: Qt.alpha(Color.accent, 0.14)
                                        Text { id: tagLabel; anchors.centerIn: parent; text: taskRow.tag; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                                    }
                                    Text {
                                        visible: taskRow.editingTime
                                        text: "Enter saves · Esc cancels"
                                        color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                                    }
                                }
                            }
                            ColumnLayout {
                                visible: taskRow.canMove
                                spacing: Style.space(2)
                                Repeater {
                                    model: [{glyph: "▲", to: "up", edge: "top"}, {glyph: "▼", to: "down", edge: "bottom"}]
                                    delegate: ActionButton {
                                        id: moveButton
                                        required property var modelData
                                        text: modelData.glyph
                                        hint: "Move " + modelData.to + " · right-click for " + modelData.edge
                                        subtle: true
                                        implicitWidth: Style.space(24)
                                        implicitHeight: Style.space(20)
                                        padding: 0; leftPadding: 0; rightPadding: 0
                                        font.pixelSize: Style.font.caption
                                        enabled: root.editable
                                        onClicked: root.service.send("move", {taskId: taskRow.task_id, to: modelData.to})
                                        MouseArea {
                                            anchors.fill: parent
                                            acceptedButtons: Qt.RightButton
                                            enabled: moveButton.enabled
                                            onClicked: root.service.send("move", {taskId: taskRow.task_id, to: moveButton.modelData.edge})
                                        }
                                    }
                                }
                            }
                            ActionButton {
                                id: tagButton
                                visible: root.viewingToday
                                text: "󰓹"
                                hint: taskRow.tag ? taskRow.tag + " · click to change" : "Tag this task"
                                subtle: true
                                leftPadding: Style.space(6); rightPadding: Style.space(6)
                                focusPolicy: Qt.NoFocus
                                enabled: root.editable
                                contentItem: Text {
                                    text: "󰓹"; font.family: root.fontFamily; font.pixelSize: Style.font.icon
                                    color: taskRow.tag ? Color.accent : root.foreground
                                    opacity: taskRow.tag ? 1 : 0.5
                                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                                }
                                onClicked: root.tagMenuTask === taskRow.task_id ? root.tagMenuTask = 0 : root.openTagMenu(tagButton, taskRow.task_id, taskRow.tag)
                            }
                            ActionButton {
                                text: "󰎞"
                                hint: taskRow.showNote ? "Close note" : taskRow.note ? taskRow.note.slice(0, 240) + (taskRow.note.length > 240 ? "…" : "") : "Add a note"
                                subtle: !taskRow.showNote
                                leftPadding: Style.space(6); rightPadding: Style.space(6)
                                font.pixelSize: Style.font.icon
                                opacity: taskRow.note || taskRow.showNote ? 1 : 0.5
                                contentItem: Text {
                                    text: "󰎞"; font.family: root.fontFamily; font.pixelSize: Style.font.icon
                                    color: taskRow.note ? Color.accent : root.foreground
                                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                                }
                                onClicked: taskRow.showNote ? (taskRow.saveNote(), taskRow.showNote = false) : taskRow.openNote()
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

                        Rectangle {
                            id: noteBox
                            visible: taskRow.showNote
                            Layout.fillWidth: true
                            height: Style.space(110)
                            radius: Style.cornerRadius
                            color: Qt.alpha(root.foreground, 0.04)
                            border.color: noteField.activeFocus ? Color.accent : Qt.alpha(root.foreground, 0.1)
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: Style.space(6)
                                spacing: Style.space(4)
                                Controls.ScrollView {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    Controls.TextArea {
                                        id: noteField
                                        wrapMode: TextEdit.Wrap
                                        textFormat: TextEdit.PlainText
                                        placeholderText: "Notes for this task…"
                                        color: root.foreground
                                        placeholderTextColor: root.secondary
                                        selectionColor: Style.selectionFill
                                        selectedTextColor: root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.body
                                        background: null
                                        Accessible.name: "Task note"
                                        onTextChanged: if (length > 4000) remove(4000, length)
                                        Keys.onPressed: event => {
                                            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && event.modifiers & Qt.ControlModifier) {
                                                taskRow.saveNote(); taskRow.showNote = false; event.accepted = true
                                            }
                                        }
                                        Keys.onEscapePressed: event => { taskRow.showNote = false; event.accepted = true }
                                        onActiveFocusChanged: if (!activeFocus && taskRow.showNote) taskRow.saveNote()
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        Layout.fillWidth: true
                                        text: "Ctrl+Enter saves · Esc closes without saving"
                                        color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                                    }
                                    ActionButton {
                                        text: "Save"; accent: true; implicitHeight: Style.space(22)
                                        font.pixelSize: Style.font.bodySmall
                                        enabled: root.editable
                                        onClicked: { taskRow.saveNote(); taskRow.showNote = false }
                                    }
                                }
                            }
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
            text: root.localError ? root.localError : root.service ? root.service.error || root.state.notice || (root.service.exported ? "Exported to " + root.service.exported : "") : "Connecting to Daybook…"
            color: root.localError || (root.service && root.service.error) ? Color.urgent : root.secondary
            font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WrapAnywhere; textFormat: Text.PlainText
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.rightMargin: Style.space(18)
            Text {
                Layout.fillWidth: true
                text: !root.service || !root.service.ready ? "Connecting…" : root.service.pending ? "Saving…" : "●  Saved on this device · even at 00:00"
                color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
            }
            ActionButton { text: "Export ↗"; hint: "Export all daily task times to CSV"; subtle: true; enabled: root.editable; onClicked: root.service.send("export") }
        }
    }

    // Tag dropdown: one menu for the whole list, placed under whichever 󰓹 was clicked.
    MouseArea {
        anchors.fill: parent
        visible: root.tagMenuTask !== 0
        z: 20
        acceptedButtons: Qt.AllButtons
        onClicked: root.tagMenuTask = 0
        onWheel: wheel => wheel.accepted = true
    }
    Rectangle {
        id: tagMenu
        visible: root.tagMenuTask !== 0
        z: 21
        x: root.tagMenuPos.x
        y: root.tagMenuPos.y
        width: Math.max(Style.space(160), tagMenuColumn.implicitWidth + Style.space(12))
        height: tagMenuColumn.implicitHeight + Style.space(12)
        radius: Style.cornerRadius
        color: Color.popups.background
        border.color: Qt.alpha(root.foreground, 0.18)
        Column {
            id: tagMenuColumn
            anchors.fill: parent
            anchors.margins: Style.space(6)
            spacing: Style.space(2)
            Repeater {
                model: [""].concat(root.tagList)
                delegate: Rectangle {
                    id: tagOption
                    required property string modelData
                    readonly property bool current: modelData === root.tagMenuCurrent
                    width: tagMenuColumn.width
                    height: Style.space(26)
                    radius: Style.cornerRadius
                    color: optionMouse.containsMouse ? Qt.alpha(Color.accent, 0.12) : "transparent"
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
                        Text {
                            Layout.fillWidth: true
                            text: tagOption.modelData === "" ? "No tag" : tagOption.modelData
                            color: tagOption.modelData === "" ? root.secondary : root.foreground
                            font.family: root.fontFamily; font.pixelSize: Style.font.body
                            font.italic: tagOption.modelData === ""
                            elide: Text.ElideRight
                        }
                        Text { visible: tagOption.current; text: "✓"; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                    }
                    MouseArea {
                        id: optionMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.chooseTag(tagOption.modelData)
                    }
                }
            }
            Text {
                visible: root.tagList.length === 0
                width: tagMenuColumn.width
                padding: Style.space(6)
                text: "No tags yet. Add some in Settings (󰒓)."
                color: root.secondary; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap
            }
        }
    }

    // Resize grip: drag to grow the panel, double-click to return to the default size.
    Item {
        id: grip
        width: Style.space(18)
        height: Style.space(18)
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: -Style.space(6)
        anchors.bottomMargin: -Style.space(6)
        Text {
            anchors.centerIn: parent
            text: "◢"
            color: gripArea.pressed ? Color.accent : root.secondary
            opacity: gripArea.containsMouse || gripArea.pressed ? 1 : 0.4
            font.family: root.fontFamily; font.pixelSize: Style.space(11)
        }
        MouseArea {
            id: gripArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.SizeFDiagCursor
            property point last
            onPressed: mouse => { last = mapToItem(null, mouse.x, mouse.y) }
            onPositionChanged: mouse => {
                if (!pressed) return
                var point = mapToItem(null, mouse.x, mouse.y)
                root.resizeBy(point.x - last.x, point.y - last.y)
                last = point
            }
            onReleased: root.resizeFinished()
            onDoubleClicked: root.resizeReset()
            Controls.ToolTip.visible: containsMouse && !pressed
            Controls.ToolTip.text: "Drag to resize the panel · Double-click to reset"
            Controls.ToolTip.delay: 650
        }
    }
}
