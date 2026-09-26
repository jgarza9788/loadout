import QtQuick
import qs.Commons
import qs.Ui

// The kit Button, plus an unmistakable accent ring while it holds keyboard
// focus — the theme's own focus fill is too faint to find at a glance.
Button {
  id: root
  focusable: true
  // Tab belongs to the panel (it moves between sections / editor fields), so
  // keep Qt's own tab chain from grabbing it first.
  activeFocusOnTab: false

  Rectangle {
    anchors.fill: parent
    anchors.margins: -3
    radius: root.radius + 3
    color: "transparent"
    border.width: 2
    border.color: Color.accent
    visible: root.activeFocus
  }
}
