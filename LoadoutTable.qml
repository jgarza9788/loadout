import QtQuick
import qs.Commons

// The scrollable loadout table: a fixed header row over a ListView. Purely a
// view — every mutation goes back through `controller` (the Loadout root).
Item {
  id: root

  property var model: null
  property var controller: null
  property int cursorIndex: -1

  // A single tab stop for the whole list. Once focused, the panel's shared
  // key handler drives j/k / arrows / space / ⏎ against the row cursor.
  activeFocusOnTab: true

  onCursorIndexChanged: list.currentIndex = cursorIndex
  // Re-assert currentIndex after the model was cleared+repopulated (which resets
  // it), so the row highlight and scroll position stay put.
  function syncCursor() {
    list.currentIndex = root.cursorIndex;
    if (root.cursorIndex >= 0) list.positionViewAtIndex(root.cursorIndex, ListView.Contain);
  }
  function ensureCursorVisible() {
    if (list.currentIndex >= 0) list.positionViewAtIndex(list.currentIndex, ListView.Contain);
  }

  readonly property color line: Util.alpha(Color.foreground, 0.12)
  readonly property color subtle: Util.alpha(Color.foreground, 0.55)

  // Column widths. Description flexes; the rest are fixed. Rows are acted on in
  // bulk (select + "Add/Remove selected", or the a/d keys) — no per-row buttons.
  readonly property real wCheck: 30
  readonly property real wType: 96
  readonly property real wStatus: 110
  readonly property real wLink: 44
  readonly property real wName: 230
  readonly property real wDesc: Math.max(160,
    width - wCheck - wName - wType - wStatus - wLink - colSpacing * 5)
  readonly property real colSpacing: 10

  function typeLabel(t) {
    return t === "pacman" ? "Program"
      : t === "aur" ? "AUR"
      : t === "flatpak" ? "Flatpak"
      : t === "omarchy" ? "Omarchy"
      : t === "hyprland" ? "Hyprland" : t;
  }
  function typeColor(t) {
    return t === "pacman" ? Color.accent
      : t === "aur" ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.7)
      : t === "flatpak" ? "#bb9af7"
      : t === "omarchy" ? "#7aa2f7"
      : t === "hyprland" ? "#9ece6a" : root.subtle;
  }

  Column {
    anchors.fill: parent
    spacing: 0

    // ── Header ──────────────────────────────────────────────────────
    Rectangle {
      width: parent.width
      height: 30
      color: "transparent"
      Row {
        anchors.fill: parent
        anchors.leftMargin: 4
        anchors.rightMargin: 4
        spacing: root.colSpacing

        Item { width: root.wCheck; height: 1 }
        HeaderCell { text: "Name"; cellWidth: root.wName }
        HeaderCell { text: "Description"; cellWidth: root.wDesc }
        HeaderCell { text: "Link"; cellWidth: root.wLink }
        HeaderCell { text: "Type"; cellWidth: root.wType }
        HeaderCell { text: "Status"; cellWidth: root.wStatus }
      }
      Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.line }
    }

    // ── Rows ────────────────────────────────────────────────────────
    ListView {
      id: list
      width: parent.width
      height: parent.height - 30
      clip: true
      model: root.model
      boundsBehavior: Flickable.StopAtBounds

      delegate: Rectangle {
        id: rowItem
        width: list.width
        height: 42

        required property int index
        required property string key
        required property string name
        required property string description
        required property string type
        required property string ref
        required property string entryId
        required property string link
        required property bool installed
        required property bool entryEnabled
        required property bool busy
        required property bool selected

        readonly property bool isCursor: index === list.currentIndex
        color: isCursor ? Util.alpha(Color.accent, 0.12)
          : rowMouse.containsMouse ? Util.alpha(Color.foreground, 0.05)
          : "transparent"

        readonly property var rowObj: ({
          type: rowItem.type, ref: rowItem.ref, id: rowItem.entryId,
          name: rowItem.name, description: rowItem.description, link: rowItem.link
        })

        // Cursor accent bar.
        Rectangle {
          anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
          width: 2
          color: Color.accent
          visible: rowItem.isCursor
        }

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton
          onClicked: root.controller.setCursor(rowItem.index)
          onDoubleClicked: root.controller.editRow(rowItem.rowObj)
        }

        Row {
          anchors.fill: parent
          anchors.leftMargin: 4
          anchors.rightMargin: 4
          spacing: root.colSpacing

          // checkbox
          Item {
            width: root.wCheck; height: parent.height
            Rectangle {
              anchors.centerIn: parent
              width: 16; height: 16; radius: 4
              color: rowItem.selected ? Color.accent : "transparent"
              border.width: 1
              border.color: rowItem.selected ? Color.accent : root.subtle
              Text {
                anchors.centerIn: parent
                text: "✓"
                visible: rowItem.selected
                color: Color.background
                font.pixelSize: 11
              }
              MouseArea { anchors.fill: parent; onClicked: root.controller.toggleSel(rowItem.key) }
            }
          }

          CellText {
            cellWidth: root.wName
            text: rowItem.name
            color: Color.foreground
            bold: true
          }
          CellText {
            cellWidth: root.wDesc
            text: rowItem.description
            color: root.subtle
          }

          // link
          Item {
            width: root.wLink; height: parent.height
            Text {
              anchors.centerIn: parent
              text: "🔗"
              visible: rowItem.link.length > 0
              opacity: linkMouse.containsMouse ? 1 : 0.6
              font.pixelSize: 13
              MouseArea {
                id: linkMouse
                anchors.fill: parent
                anchors.margins: -6
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.controller.openLink(rowItem.link)
              }
            }
          }

          // type badge
          Item {
            width: root.wType; height: parent.height
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: badgeText.implicitWidth + 14
              height: 20
              radius: 10
              color: Util.alpha(root.typeColor(rowItem.type), 0.16)
              Text {
                id: badgeText
                anchors.centerIn: parent
                text: root.typeLabel(rowItem.type)
                color: root.typeColor(rowItem.type)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          // status
          Item {
            width: root.wStatus; height: parent.height
            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 6
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 8; height: 8; radius: 4
                color: rowItem.busy ? "#e0af68"
                  : rowItem.installed ? (rowItem.entryEnabled ? "#9ece6a" : "#e0af68")
                  : Util.alpha(Color.foreground, 0.3)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.busy ? "working…"
                  : rowItem.installed ? (rowItem.entryEnabled ? "installed" : "disabled")
                  : "not installed"
                color: root.subtle
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }
        }

        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.line }
      }

      // empty state
      Text {
        anchors.centerIn: parent
        visible: list.count === 0
        text: "Nothing matches this filter.\nＮew adds a row; it stays even after you remove it."
        horizontalAlignment: Text.AlignHCenter
        color: root.subtle
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }
  }

  // Focus ring — drawn only when the list is the tab target.
  Rectangle {
    anchors.fill: parent
    anchors.margins: -2
    radius: 4
    color: "transparent"
    border.width: 1
    border.color: Color.accent
    visible: root.activeFocus
  }

  // ── Small helpers ────────────────────────────────────────────────
  component HeaderCell: Text {
    property real cellWidth: 80
    width: cellWidth
    text: ""
    color: Util.alpha(Color.foreground, 0.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 0.6
    elide: Text.ElideRight
    verticalAlignment: Text.AlignVCenter
    height: parent ? parent.height : implicitHeight
  }

  component CellText: Text {
    property real cellWidth: 80
    property bool bold: false
    width: cellWidth
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    font.bold: bold
    elide: Text.ElideRight
    verticalAlignment: Text.AlignVCenter
    height: parent ? parent.height : implicitHeight
  }
}
