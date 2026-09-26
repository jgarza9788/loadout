import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Catalog.js" as Catalog

// Modal form to add / edit / delete one loadout entry. Emits `submitted` with
// (original, edited) — original is null for a brand-new row — or `deleted`.
//
// Fully keyboard-driven: the panel's key catcher hands every key here while the
// editor is open (see handleKey). Tab / Shift+Tab walk an explicit focus ring —
// the platform's own Tab chain only visits text fields — and Ctrl-chords work
// from any field.
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

  readonly property var types: ["pacman", "aur", "flatpak", "omarchy", "hyprland"]

  // Delete is two-step so a stray key can't drop a catalog row.
  property bool confirmingDelete: false
  Timer { id: confirmTimer; interval: 3000; onTriggered: root.confirmingDelete = false }
  function requestDelete() {
    if (!root.original) return;
    if (root.confirmingDelete) { root.confirmingDelete = false; root.deleted(root.original); return; }
    root.confirmingDelete = true;
    confirmTimer.restart();
  }

  function setType(t) {
    if (root.types.indexOf(t) !== -1) root.fType = t;
  }
  function cycleType(delta) {
    var i = root.types.indexOf(root.fType);
    root.fType = root.types[(i + delta + root.types.length) % root.types.length];
  }

  function focusRing() {
    var out = [nameField, descField];
    for (var i = 0; i < typeRep.count; i++) {
      var b = typeRep.itemAt(i);
      if (b) out.push(b);
    }
    out.push(refField, idField, linkField, deleteBtn, cancelBtn, saveBtn);
    return out.filter(function (c) { return c && c.visible && c.enabled !== false; });
  }
  function focusStep(dir) {
    var ring = focusRing();
    if (!ring.length) return;
    var cur = -1;
    for (var i = 0; i < ring.length; i++) if (ring[i].activeFocus) { cur = i; break; }
    var next = cur < 0 ? (dir > 0 ? 0 : ring.length - 1) : (cur + dir + ring.length) % ring.length;
    ring[next].forceActiveFocus(dir < 0 ? Qt.BacktabFocusReason : Qt.TabFocusReason);
  }
  function typeButtonFocused() {
    for (var i = 0; i < typeRep.count; i++) {
      var b = typeRep.itemAt(i);
      if (b && b.activeFocus) return true;
    }
    return false;
  }

  // All editor keys. Returns true when handled. Called from each field's own
  // Keys handler (a focused TextField would otherwise swallow Tab) and from the
  // panel's key catcher for keys that bubble up from buttons.
  function handleKey(e) {
    var ctrl = (e.modifiers & Qt.ControlModifier) !== 0;
    var shift = (e.modifiers & Qt.ShiftModifier) !== 0;
    if (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) {
      focusStep(e.key === Qt.Key_Backtab || shift ? -1 : 1);
      return true;
    }
    if (e.key === Qt.Key_Escape) {
      if (root.confirmingDelete) root.confirmingDelete = false;
      else root.opened = false;
      return true;
    }
    if (ctrl && (e.key === Qt.Key_S || e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) {
      trySave();
      return true;
    }
    if (ctrl && e.key === Qt.Key_Delete) {
      requestDelete();
      return true;
    }
    if (ctrl && e.key >= Qt.Key_1 && e.key <= Qt.Key_5) {
      setType(root.types[e.key - Qt.Key_1]);
      return true;
    }
    if (ctrl && (e.key === Qt.Key_PageDown || e.key === Qt.Key_PageUp)) {
      cycleType(e.key === Qt.Key_PageDown ? 1 : -1);
      return true;
    }
    // On the type buttons, arrows / h l pick the type directly.
    if (typeButtonFocused() && !ctrl) {
      var d = (e.key === Qt.Key_Right || e.text === "l") ? 1
            : (e.key === Qt.Key_Left || e.text === "h") ? -1 : 0;
      if (d) {
        cycleType(d);
        var b = typeRep.itemAt(root.types.indexOf(root.fType));
        if (b) b.forceActiveFocus();
        return true;
      }
    }
    // Up / Down move between fields like Shift+Tab / Tab.
    if (!ctrl && (e.key === Qt.Key_Down || e.key === Qt.Key_Up)) {
      focusStep(e.key === Qt.Key_Down ? 1 : -1);
      return true;
    }
    return false;
  }

  function openFor(orig) {
    root.original = orig || null;
    root.fName = orig ? String(orig.name || "") : "";
    root.fDescription = orig ? String(orig.description || "") : "";
    root.fType = orig ? String(orig.type || "pacman") : "pacman";
    root.fRef = orig ? String(orig.ref || "") : "";
    root.fId = orig ? String(orig.id || "") : "";
    root.fLink = orig ? String(orig.link || "") : "";
    root.confirmingDelete = false;
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
  // Same per-backend grammar the command builder enforces, surfaced while typing.
  readonly property string targetError: Catalog.rowTargetError(collect())
  readonly property bool canSave: fName.trim().length > 0 && fRef.trim().length > 0 && targetError === ""

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

  // Field-level key hook: every TextField routes through handleKey first.
  function fieldKeys(e) { if (root.handleKey(e)) e.accepted = true; }

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
          Keys.onPressed: function (e) { root.fieldKeys(e); }
        }
      }

      Field {
        label: "Description"
        TextField {
          id: descField
          width: parent.width
          text: root.fDescription
          onTextChanged: root.fDescription = text
          onAccepted: root.trySave()
          Keys.onPressed: function (e) { root.fieldKeys(e); }
        }
      }

      Field {
        label: "Type   (Ctrl+1–5, or ← → on a type)"
        Row {
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            id: typeRep
            model: [
              { value: "pacman", label: "Program" },
              { value: "aur", label: "AUR" },
              { value: "flatpak", label: "Flatpak" },
              { value: "omarchy", label: "Omarchy" },
              { value: "hyprland", label: "Hyprland" }
            ]
            delegate: Button {
              required property var modelData
              required property int index
              text: modelData.label
              bordered: true
              focusable: true
              fontSize: Style.font.caption
              tooltipText: "Ctrl+" + (index + 1)
              active: root.fType === modelData.value
              onClicked: root.fType = modelData.value
            }
          }
        }
      }

      Field {
        label: root.refLabel
        TextField {
          id: refField
          width: parent.width
          text: root.fRef
          onTextChanged: root.fRef = text
          onAccepted: root.trySave()
          Keys.onPressed: function (e) { root.fieldKeys(e); }
        }
      }

      Field {
        label: root.idLabel
        visible: !root.isPackages
        TextField {
          id: idField
          width: parent.width
          text: root.fId
          onTextChanged: root.fId = text
          onAccepted: root.trySave()
          Keys.onPressed: function (e) { root.fieldKeys(e); }
        }
      }

      Text {
        width: parent.width
        visible: root.fRef.trim().length > 0 && root.targetError !== ""
        text: root.targetError
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      Field {
        label: "Link (homepage — defaults to the URL above)"
        TextField {
          id: linkField
          width: parent.width
          text: root.fLink
          onTextChanged: root.fLink = text
          onAccepted: root.trySave()
          Keys.onPressed: function (e) { root.fieldKeys(e); }
        }
      }

      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Button {
          id: deleteBtn
          text: root.confirmingDelete ? "Press again to delete" : "Delete entry"
          bordered: true
          focusable: true
          foreground: root.confirmingDelete ? Color.background : Color.urgent
          background: root.confirmingDelete ? Color.urgent : "transparent"
          accent: Color.urgent
          tooltipText: "Ctrl+Delete"
          visible: root.original !== null
          onClicked: root.requestDelete()
        }

        Item { Layout.fillWidth: true; implicitHeight: 1 }

        Button {
          id: cancelBtn
          text: "Cancel"
          bordered: true
          focusable: true
          tooltipText: "Esc"
          onClicked: root.opened = false
        }
        Button {
          id: saveBtn
          text: "Save"
          tooltipText: "Enter in any field, or Ctrl+S"
          bordered: true
          focusable: true
          accent: Color.accent
          active: root.canSave
          enabled: root.canSave
          onClicked: root.trySave()
        }
      }

      Text {
        width: parent.width
        text: "tab / ↑↓ fields · ctrl+1–5 type · ⏎ or ctrl+s save · ctrl+del delete · esc cancel"
        color: Util.alpha(Color.foreground, 0.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
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
