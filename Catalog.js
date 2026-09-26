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

// ── target grammar ──────────────────────────────────────────────────────────
//
// Every value that reaches a package / plugin tool must match its backend's
// grammar. Shell quoting stops metacharacters; this stops argument / option
// injection (a ref like `--config=/tmp/x`). None of these grammars admit a
// leading `-`, which matters because only flatpak honours a `--` terminator:
// omarchy-pkg-* forward "$@" to `pacman -Q` too, omarchy plugin add/remove
// reject any `-*` argument, and hyprpm has no terminator at all.

var PKG_RE = /^[a-z0-9@_+][a-z0-9@._+-]{0,127}$/;                 // Arch pkgname
var FLATPAK_RE = /^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*){2,}$/;
var NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;               // plugin id / hyprpm name
var HTTPS_GIT_RE = /^https:\/\/[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?\/[A-Za-z0-9._~\/-]+$/;
var SSH_GIT_RE = /^git@[A-Za-z0-9][A-Za-z0-9.-]*:[A-Za-z0-9._~\/-]+$/;

function isPkgName(s) { return typeof s === "string" && PKG_RE.test(s); }
function isFlatpakId(s) { return typeof s === "string" && s.length <= 255 && FLATPAK_RE.test(s); }
function isPluginName(s) { return typeof s === "string" && NAME_RE.test(s); }
function isGitUrl(s) {
  return typeof s === "string" && s.length <= 512 && (HTTPS_GIT_RE.test(s) || SSH_GIT_RE.test(s));
}

// kind ∈ pkg | flatpak | name | url
function validTarget(kind, value) {
  if (kind === "pkg") return isPkgName(value);
  if (kind === "flatpak") return isFlatpakId(value);
  if (kind === "name") return isPluginName(value);
  if (kind === "url") return isGitUrl(value);
  return false;
}

// Human-readable reason this row cannot be installed / removed, or "" if its
// targets are all well-formed.
function rowTargetError(raw) {
  var r = normalizeRow(raw);
  if (r.type === "pacman" || r.type === "aur") {
    var pkgs = pkgList(r.ref);
    if (!pkgs.length) return "Package name required";
    for (var i = 0; i < pkgs.length; i++)
      if (!isPkgName(pkgs[i])) return "Invalid package name: " + pkgs[i];
    return "";
  }
  if (r.type === "flatpak") {
    var apps = pkgList(r.ref);
    if (!apps.length) return "Flatpak app id required";
    for (var j = 0; j < apps.length; j++)
      if (!isFlatpakId(apps[j])) return "Invalid Flatpak app id: " + apps[j];
    return "";
  }
  // omarchy / hyprland
  if (!r.ref && !r.id) return "Git URL or id required";
  // An omarchy row cloned from a built-in plugin carries that plugin's id as
  // its ref (e.g. "omarchy.bar"); it can be removed / tracked, not added.
  if (r.ref && !isGitUrl(r.ref) && !(r.type === "omarchy" && isPluginName(r.ref)))
    return "Git URL must be https://host/path or git@host:path";
  if (r.id && !isPluginName(r.id)) return "Invalid id: " + r.id;
  if (r.type === "hyprland" && r.ref && !isPluginName(repoNameFromUrl(r.ref)))
    return "Cannot derive a hyprpm repo name from that URL";
  return "";
}

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
  if (TYPES.indexOf(r && r.type) === -1) return false;
  return rowTargetError(r) === "";
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

// Every well-formed target in `rows`; anything else is silently dropped here
// (callers surface the reason via rowTargetError before launching).
function collectPkgs(rows, kind) {
  return uniq(arr(rows).reduce(function (acc, r) { return acc.concat(pkgList(r.ref)); }, [])
    .filter(function (p) { return validTarget(kind || "pkg", p); }));
}

// Absolute tool paths: the command runs in a terminal that inherits the
// user's PATH, so never resolve a privileged tool through it.
var BIN = {
  pkgAdd: "/usr/share/omarchy/bin/omarchy-pkg-add",
  pkgAurAdd: "/usr/share/omarchy/bin/omarchy-pkg-aur-add",
  pkgDrop: "/usr/share/omarchy/bin/omarchy-pkg-drop",
  omarchy: "/usr/share/omarchy/bin/omarchy",
  flatpak: "/usr/bin/flatpak",
  hyprpm: "/usr/bin/hyprpm"
};

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

  // Only rows whose every target is well-formed — buildCommand re-validates
  // because runRow reaches it without going through groupFor*.
  var okRows = function (list) { return arr(list).filter(function (r) { return rowTargetError(r) === ""; }); };
  omarchy = okRows(omarchy);
  hyprland = okRows(hyprland);
  var hyprStages = 0;

  if (action === "add") {
    var pac = collectPkgs(okRows(groups.pacman), "pkg");
    var aur = collectPkgs(okRows(groups.aur), "pkg");
    var fp = collectPkgs(okRows(groups.flatpak), "flatpak");
    if (pac.length) stages.push(BIN.pkgAdd + " " + pac.map(q).join(" "));
    if (aur.length) stages.push(BIN.pkgAurAdd + " " + aur.map(q).join(" "));
    if (fp.length) stages.push(BIN.flatpak + " install -y -- flathub " + fp.map(q).join(" "));
    omarchy.forEach(function (r) {
      if (!isGitUrl(r.ref)) return;             // add needs a URL; an id alone is not installable
      stages.push(BIN.omarchy + " plugin add " + q(r.ref) + " --enable --yes");
    });
    hyprland.forEach(function (r) {
      if (!r.ref) return;
      stages.push(BIN.hyprpm + " add " + q(r.ref));
      if (r.id) stages.push(BIN.hyprpm + " enable " + q(r.id));
      hyprStages++;
    });
  } else {
    var drop = uniq(collectPkgs(okRows(groups.pacman), "pkg").concat(collectPkgs(okRows(groups.aur), "pkg")));
    var fpDrop = collectPkgs(okRows(groups.flatpak), "flatpak");
    if (drop.length) stages.push(BIN.pkgDrop + " " + drop.map(q).join(" "));
    if (fpDrop.length) stages.push(BIN.flatpak + " uninstall -y -- " + fpDrop.map(q).join(" "));
    omarchy.forEach(function (r) {
      stages.push(BIN.omarchy + " plugin remove " + q(r.id || r.ref) + " --yes");
    });
    hyprland.forEach(function (r) {
      var repo = repoNameFromUrl(r.ref) || r.id;
      if (!isPluginName(repo)) return;
      stages.push(BIN.hyprpm + " remove " + q(repo));
      hyprStages++;
    });
  }
  if (hyprStages) stages.push(BIN.hyprpm + " reload -n");

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
    if (!isPluginName(String(p.id))) return;
    if (p.clonedFrom && !isGitUrl(String(p.clonedFrom))) p = { id: p.id, name: p.name, kinds: p.kinds };
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
    if (!e || !isPluginName(e.repo) || haveHypr[e.repo]) return;
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
    if (!isFlatpakId(id) || haveFlatpak[id]) return;
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
    if (!isPkgName(name) || havePkg[name]) return;
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
    validTarget: validTarget,
    rowTargetError: rowTargetError,
    BIN: BIN,
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
