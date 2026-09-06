import QtQuick
import QtQuick.Controls
import qs.Commons

Button {
    id: root
    property bool accent: false
    property bool subtle: false
    property string hint: ""
    padding: Style.space(8)
    leftPadding: Style.space(11)
    rightPadding: Style.space(11)
    implicitHeight: Style.space(32)
    hoverEnabled: true
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    Accessible.name: hint || text
    ToolTip.visible: hovered && hint !== ""
    ToolTip.text: hint
    ToolTip.delay: 650
    contentItem: Text {
        text: root.text
        textFormat: Text.PlainText
        font: root.font
        color: root.accent ? Color.background : Color.popups.text
        opacity: root.enabled ? 1 : 0.35
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
    background: Rectangle {
        radius: Style.cornerRadius
        color: root.accent ? Color.accent : Qt.alpha(Color.popups.text, root.down ? 0.14 : root.hovered ? 0.09 : root.subtle ? 0 : 0.04)
        opacity: root.enabled ? 1 : 0.45
        border.width: root.activeFocus ? 2 : 1
        border.color: root.activeFocus ? Color.accent : Qt.alpha(Color.popups.text, root.subtle ? 0 : 0.08)
        Behavior on color { ColorAnimation { duration: 100 } }
    }
}
