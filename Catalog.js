// Pure logic for the Loadout overlay. Imported from Loadout.qml as
// `import "Catalog.js" as Catalog`, and ES5-only so the same file runs under
// `node tests/catalog.test.js`.
//
// A "row" is one loadout entry the user owns:
//   { name, description, type, ref, id, link }
// type ∈ { pacman, aur, flatpak, omarchy, hyprland }
//   pacman / aur    : ref = one or more package names, space separated
//   flatpak         : ref = one or more Flatpak application ids, space separated
//   omarchy         : ref = git URL ; id = plugin manifest id (discovered post-install)
//   hyprland        : ref = git URL ; id = hyprpm *plugin* name (for enable + status).
//                     The hyprpm *repo* name used by `hyprpm remove` is the URL basename.
//
// Reconcile adds transient fields (installed, enabled) that are never persisted.

var TYPES = ["pacman", "aur", "flatpak", "omarchy", "hyprland"];
var PACKAGE_TYPES = ["pacman", "aur", "flatpak"];

function isUrl(s) {
  return /^(https?:\/\/|git@|git:\/\/|ssh:\/\/)/.test(String(s || "").trim());
}

// Last path segment of a git URL, minus a trailing .git — this is the directory
// hyprpm clones into and the name `hyprpm remove` expects.
function repoNameFromUrl(url) {
  var s = String(url || "").trim()
    .replace(/[#?].*$/, "")      // strip fragment / query
    .replace(/\.git$/i, "")
    .replace(/\/+$/, "");        // strip trailing slashes
  var cut = Math.max(s.lastIndexOf("/"), s.lastIndexOf(":"));
  return (cut >= 0 ? s.slice(cut + 1) : s).trim();
}

function pkgList(ref) {
  return String(ref || "").trim().split(/\s+/).filter(function (p) { return p.length > 0; });
}

function uniq(arr) {
  var seen = {};
  var out = [];
  for (var i = 0; i < arr.length; i++) {
    if (!seen[arr[i]]) { seen[arr[i]] = true; out.push(arr[i]); }
  }
  return out;
}

function arr(v) { return Array.isArray(v) ? v : []; }

// ── normalize ────────────────────────────────────────────────────────────────

function normalizeRow(raw) {
  raw = raw && typeof raw === "object" ? raw : {};

  var type = String(raw.type || "pacman").toLowerCase().trim();
  if (TYPES.indexOf(type) === -1) type = "pacman";

  var ref = String(raw.ref || "").trim();
  var id = String(raw.id || "").trim();
  var description = String(raw.description || "").trim();
  var name = String(raw.name || "").trim() || ref || id || "(unnamed)";

  var link = String(raw.link || "").trim();
  if (!link && isUrl(ref)) link = ref;

  return { name: name, description: description, type: type, ref: ref, id: id, link: link };
}

function normalizeCatalog(rows) {
  return arr(rows).map(normalizeRow);
}

// Identity for de-duping a user row against a default row.
function catalogKey(row) {
  var r = normalizeRow(row);
  var handle = (r.ref || r.id || r.name).toLowerCase();
  return r.type + "\u0000" + handle;
}

// User rows win; append any default rows the user does not already have.
function mergeCatalog(userRows, defaultRows) {
  var out = [];
  var seen = {};
  arr(userRows).forEach(function (raw) {
    var r = normalizeRow(raw);
    out.push(r);
    seen[catalogKey(r)] = true;
  });
  arr(defaultRows).forEach(function (raw) {
    var r = normalizeRow(raw);
    var k = catalogKey(r);
    if (!seen[k]) { out.push(r); seen[k] = true; }
  });
  return out;
}

// ── status reconciliation ───────────────────────────────────────────────────
//
// status = {
//   explicit: [pkg…],            // pacman -Qqe
//   foreign:  [pkg…],            // pacman -Qqm
//   flatpak:  [app-id…],         // flatpak list --app --columns=application
//   plugins:  [ {id, enabled, firstParty, clonedFrom, …} … ],  // omarchy plugin list --json
//   hyprpm:   [ {repo, plugins:[{name, enabled}]} … ]
// }
//
// Returns a NEW array of rows with `installed` / `enabled` set. For an omarchy
// row whose `id` was still unknown, a match on `clonedFrom === ref` backfills
// `id` so the caller can persist it.

function reconcile(rows, status) {
  status = status || {};
  var pkgSet = {};
  arr(status.explicit).concat(arr(status.foreign)).forEach(function (p) { pkgSet[p] = true; });
  var flatpakSet = {};
  arr(status.flatpak).forEach(function (a) { flatpakSet[a] = true; });

  var pluginById = {};
  var pluginByClone = {};
  arr(status.plugins).forEach(function (p) {
    if (!p) return;
    if (p.id) pluginById[String(p.id)] = p;
    if (p.clonedFrom) pluginByClone[String(p.clonedFrom)] = p;
  });

  var hyprByRepo = {};
  var hyprPluginByName = {};
  arr(status.hyprpm).forEach(function (entry) {
    if (!entry) return;
    if (entry.repo) hyprByRepo[String(entry.repo)] = entry;
    arr(entry.plugins).forEach(function (pl) {
      if (pl && pl.name) hyprPluginByName[String(pl.name)] = pl;
    });
  });

  return arr(rows).map(function (raw) {
    var r = normalizeRow(raw);

    if (r.type === "pacman" || r.type === "aur") {
      var pkgs = pkgList(r.ref);
      r.installed = pkgs.length > 0 && pkgs.every(function (p) { return pkgSet[p] === true; });
      r.enabled = r.installed;
    } else if (r.type === "flatpak") {
      var apps = pkgList(r.ref);
      r.installed = apps.length > 0 && apps.every(function (a) { return flatpakSet[a] === true; });
      r.enabled = r.installed;
    } else if (r.type === "omarchy") {
      var p = (r.id && pluginById[r.id]) || (r.ref && pluginByClone[r.ref]) || null;
      if (p && !r.id && p.id) r.id = String(p.id);
      r.installed = !!p;
      r.enabled = !!(p && p.enabled);
    } else if (r.type === "hyprland") {
      var repo = repoNameFromUrl(r.ref) || r.id;
      var entry = hyprByRepo[repo] || null;
      var pluginMatch = (r.id && hyprPluginByName[r.id]) || null;
      r.installed = !!entry || !!pluginMatch;
      if (entry) {
        r.enabled = arr(entry.plugins).some(function (pl) { return pl && pl.enabled; });
      } else {
        r.enabled = !!(pluginMatch && pluginMatch.enabled);
      }
    } else {
      r.installed = false;
      r.enabled = false;
    }
    return r;
  });
}

// ── filtering ───────────────────────────────────────────────────────────────

function matchesFilter(row, opts) {
  opts = opts || {};
  var type = opts.type && opts.type !== "all" ? opts.type : null;
  if (type && row.type !== type) return false;
  if (opts.installedOnly && !row.installed) return false;

  var q = String(opts.query || "").toLowerCase().trim();
  if (q) {
    var hay = [row.name, row.description, row.ref, row.id, row.type].join(" ").toLowerCase();
    if (hay.indexOf(q) === -1) return false;
  }
  return true;
}

function filterRows(rows, opts) {
  return arr(rows).filter(function (r) { return matchesFilter(r, opts); });
}

// ── grouping + command building ─────────────────────────────────────────────

function hasTarget(r) {
  if (r.type === "pacman" || r.type === "aur" || r.type === "flatpak") return pkgList(r.ref).length > 0;
  if (r.type === "omarchy") return !!(r.ref || r.id);
  if (r.type === "hyprland") return !!(r.ref || r.id);
  return false;
}

function groupByType(rows) {
  var g = { pacman: [], aur: [], flatpak: [], omarchy: [], hyprland: [] };
  arr(rows).forEach(function (r) { if (g[r.type]) g[r.type].push(r); });
  return g;
}

function groupForInstall(rows) {
  return groupByType(arr(rows).filter(function (r) { return !r.installed && hasTarget(r); }));
}

function groupForRemove(rows) {
  return groupByType(arr(rows).filter(function (r) { return r.installed && hasTarget(r); }));
}

function shq(value) {
  return "'" + String(value == null ? "" : value).replace(/'/g, "'\\''") + "'";
}

function collectPkgs(rows) {
  return uniq(arr(rows).reduce(function (acc, r) { return acc.concat(pkgList(r.ref)); }, []));
}

// Join every stage for `groups` into ONE shell string (stages chained with
// ` && `). `quoteFn` defaults to POSIX single-quoting; the QML side passes
// Util.shellQuote. A single `hyprpm reload -n` is appended once if any hyprland
// stage was emitted.
function buildCommand(groups, action, quoteFn) {
  var q = typeof quoteFn === "function" ? quoteFn : shq;
  groups = groups || {};
  var omarchy = arr(groups.omarchy);
  var hyprland = arr(groups.hyprland);
  var stages = [];

  if (action === "add") {
    var pac = collectPkgs(groups.pacman);
    var aur = collectPkgs(groups.aur);
    var fp = collectPkgs(groups.flatpak);
    if (pac.length) stages.push("omarchy-pkg-add " + pac.map(q).join(" "));
    if (aur.length) stages.push("omarchy-pkg-aur-add " + aur.map(q).join(" "));
    if (fp.length) stages.push("flatpak install -y flathub " + fp.map(q).join(" "));
    omarchy.forEach(function (r) {
      stages.push("omarchy plugin add " + q(r.ref) + " --enable --yes");
    });
    hyprland.forEach(function (r) {
      stages.push("hyprpm add " + q(r.ref));
      if (r.id) stages.push("hyprpm enable " + q(r.id));
    });
    if (hyprland.length) stages.push("hyprpm reload -n");
  } else {
    var drop = uniq(collectPkgs(groups.pacman).concat(collectPkgs(groups.aur)));
    var fpDrop = collectPkgs(groups.flatpak);
    if (drop.length) stages.push("omarchy-pkg-drop " + drop.map(q).join(" "));
    if (fpDrop.length) stages.push("flatpak uninstall -y " + fpDrop.map(q).join(" "));
    omarchy.forEach(function (r) {
      stages.push("omarchy plugin remove " + q(r.id || r.ref) + " --yes");
    });
    hyprland.forEach(function (r) {
      stages.push("hyprpm remove " + q(repoNameFromUrl(r.ref) || r.id));
    });
    if (hyprland.length) stages.push("hyprpm reload -n");
  }

  return stages.join(" && ");
}

// Convenience for a single row's Add / Remove button.
function commandForRow(row, action, quoteFn) {
  return buildCommand(groupByType([normalizeRow(row)]), action, quoteFn);
}

// Does this bulk job need root (pacman / flatpak / hyprpm)? An omarchy-only job
// does not, so the caller can run it inline for live per-row status instead.
function needsTerminal(groups) {
  groups = groups || {};
  return arr(groups.pacman).length > 0 ||
    arr(groups.aur).length > 0 ||
    arr(groups.flatpak).length > 0 ||
    arr(groups.hyprland).length > 0;
}

// A Flatpak application id ("org.gnome.Calculator") shortened to its last
// dotted segment for a display name, or the whole id when there is no dot.
function flatpakName(appId) {
  var s = String(appId || "").trim();
  var dot = s.lastIndexOf(".");
  return dot >= 0 && dot < s.length - 1 ? s.slice(dot + 1) : s;
}

// Append rows for things that are installed but not yet in the loadout, so the
// table is a real inventory. Imported: third-party Omarchy shell plugins, every
// hyprpm repo, every installed Flatpak app, and every explicitly-installed
// pacman/AUR package that ships a desktop launcher (`status.apps` — the GUI
// apps, e.g. libreoffice, mpv, the browser). NOT imported: the rest of
// `pacman -Qqe` (libraries, toolchains, base system). Matched by
// id / ref / repo / app-id / package, so it is idempotent across refreshes.
function importInstalled(rows, status) {
  status = status || {};
  var out = arr(rows).map(normalizeRow);

  var haveOmId = {}, haveOmRef = {}, haveHypr = {}, haveFlatpak = {}, havePkg = {};
  out.forEach(function (r) {
    if (r.type === "omarchy") {
      if (r.id) haveOmId[r.id] = true;
      if (r.ref) haveOmRef[r.ref] = true;
    } else if (r.type === "hyprland") {
      var rp = repoNameFromUrl(r.ref) || r.id;
      if (rp) haveHypr[rp] = true;
    } else if (r.type === "flatpak") {
      pkgList(r.ref).forEach(function (a) { haveFlatpak[a] = true; });
    } else if (r.type === "pacman" || r.type === "aur") {
      pkgList(r.ref).forEach(function (p) { havePkg[p] = true; });
    }
  });

  var foreignSet = {};
  arr(status.foreign).forEach(function (p) { foreignSet[p] = true; });

  arr(status.plugins).forEach(function (p) {
    if (!p || !p.id || p.firstParty === true) return;   // skip Omarchy's bundled plugins
    if (haveOmId[p.id]) return;
    if (p.clonedFrom && haveOmRef[p.clonedFrom]) return;
    var kinds = p.kinds ? [].concat(p.kinds).join("/") : "";
    out.push(normalizeRow({
      name: p.name || p.id,
      description: kinds ? ("Omarchy " + kinds + " plugin") : "Omarchy plugin",
      type: "omarchy",
      ref: p.clonedFrom || "",
      id: p.id,
      link: p.clonedFrom || ""
    }));
    haveOmId[p.id] = true;
  });

  arr(status.hyprpm).forEach(function (e) {
    if (!e || !e.repo || haveHypr[e.repo]) return;
    out.push(normalizeRow({
      name: e.repo,
      description: "Hyprland plugin",
      type: "hyprland",
      ref: "",
      id: e.repo,               // repo name — what `hyprpm remove` needs
      link: ""
    }));
    haveHypr[e.repo] = true;
  });

  arr(status.flatpak).forEach(function (appId) {
    var id = String(appId || "").trim();
    if (!id || haveFlatpak[id]) return;
    out.push(normalizeRow({
      name: flatpakName(id),
      description: "Flatpak app",
      type: "flatpak",
      ref: id,
      id: "",
      link: "https://flathub.org/apps/" + id
    }));
    haveFlatpak[id] = true;
  });

  arr(status.apps).forEach(function (pkg) {
    var name = String(pkg || "").trim();
    if (!name || havePkg[name]) return;
    out.push(normalizeRow({
      name: name,
      description: "Installed app",
      type: foreignSet[name] ? "aur" : "pacman",
      ref: name,
      id: "",
      link: ""
    }));
    havePkg[name] = true;
  });

  return out;
}

if (typeof module !== "undefined") {
  module.exports = {
    TYPES: TYPES,
    PACKAGE_TYPES: PACKAGE_TYPES,
    isUrl: isUrl,
    repoNameFromUrl: repoNameFromUrl,
    flatpakName: flatpakName,
    pkgList: pkgList,
    normalizeRow: normalizeRow,
    normalizeCatalog: normalizeCatalog,
    catalogKey: catalogKey,
    mergeCatalog: mergeCatalog,
    reconcile: reconcile,
    importInstalled: importInstalled,
    matchesFilter: matchesFilter,
    filterRows: filterRows,
    hasTarget: hasTarget,
    groupByType: groupByType,
    groupForInstall: groupForInstall,
    groupForRemove: groupForRemove,
    buildCommand: buildCommand,
    commandForRow: commandForRow,
    needsTerminal: needsTerminal,
    shq: shq
  };
}
