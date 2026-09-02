import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Catalog.js" as Catalog

// Loadout — one table for everything you install: pacman / AUR programs,
// Omarchy shell plugins, and Hyprland plugins. The table is a catalog you own;
// Add / Remove act in bulk and a removed row stays put so you can re-add it.
//
// Overlay lifecycle (open/close/toggle/summon/hide/dismiss + writable `opened`)
// follows the Omarchy overlay-plugin contract, modeled on jgarza.scroll-overview.
Item {
  id: root

  // ── Injected by the Omarchy shell loader ─────────────────────────────────
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""
  readonly property string pluginId: String((manifest && manifest.id) || "jgarza.loadout")

  // ── Paths ────────────────────────────────────────────────────────────────
  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string configDir: homeDir + "/.config/omarchy/jgarza.loadout"
  readonly property string catalogPath: configDir + "/catalog.json"
  readonly property string defaultCatalogPath:
    Qt.resolvedUrl("catalog.default.json").toString().replace(/^file:\/\//, "")
  readonly property string statusScript:
    Qt.resolvedUrl("bin/loadout-status").toString().replace(/^file:\/\//, "")

  // ── State ────────────────────────────────────────────────────────────────
  property bool opened: false
  property bool closing: false
  readonly property bool revealed: opened && !closing

  property var rows: []            // normalized rows + transient installed/enabled/busy
  property var statusObj: ({})
  property var selectedKeys: ({})  // rowKey -> true
  property var defaultRows: []
  property bool catalogReady: false

  property string filterType: "all"
  property string query: ""
  property bool installedOnly: false

  // Keyboard row cursor — an index into the currently visible (filtered) list.
  property int cursorIndex: 0

  property string toastText: ""

  // Job tracking: keys of rows a launched command touches, and their installed
  // state at launch time so a status refresh can clear `busy` as soon as it flips.
  property var jobKeys: []
  property var jobInstalledAtLaunch: ({})
  property int jobTicks: 0

  readonly property int installedCount: {
    var n = 0;
    for (var i = 0; i < rows.length; i++) if (rows[i].installed) n++;
    return n;
  }
  readonly property int selectedCount: selectedRows().length

  function rowKey(row) { return Catalog.catalogKey(row); }
  function isSelected(key) { root.selectedKeys; return root.selectedKeys[key] === true; }

  function selectedRows() {
    var out = [];
    for (var i = 0; i < rows.length; i++)
      if (root.selectedKeys[rowKey(rows[i])] === true) out.push(rows[i]);
    return out;
  }

  // ── Catalog load / merge / save ─────────────────────────────────────────
  Component.onCompleted: Quickshell.execDetached(["mkdir", "-p", root.configDir])

  FileView {
    id: defaultsFile
    path: root.defaultCatalogPath
    printErrors: false
    onLoaded: {
      try { root.defaultRows = JSON.parse(String(text() || "[]")); }
      catch (e) { root.defaultRows = []; }
      root.tryMergeCatalog();
    }
    onLoadFailed: { root.defaultRows = []; root.tryMergeCatalog(); }
  }

  FileView {
    id: catalogFile
    path: root.catalogPath
    watchChanges: false          // only this plugin writes it
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var parsed = [];
      try { parsed = JSON.parse(String(text() || "[]")); } catch (e) { parsed = []; }
      if (!Array.isArray(parsed)) parsed = [];
      root._userRows = parsed;
      root.tryMergeCatalog();
    }
    onLoadFailed: {
      root._userRows = [];
      root.tryMergeCatalog();
    }
  }

  property var _userRows: null     // null until the catalog file resolves once

  // Merge only after BOTH files have reported in at least once.
  function tryMergeCatalog() {
    if (root._userRows === null) return;
    var merged = Catalog.mergeCatalog(root._userRows, root.defaultRows);
    var mergedJson = JSON.stringify(stripRows(merged));
    var userJson = JSON.stringify(stripRows(Catalog.normalizeCatalog(root._userRows)));
    root.rows = merged;
    root.catalogReady = true;
    pruneSelection();
    rebuild();
    if (mergedJson !== userJson) saveCatalog();   // first-run seed, or new defaults appended
    if (root.opened) refreshStatus();
  }

  function stripRows(list) {
    return (list || []).map(function (r) {
      return { name: r.name, description: r.description, type: r.type,
               ref: r.ref, id: r.id, link: r.link };
    });
  }

  Timer {
    id: saveTimer
    interval: 400
    onTriggered: catalogFile.setText(JSON.stringify(root.stripRows(root.rows), null, 2) + "\n")
  }
  function saveCatalog() { saveTimer.restart(); }

  // ── Status detection ───────────────────────────────────────────────────
  property bool scanning: false
  property bool manualRefresh: false

  Process {
    id: statusProc
    property bool queued: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var obj = null;
        try { obj = JSON.parse(String(text || "{}")); } catch (e) { obj = null; }
        if (obj) { root.statusObj = obj; root.applyStatus(); }
      }
    }
    onExited: {
      root.scanning = false;
      if (statusProc.queued) { statusProc.queued = false; Qt.callLater(function () { root.refreshStatus(); }); }
    }
  }

  // Re-run bin/loadout-status. `manual` shows a toast when it lands. Re-assigning
  // `command` each call is what makes Quickshell actually restart the Process.
  function refreshStatus(manual) {
    if (manual === true) root.manualRefresh = true;
    if (statusProc.running) { statusProc.queued = true; return; }
    root.scanning = true;
    statusProc.command = ["bash", root.statusScript];
    statusProc.running = true;
  }

  function applyStatus() {
    var countBefore = root.rows.length;
    var idsBefore = root.rows.map(function (r) { return String(r.id || ""); }).join("\u0000");
    // Pull in installed-but-uncatalogued plugins so the table is a real inventory.
    var withImports = Catalog.importInstalled(root.rows, root.statusObj);
    var reconciled = Catalog.reconcile(withImports, root.statusObj);
    root.rows = reconciled;
    var idsAfter = reconciled.map(function (r) { return String(r.id || ""); }).join("\u0000");
    if (reconciled.length !== countBefore || idsAfter !== idsBefore) { pruneSelection(); saveCatalog(); }

    if (root.manualRefresh) {
      root.manualRefresh = false;
      toast("Refreshed \u00b7 " + root.installedCount + " installed");
    }

    // Clear busy for job rows whose installed state has flipped since launch.
    if (root.jobKeys.length > 0) {
      var stillBusy = [];
      for (var i = 0; i < root.jobKeys.length; i++) {
        var k = root.jobKeys[i];
        var r = findRowByKey(k);
        if (r && r.installed !== root.jobInstalledAtLaunch[k]) setBusy([k], false);
        else stillBusy.push(k);
      }
      root.jobKeys = stillBusy;
      if (stillBusy.length === 0) refreshTimer.stop();
    }
    rebuild();
  }

  function findRowByKey(key) {
    for (var i = 0; i < root.rows.length; i++)
      if (rowKey(root.rows[i]) === key) return root.rows[i];
    return null;
  }

  // Poll status for a while after a fire-and-forget terminal job.
  Timer {
    id: refreshTimer
    interval: 3000
    repeat: true
    onTriggered: {
      root.refreshStatus();
      root.jobTicks++;
      if (root.jobTicks >= 8) {
        stop();
        root.setBusy(root.jobKeys, false);
        root.jobKeys = [];
      }
    }
  }

  // ── Selection ─────────────────────────────────────────────────────────
  //
  // `selectedKeys` is the source of truth (survives filtering). The visible
  // ListModel carries a mirror `selected` role so a checkbox re-renders without
  // rebuilding the whole list — which is what used to bounce the cursor/scroll
  // back to the top on every space press.
  function syncModelSelection() {
    for (var i = 0; i < listModel.count; i++)
      listModel.setProperty(i, "selected", root.selectedKeys[listModel.get(i).key] === true);
  }
  function toggleSel(key) {
    var next = {};
    for (var k in root.selectedKeys) next[k] = root.selectedKeys[k];
    if (next[key]) delete next[key]; else next[key] = true;
    root.selectedKeys = next;
    syncModelSelection();
  }
  function clearSelection() { root.selectedKeys = ({}); syncModelSelection(); }
  function selectAllVisible() {
    var next = {};
    for (var k in root.selectedKeys) next[k] = root.selectedKeys[k];
    var vis = Catalog.filterRows(root.rows, filterOpts());
    var allOn = vis.length > 0 && vis.every(function (r) { return next[rowKey(r)]; });
    for (var i = 0; i < vis.length; i++) {
      var key = rowKey(vis[i]);
      if (allOn) delete next[key]; else next[key] = true;
    }
    root.selectedKeys = next;
    syncModelSelection();
  }
  function pruneSelection() {
    var live = {};
    for (var i = 0; i < root.rows.length; i++) live[rowKey(root.rows[i])] = true;
    var next = {};
    for (var k in root.selectedKeys) if (live[k]) next[k] = true;
    root.selectedKeys = next;
  }

  function setBusy(keys, val) {
    var set = {};
    for (var i = 0; i < keys.length; i++) set[keys[i]] = true;
    var copy = root.rows.slice();
    for (var j = 0; j < copy.length; j++)
      if (set[rowKey(copy[j])]) copy[j] = Object.assign({}, copy[j], { busy: val });
    root.rows = copy;
    rebuild();
  }

  // ── Model rebuild (filter → ListModel) ────────────────────────────────
  function filterOpts() {
    return { type: root.filterType, query: root.query, installedOnly: root.installedOnly };
  }
  function rebuild() {
    var vis = Catalog.filterRows(root.rows, filterOpts());
    var keepKey = (root.cursorIndex >= 0 && root.cursorIndex < listModel.count)
      ? listModel.get(root.cursorIndex).key : "";
    listModel.clear();
    var keepAt = 0;
    for (var i = 0; i < vis.length; i++) {
      var r = vis[i];
      var k = rowKey(r);
      if (k === keepKey) keepAt = i;
      listModel.append({
        key: k,
        name: String(r.name || ""),
        description: String(r.description || ""),
        type: String(r.type || ""),
        ref: String(r.ref || ""),
        entryId: String(r.id || ""),
        link: String(r.link || ""),
        installed: r.installed === true,
        entryEnabled: r.enabled === true,
        busy: r.busy === true,
        selected: root.selectedKeys[k] === true
      });
    }
    root.cursorIndex = vis.length === 0 ? -1
      : Math.max(0, Math.min(keepKey ? keepAt : root.cursorIndex, vis.length - 1));
    // listModel.clear() resets the ListView's currentIndex; restore it once the
    // new delegates exist so the cursor doesn't jump to the top.
    if (table) Qt.callLater(table.syncCursor);
  }
  onFilterTypeChanged: rebuild()
  onQueryChanged: rebuild()
  onInstalledOnlyChanged: rebuild()

  ListModel { id: listModel }

  // ── Keyboard row cursor ─────────────────────────────────────────────
  function rowAtCursor() {
    if (root.cursorIndex < 0 || root.cursorIndex >= listModel.count) return null;
    return findRowByKey(listModel.get(root.cursorIndex).key);
  }
  function moveCursor(delta) {
    if (listModel.count === 0) return;
    root.cursorIndex = Math.max(0, Math.min(root.cursorIndex + delta, listModel.count - 1));
    table.ensureCursorVisible();
  }
  function setCursor(idx) {
    if (listModel.count === 0) return;
    root.cursorIndex = Math.max(0, Math.min(idx, listModel.count - 1));
    table.ensureCursorVisible();
  }
  function cursorToggleSel() {
    var r = rowAtCursor();
    if (r) toggleSel(rowKey(r));
  }
  function cursorEdit() {
    var r = rowAtCursor();
    if (r) editRow(r);
  }
  function cursorRun(action) {
    var r = rowAtCursor();
    if (!r || r.busy) return;
    if (action === "add" && r.installed) { toast("Already installed"); return; }
    if (action === "remove" && !r.installed) { toast("Not installed"); return; }
    runRow(r, action);
  }
  function cursorOpenLink() {
    var r = rowAtCursor();
    if (r && r.link) openLink(r.link);
  }

  // ── Tab focus ring ─────────────────────────────────────────────────
  //
  // Quickshell's platform reports tabFocusBehavior = Qt.TabFocusTextControls,
  // so the built-in Tab chain skips every Button and just re-focuses the
  // search field. We drive the ring ourselves: an explicit, ordered list of
  // controls, forceActiveFocus() onto the next visible + enabled one.
  function focusRing() {
    var out = [refreshBtn, newBtn, closeBtn];
    for (var i = 0; i < filterRep.count; i++) {
      var it = filterRep.itemAt(i);
      if (it) out.push(it);
    }
    out.push(searchField, installedBtn, selectAllBtn, clearBtn, addBtn, removeBtn, table);
    return out.filter(function (c) {
      return c && c.visible && c.enabled !== false;
    });
  }
  function focusStep(dir) {
    var ring = focusRing();
    if (ring.length === 0) return;
    var cur = -1;
    for (var i = 0; i < ring.length; i++)
      if (ring[i].activeFocus) { cur = i; break; }
    var next = cur < 0 ? (dir > 0 ? 0 : ring.length - 1)
                       : (cur + dir + ring.length) % ring.length;
    ring[next].forceActiveFocus(dir < 0 ? Qt.BacktabFocusReason : Qt.TabFocusReason);
  }

  // ── Catalog editing (RowEditor) ──────────────────────────────────────
  function upsertRow(original, edited) {
    var copy = root.rows.slice();
    var norm = Catalog.normalizeRow(edited);
    if (original) {
      var oldKey = rowKey(original);
      for (var i = 0; i < copy.length; i++) {
        if (rowKey(copy[i]) === oldKey) { copy[i] = Object.assign({}, norm); break; }
      }
    } else {
      copy.push(Object.assign({}, norm));
    }
    root.rows = copy;
    pruneSelection();
    saveCatalog();
    rebuild();
    refreshStatus();
  }
  function deleteRow(original) {
    if (!original) return;
    var key = rowKey(original);
    root.rows = root.rows.filter(function (r) { return rowKey(r) !== key; });
    pruneSelection();
    saveCatalog();
    rebuild();
  }
  function editRow(obj) { rowEditor.openFor(obj); }

  // ── Running jobs ─────────────────────────────────────────────────────
  function quote(s) { return Util.shellQuote(s); }

  function keysOfGroups(groups) {
    var keys = [];
    ["pacman", "aur", "flatpak", "omarchy", "hyprland"].forEach(function (t) {
      (groups[t] || []).forEach(function (r) { keys.push(rowKey(r)); });
    });
    return keys;
  }

  // Human, itemized list of exactly what a job will touch — one line per row
  // with the underlying package / plugin target spelled out.
  function manifestLines(groups) {
    var label = { pacman: "Program", aur: "AUR", flatpak: "Flatpak",
                  omarchy: "Omarchy plugin", hyprland: "Hyprland plugin" };
    var lines = [];
    ["pacman", "aur", "flatpak", "omarchy", "hyprland"].forEach(function (t) {
      (groups[t] || []).forEach(function (r) {
        var target = (t === "hyprland")
          ? (Catalog.repoNameFromUrl(r.ref) || r.id || "")
          : (t === "omarchy") ? (r.id || r.ref || "")
          : String(r.ref || "");
        var nm = String(r.name || target || "(unnamed)");
        var paren = (target && target !== nm) ? (target + ", " + label[t]) : label[t];
        lines.push("•  " + nm + "  (" + paren + ")");
      });
    });
    return lines;
  }

  // A shell snippet that prints the job manifest into the terminal right before
  // the command runs — the terminal itself shows the count + every item, then
  // the package tools take over (and, for remove, ask for sudo).
  function jobBanner(groups, action) {
    var lines = manifestLines(groups);
    var n = lines.length;
    var head = action === "remove"
      ? ("Removing " + n + (n === 1 ? " item" : " items") +
         " from your loadout — they stay listed so you can re-add them:")
      : ("Installing " + n + (n === 1 ? " item" : " items") + " into your loadout:");
    var out = [head, ""].concat(lines.map(function (l) { return "  " + l; })).concat([""]);
    return "printf '%s\\n' " + out.map(root.quote).join(" ");
  }

  function launch(cmd, keys) {
    if (!cmd) { toast("Nothing to do"); return; }
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd]);
    var snap = {};
    for (var i = 0; i < keys.length; i++) {
      var r = findRowByKey(keys[i]);
      snap[keys[i]] = r ? r.installed === true : false;
    }
    root.jobInstalledAtLaunch = snap;
    root.jobKeys = keys.slice();
    root.jobTicks = 0;
    setBusy(keys, true);
    refreshTimer.restart();
  }

  function runRow(row, action) {
    var groups = Catalog.groupByType([row]);
    var cmd = Catalog.buildCommand(groups, action, root.quote);
    launch(cmd, keysOfGroups(groups));
  }

  function runBulk(action) {
    var sel = selectedRows();
    if (sel.length === 0) { toast("Select some rows first"); return; }
    var groups = action === "add" ? Catalog.groupForInstall(sel) : Catalog.groupForRemove(sel);
    var cmd = Catalog.buildCommand(groups, action, root.quote);
    if (!cmd) { toast(action === "add" ? "Everything selected is already installed" : "Nothing selected is installed"); return; }
    var keys = keysOfGroups(groups);
    // Add and Remove both hand off to the terminal, in this order:
    //   1. launch the terminal so the job is already on its way;
    //   2. tear the panel down at once (no fade) so its exclusive keyboard
    //      grab is released and the terminal can take focus;
    //   3. nudge Hyprland to focus that terminal, in case it didn't land
    //      there when our layer surface went away.
    // Both print an itemized manifest ahead of the command; remove additionally
    // stops at the sudo prompt.
    var full = jobBanner(groups, action) + " && " + cmd;
    launch(full, keys);
    root.finishClose();
    focusTerminalSoon();
  }

  // Re-assert focus on the Omarchy terminal a few times while it maps.
  Timer {
    id: focusTermTimer
    interval: 200
    repeat: true
    property int shots: 0
    onTriggered: {
      Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow",
                               "class:^(org\\.omarchy\\.terminal)$"]);
      if (++focusTermTimer.shots >= 3) focusTermTimer.stop();
    }
  }
  function focusTerminalSoon() { focusTermTimer.shots = 0; focusTermTimer.restart(); }

  function openLink(link) {
    if (link) Quickshell.execDetached(["xdg-open", link]);
  }

  Timer { id: toastTimer; interval: 2600; onTriggered: root.toastText = "" }
  function toast(t) { root.toastText = t; toastTimer.restart(); }

  // ── Lifecycle verbs (overlay contract) ──────────────────────────────
  function open(payloadJson) {
    closeTimer.stop();
    root.closing = false;
    rowEditor.opened = false;
    root.opened = true;
    root.cursorIndex = 0;
    root.filterType = "all";
    root.query = "";
    root.installedOnly = false;
    root.selectedKeys = ({});
    if (root.catalogReady) { rebuild(); refreshStatus(); }
    Qt.callLater(function () { keyCatcher.forceActiveFocus(); });
  }
  function close() {
    closeTimer.stop();
    root.opened = false;
    root.closing = false;
    root.query = "";
  }
  function dismiss() {
    if (!root.opened && !root.closing) {
      if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId);
      return;
    }
    if (root.closing) return;
    root.opened = false;
    root.closing = true;
    closeTimer.restart();
  }
  function finishClose() {
    root.close();
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId);
  }
  function toggle() {
    if (root.opened && !root.closing) root.dismiss();
    else if (!root.closing) root.open("{}");
  }
  function summon(payloadJson) { root.open(payloadJson || "{}"); }
  function hide() { root.dismiss(); }

  Timer { id: closeTimer; interval: 200; onTriggered: root.finishClose() }

  // ── The overlay surface ────────────────────────────────────────────
  PanelWindow {
    id: panel

    visible: root.opened || root.closing
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"

    WlrLayershell.namespace: "omarchy-loadout"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      id: scrim
      anchors.fill: parent
      color: Util.alpha(Color.background, 0.82)
      opacity: root.revealed ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      TapHandler { onTapped: root.dismiss() }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      // Keep list focus after a modal closes.
      Connections {
        target: rowEditor
        function onOpenedChanged() { if (!rowEditor.opened) Qt.callLater(function () { keyCatcher.forceActiveFocus(); }); }
      }

      Keys.onPressed: function (event) {
        var isTab = event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab;
        var back = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) !== 0;

        // The row editor owns the keyboard; let Tab navigate its own fields
        // and buttons, and Escape backs out.
        if (rowEditor.opened) {
          if (isTab) { event.accepted = false; return; }
          if (event.key === Qt.Key_Escape) { rowEditor.opened = false; event.accepted = true; }
          return;
        }

        // Tab / Shift+Tab step the panel's focus ring (see focusStep — the
        // platform's own Tab chain can't reach the buttons here).
        if (isTab) { root.focusStep(back ? -1 : 1); event.accepted = true; return; }

        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0;

        // While typing in search, Escape is the only shortcut (back to the list).
        if (searchField.activeFocus) {
          if (event.key === Qt.Key_Escape) { keyCatcher.forceActiveFocus(); event.accepted = true; }
          return;
        }

        if (ctrl && event.key === Qt.Key_F) { searchField.forceActiveFocus(); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_A) { root.selectAllVisible(); event.accepted = true; return; }
        if (ctrl) return;

        var handled = true;
        switch (event.key) {
        case Qt.Key_Escape:   root.dismiss(); break;
        case Qt.Key_Down:     root.moveCursor(1); break;
        case Qt.Key_Up:       root.moveCursor(-1); break;
        case Qt.Key_PageDown: root.moveCursor(10); break;
        case Qt.Key_PageUp:   root.moveCursor(-10); break;
        case Qt.Key_Home:     root.setCursor(0); break;
        case Qt.Key_End:      root.setCursor(listModel.count - 1); break;
        case Qt.Key_Space:    root.cursorToggleSel(); break;
        case Qt.Key_Return:
        case Qt.Key_Enter:    root.cursorEdit(); break;
        default:              handled = false;
        }

        if (!handled) {
          var t = event.text;
          handled = true;
          if (t === "j") root.moveCursor(1);
          else if (t === "k") root.moveCursor(-1);
          else if (t === "g") root.setCursor(0);
          else if (t === "G") root.setCursor(listModel.count - 1);
          else if (t === "/") searchField.forceActiveFocus();
          else if (t === "n") rowEditor.openFor(null);
          else if (t === "r") root.refreshStatus(true);
          else if (t === "i") root.installedOnly = !root.installedOnly;
          else if (t === "o") root.cursorOpenLink();
          else if (t === "a") root.cursorRun("add");
          else if (t === "d" || t === "x") root.cursorRun("remove");
          else if (t === "A") root.runBulk("add");
          else if (t === "D" || t === "X" || t === "R") root.runBulk("remove");
          else if (t === "c") root.clearSelection();
          else if (t.length === 1 && t >= "1" && t <= "6")
            root.filterType = ["all", "pacman", "aur", "flatpak", "omarchy", "hyprland"][parseInt(t, 10) - 1];
          else handled = false;
        }
        event.accepted = handled;
      }

      // Centered card
      Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(1180, parent.width * 0.92)
        height: parent.height * 0.84
        radius: Math.max(8, Style.cornerRadius)
        color: Color.background
        border.width: 1
        border.color: Util.alpha(Color.foreground, 0.14)
        opacity: root.revealed ? 1 : 0
        scale: root.revealed ? 1 : 0.97
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        // Swallow clicks so a tap inside the card doesn't fall through to the scrim.
        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
          anchors.fill: parent
          anchors.margins: Style.space(18)
          spacing: Style.space(12)

          // ── Header ────────────────────────────────────────────────
          Row {
            width: parent.width
            spacing: Style.space(10)

            Column {
              width: parent.width - headerActions.width - Style.space(10)
              spacing: 2
              Text {
                text: "LOADOUT"
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.6
              }
              Text {
                width: parent.width
                text: root.installedCount + " installed · " + root.rows.length +
                  " in loadout · " + root.selectedCount + " selected"
                color: Util.alpha(Color.foreground, 0.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Row {
              id: headerActions
              spacing: Style.space(6)
              Button {
                id: refreshBtn
                iconText: "↻"
                bordered: true
                focusable: true
                iconSpinning: root.scanning
                tooltipText: "Refresh status (r)"
                onClicked: root.refreshStatus(true)
              }
              Button {
                id: newBtn
                text: "＋ New"
                bordered: true
                focusable: true
                onClicked: rowEditor.openFor(null)
              }
              Button {
                id: closeBtn
                iconText: "×"
                bordered: true
                focusable: true
                tooltipText: "Close (Esc)"
                onClicked: root.dismiss()
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ── Filter bar ───────────────────────────────────────────
          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              id: filterRep
              model: [
                { value: "all", label: "All", key: "1" },
                { value: "pacman", label: "Programs", key: "2" },
                { value: "aur", label: "AUR", key: "3" },
                { value: "flatpak", label: "Flatpak", key: "4" },
                { value: "omarchy", label: "Omarchy", key: "5" },
                { value: "hyprland", label: "Hyprland", key: "6" }
              ]
              delegate: Button {
                required property var modelData
                text: modelData.label
                bordered: true
                focusable: true
                fontSize: Style.font.caption
                tooltipText: "Filter (" + modelData.key + ")"
                active: root.filterType === modelData.value
                onClicked: root.filterType = modelData.value
              }
            }

            Item { Layout.fillWidth: true; implicitHeight: 1 }

            TextField {
              id: searchField
              Layout.preferredWidth: Style.space(180)
              placeholderText: "Search…  (/)"
              text: root.query
              onTextChanged: root.query = text
              Keys.onPressed: function (e) {
                // Escape drops back to the list; Tab / Shift+Tab step the ring
                // (handled here because a focused TextField consumes the key
                // before it can reach the panel's key catcher).
                if (e.key === Qt.Key_Escape) {
                  keyCatcher.forceActiveFocus();
                  e.accepted = true;
                } else if (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) {
                  root.focusStep((e.key === Qt.Key_Backtab || (e.modifiers & Qt.ShiftModifier)) ? -1 : 1);
                  e.accepted = true;
                }
              }
            }
            Button {
              id: installedBtn
              text: "Installed only"
              bordered: true
              focusable: true
              fontSize: Style.font.caption
              active: root.installedOnly
              onClicked: root.installedOnly = !root.installedOnly
            }
          }

          // ── Action bar ───────────────────────────────────────────
          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Button {
              id: selectAllBtn
              text: "Select all"
              bordered: true
              focusable: true
              fontSize: Style.font.caption
              tooltipText: "Ctrl+A"
              onClicked: root.selectAllVisible()
            }
            Button {
              id: clearBtn
              text: "Clear"
              bordered: true
              focusable: true
              fontSize: Style.font.caption
              enabled: root.selectedCount > 0
              onClicked: root.clearSelection()
            }
            Item { Layout.fillWidth: true; implicitHeight: 1 }
            Button {
              id: addBtn
              text: "Add selected"
              bordered: true
              focusable: true
              accent: Color.accent
              active: root.selectedCount > 0
              enabled: root.selectedCount > 0 && !root.anyBusy
              onClicked: root.runBulk("add")
            }
            Button {
              id: removeBtn
              text: "Remove selected"
              bordered: true
              focusable: true
              // Destructive — paint it with the theme's urgent colour, and fill
              // it once rows are selected so it clearly reads as "this deletes".
              accent: Color.urgent
              foreground: (root.selectedCount > 0 && !root.anyBusy) ? Color.background : Color.urgent
              background: (root.selectedCount > 0 && !root.anyBusy) ? Color.urgent : "transparent"
              enabled: root.selectedCount > 0 && !root.anyBusy
              onClicked: root.runBulk("remove")
            }
          }

          // ── Table ────────────────────────────────────────────────
          LoadoutTable {
            id: table
            width: parent.width
            height: parent.height - y - footer.height - Style.space(8)
            model: listModel
            controller: root
            cursorIndex: root.cursorIndex
          }

          // ── Keyboard hint footer ────────────────────────────────
          Text {
            id: footer
            width: parent.width
            text: "tab focus controls · j/k move · space select · ⏎ edit · a add · d remove · o link · / search · " +
              "n new · r refresh · i installed-only · 1–6 filter · A/D bulk · esc close"
            color: Util.alpha(Color.foreground, 0.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        // Toast
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(14)
          visible: root.toastText.length > 0
          width: toastLabel.implicitWidth + Style.space(24)
          height: toastLabel.implicitHeight + Style.space(12)
          radius: height / 2
          color: Util.alpha(Color.foreground, 0.92)
          Text {
            id: toastLabel
            anchors.centerIn: parent
            text: root.toastText
            color: Color.background
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      // ── Row editor ────────────────────────────────────────────
      RowEditor {
        id: rowEditor
        anchors.fill: parent
        z: 40
        onSubmitted: function (original, edited) { root.upsertRow(original, edited); opened = false; }
        onDeleted: function (original) { root.deleteRow(original); opened = false; }
      }
    }
  }

  readonly property bool anyBusy: {
    for (var i = 0; i < rows.length; i++) if (rows[i].busy) return true;
    return false;
  }
}
