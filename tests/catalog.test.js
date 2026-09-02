// Run: node tests/catalog.test.js
const C = require("../Catalog.js");

let failed = 0;
function ok(name, cond) {
  console.log((cond ? "PASS " : "FAIL ") + name);
  if (!cond) failed++;
}
function eq(name, a, b) { ok(name + "  (" + JSON.stringify(a) + " === " + JSON.stringify(b) + ")", a === b); }

// ── repoNameFromUrl ─────────────────────────────────────────────────────────
eq("repo from https .git", C.repoNameFromUrl("https://github.com/yayuuu/hyprland-scroll-overview.git"), "hyprland-scroll-overview");
eq("repo from https no .git", C.repoNameFromUrl("https://github.com/foo/bar"), "bar");
eq("repo from trailing slash", C.repoNameFromUrl("https://github.com/foo/bar/"), "bar");
eq("repo from ssh", C.repoNameFromUrl("git@github.com:foo/baz.git"), "baz");
eq("repo strips fragment", C.repoNameFromUrl("https://github.com/foo/bar#main"), "bar");

// ── pkgList ─────────────────────────────────────────────────────────────────
eq("pkgList splits", C.pkgList("  a   b\tc ").join(","), "a,b,c");
eq("pkgList empty", C.pkgList("").length, 0);

// ── normalizeRow ────────────────────────────────────────────────────────────
const n1 = C.normalizeRow({ ref: "cowsay" });
eq("normalize defaults type", n1.type, "pacman");
eq("normalize name falls back to ref", n1.name, "cowsay");
const n2 = C.normalizeRow({ type: "OMARCHY", ref: "https://x/y.git", name: "Y" });
eq("normalize lowercases type", n2.type, "omarchy");
eq("normalize derives link from url ref", n2.link, "https://x/y.git");
const n3 = C.normalizeRow({ type: "bogus", ref: "z" });
eq("normalize unknown type -> pacman", n3.type, "pacman");

// ── mergeCatalog ────────────────────────────────────────────────────────────
const user = [{ name: "Mine", type: "pacman", ref: "ripgrep", description: "edited" }];
const defs = [
  { name: "Ripgrep", type: "pacman", ref: "ripgrep", description: "SHOULD NOT CLOBBER" },
  { name: "Bat", type: "pacman", ref: "bat" },
  { name: "Plug", type: "omarchy", ref: "https://h/p.git" }
];
const merged = C.mergeCatalog(user, defs);
eq("merge length", merged.length, 3);
eq("merge keeps user row first", merged[0].name, "Mine");
eq("merge does not clobber user description", merged[0].description, "edited");
eq("merge appends new default (bat)", merged[1].ref, "bat");
eq("merge appends new default (omarchy)", merged[2].type, "omarchy");
eq("merge is idempotent", C.mergeCatalog(merged, defs).length, 3);

// ── reconcile ───────────────────────────────────────────────────────────────
const rows = [
  { name: "rg", type: "pacman", ref: "ripgrep" },
  { name: "multi", type: "pacman", ref: "foo bar" },
  { name: "aurthing", type: "aur", ref: "yay" },
  { name: "nc", type: "omarchy", ref: "https://x/nc.git" },              // id discovered via clonedFrom
  { name: "known", type: "omarchy", ref: "https://x/k.git", id: "vendor.known" },
  { name: "scroll", type: "hyprland", ref: "https://github.com/yayuuu/hyprland-scroll-overview.git", id: "scrolloverview" }
];
const status = {
  explicit: ["ripgrep", "foo"],
  foreign: ["yay"],
  plugins: [
    { id: "vendor.known", enabled: false, clonedFrom: "https://x/k.git" },
    { id: "auto.nc", enabled: true, clonedFrom: "https://x/nc.git" }
  ],
  hyprpm: [
    { repo: "hyprland-scroll-overview", plugins: [{ name: "scrolloverview", enabled: true }] }
  ]
};
const rec = C.reconcile(rows, status);
eq("reconcile pacman installed", rec[0].installed, true);
eq("reconcile pacman partial -> not installed", rec[1].installed, false);
eq("reconcile aur via foreign list", rec[2].installed, true);
eq("reconcile omarchy matched by clonedFrom", rec[3].installed, true);
eq("reconcile backfills omarchy id", rec[3].id, "auto.nc");
eq("reconcile omarchy enabled passthrough", rec[3].enabled, true);
eq("reconcile omarchy known not enabled", rec[4].enabled, false);
eq("reconcile hyprland installed by repo", rec[5].installed, true);
eq("reconcile hyprland enabled", rec[5].enabled, true);
eq("reconcile does not mutate input", rows[3].id || "", "");

