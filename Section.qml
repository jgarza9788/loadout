import QtQuick
import qs.Commons

// One numbered keyboard section of the panel: a bordered box with its number
// riding the top-left edge. It is a FocusScope, so `activeFocus` is true while
// anything inside holds focus — that is what paints the border and badge in
// the accent colour. The single child fills the box (give it anchors.fill).
FocusScope {
  id: root

  property int number: 0
  property real pad: Style.space(8)
  default property alias content: inner.data

  readonly property Item body: inner.children.length > 0 ? inner.children[0] : null
  readonly property color tone: root.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.16)

  implicitWidth: (body ? body.implicitWidth : 0) + pad * 2
  implicitHeight: (body ? body.implicitHeight : 0) + pad * 2

  Rectangle {
    anchors.fill: parent
    radius: Math.max(6, Style.cornerRadius)
    color: root.activeFocus ? Util.alpha(Color.accent, 0.05) : "transparent"
    border.width: root.activeFocus ? 2 : 1
    border.color: root.tone
  }

  Item {
    id: inner
    anchors.fill: parent
    anchors.margins: root.pad
  }

  // Number badge on the top border.
  Rectangle {
    x: Style.space(10)
    y: -height / 2
    width: badge.implicitWidth + Style.space(8)
    height: badge.implicitHeight + 2
    radius: 3
    color: root.activeFocus ? Color.accent : Color.background
    border.width: 1
    border.color: root.tone
    Text {
      id: badge
      anchors.centerIn: parent
      text: String(root.number)
      color: root.activeFocus ? Color.background : Util.alpha(Color.foreground, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }
}
