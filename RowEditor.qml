import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Modal form to add / edit / delete one loadout entry. Emits `submitted` with
// (original, edited) — original is null for a brand-new row — or `deleted`.
Item {
  id: root

  property bool opened: false
  property var original: null

  signal submitted(var original, var edited)
  signal deleted(var original)

  property string fName: ""
  property string fDescription: ""
  property string fType: "pacman"
  property string fRef: ""
  property string fId: ""
  property string fLink: ""

  visible: opened

  function openFor(orig) {
    root.original = orig || null;
    root.fName = orig ? String(orig.name || "") : "";
    root.fDescription = orig ? String(orig.description || "") : "";
    root.fType = orig ? String(orig.type || "pacman") : "pacman";
    root.fRef = orig ? String(orig.ref || "") : "";
    root.fId = orig ? String(orig.id || "") : "";
    root.fLink = orig ? String(orig.link || "") : "";
    root.opened = true;
    Qt.callLater(function () { nameField.forceActiveFocus(); });
  }

  readonly property bool isPackages: fType === "pacman" || fType === "aur" || fType === "flatpak"
  readonly property string refLabel: fType === "flatpak"
    ? "Flatpak app id(s), space separated  (e.g. com.nvidia.geforcenow)"
    : isPackages
      ? "Package name(s), space separated"
      : "Git URL"
  readonly property string idLabel: fType === "omarchy"
    ? "Plugin id (optional — discovered after install)"
    : fType === "hyprland"
      ? "hyprpm plugin name (for enable + status)"
      : "id (optional)"
  readonly property bool canSave: fName.trim().length > 0 && fRef.trim().length > 0

  function collect() {
    return {
      name: root.fName.trim(),
      description: root.fDescription.trim(),
      type: root.fType,
      ref: root.fRef.trim(),
      id: root.fId.trim(),
      link: root.fLink.trim()
    };
  }
  function trySave() { if (root.canSave) root.submitted(root.original, root.collect()); }

  // Scrim
  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Color.background, 0.6)
    MouseArea { anchors.fill: parent; onClicked: root.opened = false }
  }

  Rectangle {
    anchors.centerIn: parent
    width: Math.min(560, parent.width * 0.8)
    height: form.implicitHeight + Style.space(36)
    radius: Math.max(8, Style.cornerRadius)
    color: Color.background
    border.width: 1
    border.color: Util.alpha(Color.foreground, 0.16)

    MouseArea { anchors.fill: parent; onClicked: {} }

    Column {
      id: form
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(18)
      spacing: Style.space(12)

      Text {
        text: root.original ? "Edit entry" : "New entry"
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.4
      }

      Field {
        label: "Name"
        TextField {
          id: nameField
          width: parent.width
          text: root.fName
          onTextChanged: root.fName = text
          onAccepted: root.trySave()
        }
      }

      Field {
        label: "Description"
        TextField {
          width: parent.width
          text: root.fDescription
          onTextChanged: root.fDescription = text
          onAccepted: root.trySave()
        }
      }

      Field {
        label: "Type"
        Row {
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: [
              { value: "pacman", label: "Program" },
              { value: "aur", label: "AUR" },
              { value: "flatpak", label: "Flatpak" },
              { value: "omarchy", label: "Omarchy" },
              { value: "hyprland", label: "Hyprland" }
            ]
            delegate: Button {
              required property var modelData
              text: modelData.label
              bordered: true
              focusable: true
              fontSize: Style.font.caption
              active: root.fType === modelData.value
              onClicked: root.fType = modelData.value
            }
          }
        }
      }

      Field {
        label: root.refLabel
        TextField {
          width: parent.width
          text: root.fRef
          onTextChanged: root.fRef = text
          onAccepted: root.trySave()
        }
      }

      Field {
        label: root.idLabel
        visible: !root.isPackages
        TextField {
          width: parent.width
          text: root.fId
          onTextChanged: root.fId = text
          onAccepted: root.trySave()
        }
      }

      Field {
        label: "Link (homepage — defaults to the URL above)"
        TextField {
          width: parent.width
          text: root.fLink
          onTextChanged: root.fLink = text
          onAccepted: root.trySave()
        }
      }

      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Button {
          text: "Delete entry"
          bordered: true
          focusable: true
          foreground: Color.urgent
          accent: Color.urgent
          visible: root.original !== null
          onClicked: root.deleted(root.original)
        }

        Item { Layout.fillWidth: true; implicitHeight: 1 }

        Button {
          text: "Cancel"
          bordered: true
          focusable: true
          onClicked: root.opened = false
        }
        Button {
          text: "Save"
          bordered: true
          focusable: true
          accent: Color.accent
          active: root.canSave
          enabled: root.canSave
          onClicked: root.submitted(root.original, root.collect())
        }
      }
    }
  }

  component Field: Column {
    property string label: ""
    width: parent ? parent.width : implicitWidth
    spacing: 4
    Text {
      text: parent.label
      color: Util.alpha(Color.foreground, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