// ── filterRows ──────────────────────────────────────────────────────────────
eq("filter by type", C.filterRows(rec, { type: "pacman" }).length, 2);
// installed: rg, aurthing, nc, known (disabled but present), scroll = 5
eq("filter installed only", C.filterRows(rec, { installedOnly: true }).length, 5);
eq("filter query hits description/name/ref", C.filterRows(rec, { query: "scroll" }).length, 1);
eq("filter all", C.filterRows(rec, { type: "all" }).length, 6);

// ── grouping ────────────────────────────────────────────────────────────────
const gi = C.groupForInstall(rec);
eq("groupForInstall skips already-installed pacman", gi.pacman.length, 1);   // only "multi"
eq("groupForInstall keeps known omarchy (disabled counts as installed=true -> skipped)", gi.omarchy.length, 0);
const gr = C.groupForRemove(rec);
eq("groupForRemove pacman", gr.pacman.length, 1);       // "rg"
eq("groupForRemove aur", gr.aur.length, 1);
eq("groupForRemove hyprland", gr.hyprland.length, 1);

// ── buildCommand ────────────────────────────────────────────────────────────
const addOne = C.buildCommand(C.groupByType([{ type: "pacman", ref: "cowsay lolcat" }]), "add");
eq("add pacman single stage", addOne, "omarchy-pkg-add 'cowsay' 'lolcat'");

const rmMixed = C.buildCommand(C.groupByType([
  { type: "pacman", ref: "cowsay" },
  { type: "aur", ref: "yay" },
  { type: "omarchy", ref: "https://x/nc.git", id: "auto.nc" },
  { type: "hyprland", ref: "https://github.com/yayuuu/hyprland-scroll-overview.git", id: "scrolloverview" }
]), "remove");
ok("remove drops pacman+aur together: " + rmMixed, rmMixed.indexOf("omarchy-pkg-drop 'cowsay' 'yay'") === 0);
ok("remove omarchy by id", rmMixed.indexOf("omarchy plugin remove 'auto.nc' --yes") !== -1);
ok("remove hyprland by repo name (not id)", rmMixed.indexOf("hyprpm remove 'hyprland-scroll-overview'") !== -1);
eq("remove appends exactly one hyprpm reload", rmMixed.split("hyprpm reload -n").length - 1, 1);
ok("remove stages chained with &&", rmMixed.indexOf(" && ") !== -1);

const addMixed = C.buildCommand(C.groupByType([
  { type: "pacman", ref: "a" },
  { type: "hyprland", ref: "https://h/one.git", id: "onep" },
  { type: "hyprland", ref: "https://h/two.git" }
]), "add");
eq("add hyprland reload appended once for two repos", addMixed.split("hyprpm reload -n").length - 1, 1);
ok("add hyprland enable only when id present", addMixed.indexOf("hyprpm enable 'onep'") !== -1);
ok("add hyprland second repo has no enable", addMixed.indexOf("hyprpm add 'https://h/two.git' && hyprpm reload") !== -1);

eq("buildCommand empty groups -> empty string", C.buildCommand({}, "add"), "");

// custom quote fn is used
const q = (s) => '"' + s + '"';
eq("buildCommand honors injected quote fn", C.buildCommand(C.groupByType([{ type: "pacman", ref: "x" }]), "add", q), 'omarchy-pkg-add "x"');

// ── needsTerminal ───────────────────────────────────────────────────────────
eq("needsTerminal true for pacman", C.needsTerminal(C.groupByType([{ type: "pacman", ref: "x" }])), true);
eq("needsTerminal false for omarchy-only", C.needsTerminal(C.groupByType([{ type: "omarchy", ref: "https://x/y.git" }])), false);
eq("needsTerminal true for hyprland", C.needsTerminal(C.groupByType([{ type: "hyprland", ref: "https://x/y.git" }])), true);
eq("needsTerminal true for flatpak", C.needsTerminal(C.groupByType([{ type: "flatpak", ref: "org.x.Y" }])), true);

// ── flatpak type ───────────────────────────────────────────────────────────
const fpRows = [
  { name: "GeForce NOW", type: "flatpak", ref: "com.nvidia.geforcenow" },
  { name: "two", type: "flatpak", ref: "org.a.A org.b.B" }
];
const fpRec = C.reconcile(fpRows, { flatpak: ["com.nvidia.geforcenow", "org.a.A"] });
eq("flatpak installed when id present", fpRec[0].installed, true);
eq("flatpak not installed when one id missing", fpRec[1].installed, false);
eq("flatpak add command", C.buildCommand(C.groupByType([fpRows[0]]), "add"),
  "flatpak install -y flathub 'com.nvidia.geforcenow'");
