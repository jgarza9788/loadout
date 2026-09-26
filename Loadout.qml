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
  readonly property string catalogHelper:
    Qt.resolvedUrl("bin/loadout-catalog").toString().replace(/^file:\/\//, "")
  readonly property string aurTool:
    Qt.resolvedUrl("bin/omarchy-aur").toString().replace(/^file:\/\//, "")

  // ── Trusted process launch ─────────────────────────────────────────────
  //
  // Every helper runs by absolute path with a cleared environment and a pinned
  // PATH, so nothing planted in the session's PATH is ever executed.
  readonly property string trustedPath: "/usr/bin:/usr/share/omarchy/bin"
  readonly property var trustedEnv: ({
    PATH: root.trustedPath,
    HOME: root.homeDir,
    XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR") || "",
    WAYLAND_DISPLAY: Quickshell.env("WAYLAND_DISPLAY") || "",
    LANG: "C.UTF-8"
  })
  readonly property int statusDeadlineSec: 20
  readonly property int statusMaxBytes: 4194304
  // Detached GUI launches keep the session env (the terminal needs it) but
  // never resolve anything through the inherited PATH.
  function spawn(argv) {
    Quickshell.execDetached({ command: argv, environment: { PATH: root.trustedPath } });
  }

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
  property bool helpOpen: false

  // AUR mode — see Catalog.js. System-wide state owned by bin/omarchy-aur;
  // read back through bin/loadout-status on every refresh.
  property string aurMode: "enabled"
  readonly property bool aurHidden: aurMode === "disabled"
  readonly property var aurModeLabel: ({ enabled: "AUR: on", updates: "AUR: updates only", disabled: "AUR: off" })

  // The filter tabs actually shown (AUR drops out while hidden). h/l cycle
  // them and the number keys pick them in on-screen order.
  readonly property var filterChips: [
    { value: "all", label: "All" },
    { value: "pacman", label: "Programs" },
    { value: "aur", label: "AUR" },
    { value: "flatpak", label: "Flatpak" },
    { value: "omarchy", label: "Omarchy" },
    { value: "hyprland", label: "Hyprland" }
  ].filter(function (c) { return !(c.value === "aur" && root.aurHidden); })
  readonly property var filterTypes: filterChips.map(function (c) { return c.value; })

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
  // The catalog lives at a predictable, user-writable path, so it is never
  // opened directly: bin/loadout-catalog reads and writes it through a single
  // O_NOFOLLOW|O_NONBLOCK descriptor with type / owner / size checks, and
  // replaces it atomically (see that script). It also creates configDir 0700.
  Component.onCompleted: catalogReadProc.running = true
  Component.onDestruction: {
    statusWatchdog.stop();
    statusProc.running = false;
  }

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

  // Set when catalog.json was rejected; saving stays off for the session so
  // the seed never overwrites (or follows) a file we refused to read.
  property string catalogError: ""

  Process {
    id: catalogReadProc
    command: ["/usr/bin/timeout", "-k", "2", "10",
              "/usr/bin/python3", "-I", "-S", root.catalogHelper, "read", root.catalogPath]
    clearEnvironment: true
    environment: root.trustedEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = null;
        try { parsed = JSON.parse(String(text || "")); } catch (e) { parsed = null; }
        if (Array.isArray(parsed)) {
          root._userRows = parsed;
        } else {
          root.catalogError = (parsed && parsed.error) ? String(parsed.error) : "unreadable";
          root._userRows = [];
          root.toast("catalog.json rejected: " + root.catalogError);
        }
        root.tryMergeCatalog();
      }
    }
  }

  Process {
    id: catalogWriteProc
    property string pending: ""
    property bool queued: false
    command: ["/usr/bin/timeout", "-k", "2", "10",
              "/usr/bin/python3", "-I", "-S", root.catalogHelper, "write", root.catalogPath]
    clearEnvironment: true
    environment: root.trustedEnv
    stdinEnabled: true
    onStarted: {
      catalogWriteProc.write(catalogWriteProc.pending);
      catalogWriteProc.stdinEnabled = false;       // closes stdin → helper sees EOF
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = null;
        try { res = JSON.parse(String(text || "")); } catch (e) { res = null; }
        if (!res || !res.ok) root.toast("Could not save catalog: " + ((res && res.error) || "helper failed"));
      }
    }
    onExited: {
      if (catalogWriteProc.queued) { catalogWriteProc.queued = false; Qt.callLater(root.writeCatalogNow); }
    }
  }

  function writeCatalogNow() {
    if (root.catalogError) return;
    if (catalogWriteProc.running) { catalogWriteProc.queued = true; return; }
    catalogWriteProc.pending = JSON.stringify(root.stripRows(root.rows), null, 2) + "\n";
    catalogWriteProc.stdinEnabled = true;
    catalogWriteProc.running = true;
  }

  property var _userRows: null     // null until the catalog file resolves once

  // The AUR button opens bin/omarchy-aur's picker in the floating terminal:
  // it changes /etc/hosts, yay/paru config and a pacman hook, so it needs sudo
  // and a confirmation keypress. The next status refresh picks up the result.
  function chooseAurMode() {
    root.spawn(["/usr/share/omarchy/bin/omarchy-launch-floating-terminal-with-presentation",
                "/usr/bin/bash " + root.quote(root.aurTool) + " --choose"]);
    root.finishClose();
    focusTerminalSoon();
  }
  onAurModeChanged: {
    if (root.aurHidden && root.filterType === "aur") root.filterType = "all";
    pruneSelection();
    syncModelSelection();
    rebuild();
  }

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
    onTriggered: root.writeCatalogNow()
  }
  function saveCatalog() { saveTimer.restart(); }

  // ── Status detection ───────────────────────────────────────────────────
  property bool scanning: false
  property bool manualRefresh: false

  // bin/loadout-status, bounded as a whole: `timeout` (no --foreground) puts
  // the probe in its own process group and kills the entire group at the
  // deadline; `head -c` caps what reaches the collector; the watchdog below is
  // a backstop in case the timeout itself wedges.
  Process {
    id: statusProc
    property bool queued: false
    clearEnvironment: true
    environment: root.trustedEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "");
        if (raw.length >= root.statusMaxBytes) return;   // truncated by the cap — ignore
        var obj = null;
        try { obj = JSON.parse(raw || "{}"); } catch (e) { obj = null; }
        if (obj && typeof obj === "object" && !Array.isArray(obj)) { root.statusObj = obj; root.applyStatus(); }
      }
    }
    onExited: {
      statusWatchdog.stop();
      root.scanning = false;
      if (statusProc.queued) { statusProc.queued = false; Qt.callLater(function () { root.refreshStatus(); }); }
    }
  }

  Timer {
    id: statusWatchdog
    interval: (root.statusDeadlineSec + 5) * 1000
    onTriggered: statusProc.running = false
  }

  // Re-run bin/loadout-status. `manual` shows a toast when it lands. Re-assigning
  // `command` each call is what makes Quickshell actually restart the Process.
  function refreshStatus(manual) {
    if (manual === true) root.manualRefresh = true;
    if (statusProc.running) { statusProc.queued = true; return; }
    root.scanning = true;
    statusProc.command = [
      "/usr/bin/timeout", "-k", "3", String(root.statusDeadlineSec),
      "/usr/bin/bash", "--noprofile", "--norc", "-c",
      "\"$1\" | /usr/bin/head -c " + root.statusMaxBytes,
      "loadout-status", root.statusScript
    ];
    statusProc.running = true;
    statusWatchdog.restart();
  }

  function applyStatus() {
    var countBefore = root.rows.length;
    var idsBefore = root.rows.map(function (r) { return String(r.id || ""); }).join("\u0000");
    // Pull in installed-but-uncatalogued plugins so the table is a real inventory.
    var withImports = Catalog.importInstalled(root.rows, root.statusObj);
    var reconciled = Catalog.reconcile(withImports, root.statusObj);
    root.aurMode = Catalog.normalizeAurMode(root.statusObj.aur);
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
    for (var i = 0; i < root.rows.length; i++)
      if (!(root.aurHidden && root.rows[i].type === "aur")) live[rowKey(root.rows[i])] = true;
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
    return { type: root.filterType, query: root.query, installedOnly: root.installedOnly, aurMode: root.aurMode };
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
  // Shift+↓/↑ (or J/K): select the cursor row, then move and select the next —
  // a keyboard range select.
  function extendSelection(delta) {
    if (listModel.count === 0) return;
    var next = {};
    for (var k in root.selectedKeys) next[k] = root.selectedKeys[k];
    var from = listModel.get(root.cursorIndex);
    if (from) next[from.key] = true;
    root.cursorIndex = Math.max(0, Math.min(root.cursorIndex + delta, listModel.count - 1));
    var to = listModel.get(root.cursorIndex);
    if (to) next[to.key] = true;
    root.selectedKeys = next;
    syncModelSelection();
    table.ensureCursorVisible();
  }
  function cycleFilter(delta) {
    var i = Math.max(0, root.filterTypes.indexOf(root.filterType));
    root.filterType = root.filterTypes[(i + delta + root.filterTypes.length) % root.filterTypes.length];
  }
  function halfPage() { return Math.max(1, Math.floor(table.height / 42 / 2)); }

  // Delete key: drop the cursor row from the catalog (not an uninstall).
  // Two-step so a stray key can't lose a row.
  property string pendingDeleteKey: ""
  Timer { id: deleteConfirmTimer; interval: 3000; onTriggered: root.pendingDeleteKey = "" }
  function cursorDelete() {
    var r = rowAtCursor();
    if (!r) return;
    var k = rowKey(r);
    if (root.pendingDeleteKey === k) {
      root.pendingDeleteKey = "";
      deleteConfirmTimer.stop();
      deleteRow(r);
      toast("Removed \u201c" + r.name + "\u201d from the loadout");
      return;
    }
    root.pendingDeleteKey = k;
    deleteConfirmTimer.restart();
    toast("Press Delete again to drop \u201c" + r.name + "\u201d from the loadout" +
          (r.installed ? " (stays installed)" : ""));
  }

  // Esc peels back one layer at a time: help → pending delete → search text → close.
  function backOut() {
    if (root.helpOpen) { root.helpOpen = false; return; }
    if (root.pendingDeleteKey) { root.pendingDeleteKey = ""; toast("Cancelled"); return; }
    if (root.query) { root.query = ""; return; }
    root.dismiss();
  }
  function cursorEdit() {
    var r = rowAtCursor();
    if (r) editRow(r);
  }
  function cursorRun(action) {
    var r = rowAtCursor();
    if (!r || r.busy) return;
    if (action === "update" && r.type !== "aur") { toast("Update is for AUR rows"); return; }
    if (r.type === "aur" && !Catalog.aurAllows(root.aurMode, action)) {
      toast(root.aurModeLabel[root.aurMode] + " \u00b7 can't " + action); return;
    }
    if (action === "add" && r.installed) { toast("Already installed"); return; }
    if ((action === "remove" || action === "update") && !r.installed) { toast("Not installed"); return; }
    var bad = Catalog.rowTargetError(r);
    if (bad) { toast(bad); return; }
    runRow(r, action);
  }
  function cursorOpenLink() {
    var r = rowAtCursor();
    if (r && r.link) openLink(r.link);
  }

  // ── Keyboard sections ──────────────────────────────────────────────
  //
  // The panel is five numbered sections (see Section.qml), in the order you
  // work: 1 search, 2 type filters, 3 the list, 4 act on the marked rows,
  // 5 loadout-level buttons (new / refresh / AUR mode). Tab / Shift+Tab and
  // the number keys move between sections; arrows / h j k l move within one.
  // Quickshell's own Tab chain only visits text fields, so all of this is
  // driven by hand with forceActiveFocus(). Close (×) sits outside the
  // sections — Esc / q already close.
  readonly property int searchSection: 0
  readonly property int listSection: 2
  function sections() { return [secSearch, secFilter, secList, secActions, secLoadout]; }
  function sectionItems(i) {
    var out;
    if (i === 0) out = [searchField];
    else if (i === 1) {
      out = [];
      for (var c = 0; c < filterRep.count; c++) out.push(filterRep.itemAt(c));
      out.push(installedBtn);
    }
    else if (i === 2) out = [table];
    else if (i === 3) out = [selectAllBtn, clearBtn, addBtn, updateBtn, removeBtn];
    else out = [newBtn, refreshBtn, aurModeBtn];
    return out.filter(function (it) { return it && it.visible && it.enabled !== false; });
  }
  function currentSection() {
    var secs = sections();
    for (var i = 0; i < secs.length; i++) if (secs[i].activeFocus) return i;
    return root.listSection;
  }
  // Last item focused in each section, so coming back lands where you left.
  property var sectionLast: ({})
  function gotoSection(i) {
    var n = sections().length;
    i = ((i % n) + n) % n;
    var items = sectionItems(i);
    if (!items.length) return;
    var last = root.sectionLast[i];
    (items.indexOf(last) !== -1 ? last : items[0]).forceActiveFocus(Qt.TabFocusReason);
  }
  function sectionMove(delta) {
    var sec = currentSection();
    var items = sectionItems(sec);
    if (!items.length) return;
    var cur = -1;
    for (var i = 0; i < items.length; i++) if (items[i].activeFocus) { cur = i; break; }
    var next = Math.max(0, Math.min(cur + delta, items.length - 1));
    items[next].forceActiveFocus(Qt.TabFocusReason);
    var mem = {};
    for (var k in root.sectionLast) mem[k] = root.sectionLast[k];
    mem[sec] = items[next];
    root.sectionLast = mem;
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
      : action === "update"
      ? ("Updating " + n + " AUR " + (n === 1 ? "package" : "packages") + " (skipped if already current):")
      : ("Installing " + n + (n === 1 ? " item" : " items") + " into your loadout:");
    var out = [head, ""].concat(lines.map(function (l) { return "  " + l; })).concat([""]);
    return "printf '%s\\n' " + out.map(root.quote).join(" ");
  }

  function launch(cmd, keys) {
    if (!cmd) { toast("Nothing to do"); return; }
    root.spawn(["/usr/share/omarchy/bin/omarchy-launch-floating-terminal-with-presentation", cmd]);
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
    var cmd = Catalog.buildCommand(groups, action, root.quote, root.aurMode);
    launch(cmd, keysOfGroups(groups));
  }

  function runBulk(action) {
    if (root.anyBusy) { toast("Wait for the running job to finish"); return; }
    var sel = selectedRows();
    if (sel.length === 0) { toast("Mark some rows first (space in the list)"); return; }
    var invalid = sel.filter(function (r) { return Catalog.rowTargetError(r) !== ""; }).length;
    var groups = action === "add" ? Catalog.groupForInstall(sel)
      : action === "update" ? Catalog.groupForUpdate(sel)
      : Catalog.groupForRemove(sel);
    // AUR rows the mode forbids are left out of the job (buildCommand drops
    // them too); say so rather than skip them silently.
    var blocked = 0;
    if (!Catalog.aurAllows(root.aurMode, action)) { blocked = (groups.aur || []).length; groups.aur = []; }
    var cmd = Catalog.buildCommand(groups, action, root.quote, root.aurMode);
    var skipped = [];
    if (invalid) skipped.push(invalid + (invalid === 1 ? " row" : " rows") + " skipped: invalid target");
    if (blocked) skipped.push(blocked + " AUR " + (blocked === 1 ? "row" : "rows") + " skipped: " + root.aurModeLabel[root.aurMode]);
    if (!cmd) {
      toast(skipped.length ? skipped.join(" \u00b7 ")
        : action === "add" ? "Everything selected is already installed"
        : action === "update" ? "No installed AUR rows selected"
        : "Nothing selected is installed");
      return;
    }
    if (skipped.length) toast(skipped.join(" \u00b7 "));
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
      root.spawn(["/usr/bin/hyprctl", "dispatch", "focuswindow",
                  "class:^(org\\.omarchy\\.terminal)$"]);
      if (++focusTermTimer.shots >= 3) focusTermTimer.stop();
    }
  }
  function focusTerminalSoon() { focusTermTimer.shots = 0; focusTermTimer.restart(); }

  // Only plain https links, so a catalog value can never become an xdg-open
  // option or a file:/custom-scheme handler launch.
  function openLink(link) {
    var s = String(link || "");
    if (/^https:\/\/[^\s]+$/.test(s)) root.spawn(["/usr/bin/xdg-open", s]);
    else if (s) toast("Only https links can be opened");
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
    root.helpOpen = false;
    root.pendingDeleteKey = "";
    if (root.catalogReady) { rebuild(); refreshStatus(); }
    Qt.callLater(function () { table.forceActiveFocus(); });
  }
  function close() {
    closeTimer.stop();
    if (statusProc.running && root.jobKeys.length === 0) { statusWatchdog.stop(); statusProc.running = false; }
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
        function onOpenedChanged() { if (!rowEditor.opened) Qt.callLater(function () { table.forceActiveFocus(); }); }
      }

      Keys.onPressed: function (event) {
        var isTab = event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab;
        var back = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) !== 0;

        // The row editor owns the keyboard (its own focus ring + shortcuts).
        if (rowEditor.opened) {
          if (rowEditor.handleKey(event)) event.accepted = true;
          return;
        }

        // The shortcut sheet is modal: ? / Esc / q close it.
        if (root.helpOpen) {
          if (event.key === Qt.Key_Escape || event.text === "?" || event.text === "q") root.helpOpen = false;
          event.accepted = true;
          return;
        }

        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        var sec = root.currentSection();

        // Tab / Shift+Tab: next / previous section.
        if (isTab) { root.gotoSection(sec + (back ? -1 : 1)); event.accepted = true; return; }

        // Search (section 1) types freely — digits included; its own key
        // handler covers Tab / Esc / ⏎ / ↑↓.
        if (searchField.activeFocus) return;

        if (ctrl && event.key === Qt.Key_F) { root.gotoSection(root.searchSection); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_A) { root.selectAllVisible(); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_D) { root.moveCursor(root.halfPage()); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_U) { root.moveCursor(-root.halfPage()); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_R) { root.refreshStatus(true); event.accepted = true; return; }
        if (ctrl) return;

        var t = event.text;
        var k = event.key;

        // 1–5: jump straight to a section.
        if (t.length === 1 && t >= "1" && t <= String(root.sections().length)) {
          root.gotoSection(parseInt(t, 10) - 1);
          event.accepted = true;
          return;
        }

        var left = k === Qt.Key_Left || t === "h";
        var right = k === Qt.Key_Right || t === "l";
        var up = (k === Qt.Key_Up && !shift) || t === "k";
        var down = (k === Qt.Key_Down && !shift) || t === "j";

        var handled = true;
        if (sec !== root.listSection) {
          // A button section: arrows / h j k l walk its buttons, the focused
          // button takes ⏎ / space itself, Esc returns to the list.
          if (left || up) root.sectionMove(-1);
          else if (right || down) root.sectionMove(1);
          else if (k === Qt.Key_Escape) root.gotoSection(root.listSection);
          else handled = false;
        } else {
          // The list: ↑↓ j k move the row cursor, ←→ h l switch the type
          // filter, space / ⏎ mark the row.
          if (up) root.moveCursor(-1);
          else if (down) root.moveCursor(1);
          else if (left) root.cycleFilter(-1);
          else if (right) root.cycleFilter(1);
          else if (k === Qt.Key_Space || k === Qt.Key_Return || k === Qt.Key_Enter) root.cursorToggleSel();
          else if (k === Qt.Key_Escape) root.backOut();
          else handled = false;
        }

        if (!handled) {
          handled = true;
          switch (k) {
          case Qt.Key_Down:     root.extendSelection(1); break;     // Shift+↓
          case Qt.Key_Up:       root.extendSelection(-1); break;    // Shift+↑
          case Qt.Key_Delete:   root.cursorDelete(); break;
          case Qt.Key_PageDown: root.moveCursor(10); break;
          case Qt.Key_PageUp:   root.moveCursor(-10); break;
          case Qt.Key_Home:     root.setCursor(0); break;
          case Qt.Key_End:      root.setCursor(listModel.count - 1); break;
          default:              handled = false;
          }
        }

        if (!handled) {
          handled = true;
          if (t === "J") root.extendSelection(1);
          else if (t === "K") root.extendSelection(-1);
          else if (t === "e") root.cursorEdit();
          else if (t === "?") root.helpOpen = true;
          else if (t === "q") root.dismiss();
          else if (t === "g") root.setCursor(0);
          else if (t === "G") root.setCursor(listModel.count - 1);
          else if (t === "/") root.gotoSection(root.searchSection);
          else if (t === "n") rowEditor.openFor(null);
          else if (t === "r") root.refreshStatus(true);
          else if (t === "i") root.installedOnly = !root.installedOnly;
          else if (t === "o") root.cursorOpenLink();
          else if (t === "a") root.cursorRun("add");
          else if (t === "u") root.cursorRun("update");
          else if (t === "U") root.runBulk("update");
          else if (t === "m") root.chooseAurMode();
          else if (t === "d" || t === "x") root.cursorRun("remove");
          else if (t === "A") root.runBulk("add");
          else if (t === "D" || t === "X" || t === "R") root.runBulk("remove");
          else if (t === "c") root.clearSelection();
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
        border.width: 2
        border.color: Color.accent
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

            // nf-md-package_variant_closed (the shell font is a Nerd Font)
            Text {
              id: titleIcon
              anchors.verticalCenter: parent.verticalCenter
              text: "\uDB80\uDFD7"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Math.round(Style.font.iconLarge * 1.6)
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - titleIcon.width - closeBtn.width - Style.space(10) * 2
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

            // Not a section: Esc / q close from anywhere.
            LoadoutButton {
              id: closeBtn
              anchors.verticalCenter: parent.verticalCenter
              // Labelled with the key that does the same thing.
              text: "esc"
              bordered: true
              fontSize: Style.font.caption
              tooltipText: "Close (Esc / q)"
              onClicked: root.dismiss()
            }
          }

          PanelSeparator { width: parent.width }

          // ── Filter bar: 1 search, 2 type filters ─────────────────
          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Section {
              id: secSearch
              number: 1
              Layout.fillWidth: true
              TextField {
                id: searchField
                anchors.fill: parent
                implicitWidth: Style.space(200)
                placeholderText: "Search…  (/)"
                text: root.query
                onTextChanged: root.query = text
                Keys.onPressed: function (e) {
                  // Escape drops back to the list; Tab / Shift+Tab change section
                  // (handled here because a focused TextField consumes the key
                  // before it can reach the panel's key catcher).
                  if (e.key === Qt.Key_Escape) {
                    // First Esc clears the text, second leaves the field.
                    if (searchField.text.length > 0) root.query = "";
                    else root.gotoSection(root.listSection);
                    e.accepted = true;
                  } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter ||
                             e.key === Qt.Key_Down || e.key === Qt.Key_Up) {
                    // Jump into the filtered results, keeping the query.
                    root.setCursor(0);
                    table.forceActiveFocus();
                    e.accepted = true;
                  } else if (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) {
                    root.gotoSection(root.searchSection +
                      ((e.key === Qt.Key_Backtab || (e.modifiers & Qt.ShiftModifier)) ? -1 : 1));
                    e.accepted = true;
                  }
                }
              }
            }

            Section {
              id: secFilter
              number: 2
              Row {
                anchors.fill: parent
                spacing: Style.space(8)

                Repeater {
                  id: filterRep
                  model: root.filterChips
                  delegate: LoadoutButton {
                    required property var modelData
                    text: modelData.label
                    bordered: true
                    focusable: true
                    fontSize: Style.font.caption
                    active: root.filterType === modelData.value
                    onClicked: root.filterType = modelData.value
                  }
                }
                LoadoutButton {
                  id: installedBtn
                  text: "Installed only"
                  bordered: true
                  focusable: true
                  fontSize: Style.font.caption
                  active: root.installedOnly
                  onClicked: root.installedOnly = !root.installedOnly
                }
              }
            }
          }

          // ── Table: 3 ─────────────────────────────────────────────
          Section {
            id: secList
            number: 3
            width: parent.width
            height: parent.height - y - secActions.height - bottomBar.height - parent.spacing * 2
            LoadoutTable {
              id: table
              anchors.fill: parent
              model: listModel
              controller: root
              cursorIndex: root.cursorIndex
            }
          }

          // ── Act on the marked rows: 4 ────────────────────────────
          Section {
            id: secActions
            number: 4
            width: parent.width
            RowLayout {
              anchors.fill: parent
              spacing: Style.space(8)

              LoadoutButton {
                id: selectAllBtn
                text: "Select all"
                bordered: true
                focusable: true
                fontSize: Style.font.caption
                tooltipText: "Ctrl+A"
                onClicked: root.selectAllVisible()
              }
              LoadoutButton {
                id: clearBtn
                text: "Clear"
                bordered: true
                focusable: true
                fontSize: Style.font.caption
                // Stays focusable so section 4's arrows can reach it; dimmed
                // (and a no-op with a hint) until something is marked.
                opacity: root.selectedCount > 0 ? 1 : 0.45
                onClicked: {
                  if (root.selectedCount === 0) root.toast("Nothing marked");
                  else root.clearSelection();
                }
              }
              Item { Layout.fillWidth: true; implicitHeight: 1 }
              LoadoutButton {
                id: addBtn
                text: "Add selected"
                bordered: true
                focusable: true
                accent: Color.accent
                active: root.selectedCount > 0
                opacity: root.bulkReady ? 1 : 0.45
                onClicked: root.runBulk("add")
              }
              LoadoutButton {
                id: updateBtn
                text: "Update AUR"
                bordered: true
                focusable: true
                visible: !root.aurHidden
                tooltipText: "Update the selected, installed AUR rows (U)"
                opacity: root.bulkReady ? 1 : 0.45
                onClicked: root.runBulk("update")
              }
              LoadoutButton {
                id: removeBtn
                text: "Remove selected"
                bordered: true
                focusable: true
                // Destructive — paint it with the theme's urgent colour, and fill
                // it once rows are selected so it clearly reads as "this deletes".
                accent: Color.urgent
                foreground: (root.selectedCount > 0 && !root.anyBusy) ? Color.background : Color.urgent
                background: (root.selectedCount > 0 && !root.anyBusy) ? Color.urgent : "transparent"
                opacity: root.bulkReady ? 1 : 0.45
                onClicked: root.runBulk("remove")
              }
            }
          }

          // ── 5 loadout buttons + keyboard hints ─────────────────────
          RowLayout {
            id: bottomBar
            width: parent.width
            spacing: Style.space(12)

            Section {
              id: secLoadout
              number: 5
              Row {
                anchors.fill: parent
                spacing: Style.space(6)
                LoadoutButton {
                  id: newBtn
                  text: "＋ New"
                  bordered: true
                  fontSize: Style.font.caption
                  tooltipText: "New row (n)"
                  onClicked: rowEditor.openFor(null)
                }
                LoadoutButton {
                  id: refreshBtn
                  iconText: "↻"
                  text: "Refresh"
                  bordered: true
                  fontSize: Style.font.caption
                  iconSize: Style.font.caption
                  iconSpinning: root.scanning
                  tooltipText: "Refresh status (r)"
                  onClicked: root.refreshStatus(true)
                }
                LoadoutButton {
                  id: aurModeBtn
                  text: root.aurModeLabel[root.aurMode]
                  bordered: true
                  fontSize: Style.font.caption
                  active: root.aurMode !== "enabled"
                  tooltipText: "Set AUR mode system-wide: on / updates only / off (m)"
                  onClicked: root.chooseAurMode()
                }
              }
            }

            Text {
              id: footer
              Layout.fillWidth: true
              text: "? all shortcuts · tab / 1–5 section · ←↓↑→ hjkl move · space/⏎ mark or press · " +
                "a/d/u add/remove/update · A/D/U marked · e edit · esc back"
              horizontalAlignment: Text.AlignRight
              color: Util.alpha(Color.foreground, 0.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideLeft
            }
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

      // ── Shortcut sheet (?) ──────────────────────────────────────
      Rectangle {
        anchors.fill: parent
        z: 30
        visible: root.helpOpen
        color: Util.alpha(Color.background, 0.6)
        MouseArea { anchors.fill: parent; onClicked: root.helpOpen = false }

        Rectangle {
          anchors.centerIn: parent
          width: Math.min(760, parent.width * 0.86)
          height: helpCol.implicitHeight + Style.space(36)
          radius: Math.max(8, Style.cornerRadius)
          color: Color.background
          border.width: 1
          border.color: Util.alpha(Color.foreground, 0.16)
          MouseArea { anchors.fill: parent; onClicked: {} }

          Column {
            id: helpCol
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(18) }
            spacing: Style.space(10)

            Text {
              text: "KEYBOARD SHORTCUTS"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.4
            }

            Grid {
              width: parent.width
              columns: 2
              columnSpacing: Style.space(24)
              rowSpacing: Style.space(10)
              Repeater {
                model: [
                  { title: "Sections", keys: [
                    ["Tab  Shift+Tab", "next / previous section"],
                    ["1 – 5", "jump to a section (numbered on screen)"],
                    ["← ↓ ↑ →  h j k l", "move within the section"],
                    ["⏎  space", "press the button · in the list, mark the row"] ] },
                  { title: "Move", keys: [
                    ["j k  ↑ ↓", "row up / down"],
                    ["g G  Home End", "first / last row"],
                    ["Ctrl+D  Ctrl+U", "half page down / up"],
                    ["PgDn PgUp", "ten rows"] ] },
                  { title: "Select", keys: [
                    ["space  ⏎", "mark / unmark the cursor row"],
                    ["J K  Shift+↑↓", "extend selection"],
                    ["Ctrl+A", "select / unselect all shown"],
                    ["c", "clear selection"] ] },
                  { title: "Act", keys: [
                    ["a  d", "add / remove the cursor row"],
                    ["A  D", "add / remove selected"],
                    ["u  U", "update the cursor / selected AUR rows"],
                    ["m", "set AUR mode (system-wide, opens a terminal)"],
                    ["o", "open the row's link"],
                    ["r  Ctrl+R", "refresh status"] ] },
                  { title: "Edit", keys: [
                    ["e  double-click", "edit the cursor row"],
                    ["n", "new row"],
                    ["Delete ×2", "drop row from loadout"],
                    ["in the editor", "Tab / ↑↓ fields, Ctrl+1–5 type, Ctrl+S save"] ] },
                  { title: "Filter", keys: [
                    ["h l  ← →", "previous / next type (in the list)"],
                    ["i", "installed only"],
                    ["/  Ctrl+F", "search (⏎ or ↓ jumps to results)"] ] },
                  { title: "Panel", keys: [
                    ["Esc", "back one step (section → list → close)"],
                    ["q", "close"],
                    ["?", "this sheet"] ] }
                ]
                delegate: Column {
                  required property var modelData
                  width: (helpCol.width - Style.space(24)) / 2
                  spacing: 3
                  Text {
                    text: modelData.title
                    color: Util.alpha(Color.foreground, 0.55)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  Repeater {
                    model: modelData.keys
                    delegate: Row {
                      id: helpRow
                      required property var modelData
                      width: parent.width
                      spacing: Style.space(10)
                      Text {
                        id: helpKey
                        width: Style.space(120)
                        text: modelData[0]
                        color: Color.accent
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                      Text {
                        width: helpRow.width - helpKey.width - helpRow.spacing
                        text: modelData[1]
                        wrapMode: Text.Wrap
                        color: Color.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }
            }

            Text {
              text: "? or Esc to close"
              color: Util.alpha(Color.foreground, 0.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
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

  // Bulk buttons stay enabled (so the keyboard can land on them) and just dim
  // until this is true; runBulk says why when pressed early.
  readonly property bool bulkReady: selectedCount > 0 && !anyBusy
  readonly property bool anyBusy: {
    for (var i = 0; i < rows.length; i++) if (rows[i].busy) return true;
    return false;
  }
}