eq("flatpak remove command", C.buildCommand(C.groupByType([fpRows[0]]), "remove"),
  "flatpak uninstall -y 'com.nvidia.geforcenow'");
const fpMixed = C.buildCommand(C.groupByType([
  { type: "pacman", ref: "p" }, { type: "flatpak", ref: "org.x.Y" }
]), "add");
ok("flatpak stage after pacman: " + fpMixed,
  fpMixed === "omarchy-pkg-add 'p' && flatpak install -y flathub 'org.x.Y'");
eq("flatpak filter", C.filterRows(fpRec, { type: "flatpak" }).length, 2);

// ── flatpakName ───────────────────────────────────────────────────────────
eq("flatpakName last segment", C.flatpakName("io.missioncenter.MissionCenter"), "MissionCenter");
eq("flatpakName another", C.flatpakName("io.github.diegopvlk.Cine"), "Cine");
eq("flatpakName no dot", C.flatpakName("Whatever"), "Whatever");
eq("flatpakName trailing dot", C.flatpakName("a.b."), "a.b.");

// ── importInstalled ────────────────────────────────────────────────────────
const impStatus = {
  plugins: [
    { id: "omarchy.bar", enabled: true, firstParty: true },              // skip: bundled
    { id: "vendor.known", enabled: true, clonedFrom: "https://x/k.git", firstParty: false },
    { id: "third.party-a", name: "Third Party A", kinds: ["bar-widget"], enabled: false, clonedFrom: "https://z/a.git", firstParty: false },
    { id: "third.party-b", name: "Third Party B", enabled: true, firstParty: false }
  ],
  hyprpm: [
    { repo: "hyprland-scroll-overview", plugins: [{ name: "scrolloverview", enabled: true }] },
    { repo: "some-other-hypr", plugins: [{ name: "sohp", enabled: false }] }
  ],
  flatpak: ["io.missioncenter.MissionCenter", "io.github.diegopvlk.Cine", "org.gnome.Calculator"],
  apps: ["libreoffice-fresh", "mpv", "yay", "btop"],   // btop already catalogued below
  foreign: ["yay"]
};
const impBase = [
  { name: "known", type: "omarchy", ref: "https://x/k.git", id: "vendor.known" },
  { name: "scroll", type: "hyprland", ref: "https://github.com/yayuuu/hyprland-scroll-overview.git", id: "scrolloverview" },
  { name: "Mission Center", type: "flatpak", ref: "io.missioncenter.MissionCenter" },  // already catalogued
  { name: "btop", type: "pacman", ref: "btop" }                                        // already catalogued
];
const imp = C.importInstalled(impBase, impStatus);
// base 4 + third.party-a + third.party-b + some-other-hypr + Cine + Calculator + libreoffice-fresh + mpv + yay = 12
eq("importInstalled adds the new installed items", imp.length, 12);
ok("imported third-party omarchy by id", imp.some(r => r.type === "omarchy" && r.id === "third.party-a"));
ok("imported bare third-party (no clonedFrom)", imp.some(r => r.id === "third.party-b"));
ok("did NOT import first-party omarchy.bar", !imp.some(r => r.id === "omarchy.bar"));
ok("did NOT duplicate vendor.known", imp.filter(r => r.id === "vendor.known").length === 1);
ok("imported new hyprpm repo with repo name as id", imp.some(r => r.type === "hyprland" && r.id === "some-other-hypr"));
ok("did NOT duplicate the scroll-overview repo", imp.filter(r => r.type === "hyprland").length === 2);
ok("imported flatpak Cine with derived name", imp.some(r => r.type === "flatpak" && r.name === "Cine" && r.ref === "io.github.diegopvlk.Cine"));
ok("imported flatpak Calculator", imp.some(r => r.type === "flatpak" && r.ref === "org.gnome.Calculator"));
ok("imported flatpak gets a flathub link", imp.find(r => r.ref === "org.gnome.Calculator").link === "https://flathub.org/apps/org.gnome.Calculator");
ok("did NOT duplicate the already-catalogued Mission Center flatpak", imp.filter(r => r.type === "flatpak").length === 3);
ok("imported GUI app libreoffice-fresh as a pacman row", imp.some(r => r.type === "pacman" && r.ref === "libreoffice-fresh"));
ok("imported GUI app mpv", imp.some(r => r.type === "pacman" && r.ref === "mpv"));
ok("imported foreign GUI app yay as type aur", imp.some(r => r.type === "aur" && r.ref === "yay"));
ok("did NOT re-import already-catalogued btop", imp.filter(r => r.ref === "btop").length === 1);
ok("imported app row is name=ref", imp.find(r => r.ref === "mpv").name === "mpv");
eq("importInstalled is idempotent", C.importInstalled(imp, impStatus).length, 12);
// a catalogued flatpak row carrying several ids covers all of them
const multiFp = C.importInstalled(
  [{ name: "combo", type: "flatpak", ref: "io.missioncenter.MissionCenter io.github.diegopvlk.Cine" }],
  { flatpak: ["io.missioncenter.MissionCenter", "io.github.diegopvlk.Cine", "org.gnome.Calculator"] });
eq("multi-id flatpak row only pulls in the missing one", multiFp.length, 2);

// ── refresh pipeline ───────────────────────────────────────────────────────
// The overlay's "refresh" (the r key / ↻ button) re-runs bin/loadout-status and
// then does: rows = reconcile(importInstalled(rows, status), status). These
// tests pin that behaviour: a fresh status must be reflected each time.
function refresh(rows, status) {
  return C.reconcile(C.importInstalled(rows, status), status);
}

const base = [
  { name: "cowsay", type: "pacman", ref: "cowsay" },
  { name: "GFN", type: "flatpak", ref: "com.nvidia.geforcenow" },
  { name: "nc", type: "omarchy", ref: "https://x/nc.git", id: "vendor.nc" }
];

// 1. nothing installed yet
let r0 = refresh(base, { explicit: [], foreign: [], flatpak: [], plugins: [], hyprpm: [] });
eq("refresh: all not-installed initially", r0.filter(x => x.installed).length, 0);

// 2. user installs cowsay + the flatpak + enables the plugin → refresh picks it up
let r1 = refresh(r0, {
  explicit: ["cowsay"], foreign: [], flatpak: ["com.nvidia.geforcenow"],
  plugins: [{ id: "vendor.nc", enabled: true, clonedFrom: "https://x/nc.git", firstParty: false }],
  hyprpm: []
});
eq("refresh: cowsay now installed", r1.find(x => x.name === "cowsay").installed, true);
eq("refresh: flatpak now installed", r1.find(x => x.name === "GFN").installed, true);
eq("refresh: omarchy plugin now installed+enabled", r1.find(x => x.name === "nc").enabled, true);

// 3. user removes cowsay and disables the plugin → next refresh flips them back
let r2 = refresh(r1, {
  explicit: [], foreign: [], flatpak: ["com.nvidia.geforcenow"],
  plugins: [{ id: "vendor.nc", enabled: false, clonedFrom: "https://x/nc.git", firstParty: false }],
  hyprpm: []
});
eq("refresh: cowsay uninstalled again", r2.find(x => x.name === "cowsay").installed, false);
eq("refresh: flatpak still installed", r2.find(x => x.name === "GFN").installed, true);
eq("refresh: plugin still present but disabled", r2.find(x => x.name === "nc").installed, true);
eq("refresh: plugin now not enabled", r2.find(x => x.name === "nc").enabled, false);

// 4. a plugin the user removed entirely (gone from status) stays as a row, off
eq("refresh: removed-from-system plugin row survives", r2.length, r1.length);
let r3 = refresh(r2, { explicit: [], foreign: [], flatpak: [], plugins: [], hyprpm: [] });
eq("refresh: row count stable when nothing installed", r3.length, base.length);
eq("refresh: everything reads not-installed", r3.filter(x => x.installed).length, 0);

// 5. idempotent — refreshing twice on the same status changes nothing
const S = { explicit: ["cowsay"], foreign: [], flatpak: [], plugins: [], hyprpm: [] };
eq("refresh: idempotent length", refresh(refresh(base, S), S).length, refresh(base, S).length);
eq("refresh: idempotent installed set",
  JSON.stringify(refresh(refresh(base, S), S).map(x => x.installed)),
  JSON.stringify(refresh(base, S).map(x => x.installed)));

// 6. a refresh that discovers a new third-party plugin grows the catalog once
let g0 = refresh(base, { explicit: [], foreign: [], flatpak: [], plugins: [], hyprpm: [] });
let g1 = refresh(g0, {
  explicit: [], foreign: [], flatpak: [],
  plugins: [{ id: "new.thing", name: "New Thing", enabled: true, clonedFrom: "https://z/n.git", firstParty: false }],
  hyprpm: []
});
eq("refresh: new plugin imported once", g1.length, g0.length + 1);
eq("refresh: re-refresh does not re-import it", refresh(g1, {
  plugins: [{ id: "new.thing", name: "New Thing", enabled: true, clonedFrom: "https://z/n.git", firstParty: false }]
}).length, g1.length);

console.log(failed === 0 ? "\nALL PASS" : "\n" + failed + " FAILED");
process.exit(failed === 0 ? 0 : 1);
