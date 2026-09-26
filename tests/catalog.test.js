// Run: node tests/catalog.test.js
const C = require("../Catalog.js");
const B = C.BIN;

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
eq("add pacman single stage", addOne, B.pkgAdd + " 'cowsay' 'lolcat'");

const rmMixed = C.buildCommand(C.groupByType([
  { type: "pacman", ref: "cowsay" },
  { type: "aur", ref: "yay" },
  { type: "omarchy", ref: "https://x/nc.git", id: "auto.nc" },
  { type: "hyprland", ref: "https://github.com/yayuuu/hyprland-scroll-overview.git", id: "scrolloverview" }
]), "remove");
ok("remove drops pacman+aur together: " + rmMixed, rmMixed.indexOf(B.pkgDrop + " 'cowsay' 'yay'") === 0);
ok("remove omarchy by id", rmMixed.indexOf(B.omarchy + " plugin remove 'auto.nc' --yes") !== -1);
ok("remove hyprland by repo name (not id)", rmMixed.indexOf(B.hyprpm + " remove 'hyprland-scroll-overview'") !== -1);
eq("remove appends exactly one hyprpm reload", rmMixed.split("hyprpm reload -n").length - 1, 1);
ok("remove stages chained with &&", rmMixed.indexOf(" && ") !== -1);

const addMixed = C.buildCommand(C.groupByType([
  { type: "pacman", ref: "a" },
  { type: "hyprland", ref: "https://h/one.git", id: "onep" },
  { type: "hyprland", ref: "https://h/two.git" }
]), "add");
eq("add hyprland reload appended once for two repos", addMixed.split("hyprpm reload -n").length - 1, 1);
ok("add hyprland enable only when id present", addMixed.indexOf(B.hyprpm + " enable 'onep'") !== -1);
ok("add hyprland second repo has no enable", addMixed.indexOf(B.hyprpm + " add 'https://h/two.git' && " + B.hyprpm + " reload") !== -1);

eq("buildCommand empty groups -> empty string", C.buildCommand({}, "add"), "");

// custom quote fn is used
const q = (s) => '"' + s + '"';
eq("buildCommand honors injected quote fn", C.buildCommand(C.groupByType([{ type: "pacman", ref: "x" }]), "add", q), B.pkgAdd + ' "x"');


// ── target grammar (argument / option injection) ─────────────────────────────
const V = C.validTarget;
["-x", "--config=/tmp/x", ".hidden", "", "a b", "a;b", "$(id)", "Foo", "x".repeat(200)].forEach(v =>
  eq("pkg rejects " + JSON.stringify(v).slice(0, 30), V("pkg", v), false));
["btop", "ripgrep", "libreoffice-fresh", "lib32-glibc", "gtk+", "python3.12", "@scope"].forEach(v =>
  eq("pkg accepts " + v, V("pkg", v), true));
["-org.x.Y", "--user", "org.x", "org..x.Y", "org.x.Y;", "1org.x.Y"].forEach(v =>
  eq("flatpak rejects " + v, V("flatpak", v), false));
["io.missioncenter.MissionCenter", "com.nvidia.geforcenow", "org.gnome.Calculator"].forEach(v =>
  eq("flatpak accepts " + v, V("flatpak", v), true));
["-rf", "--help", ".x", "a/b", "a b", ""].forEach(v =>
  eq("name rejects " + JSON.stringify(v), V("name", v), false));
["scrolloverview", "jankeesvw.notification-center", "io.github.mtolhuys.theme-manager"].forEach(v =>
  eq("name accepts " + v, V("name", v), true));
["http://github.com/a/b.git", "git://github.com/a/b.git", "file:///etc/passwd", "ext::sh -c id",
 "--upload-pack=touch /tmp/x", "https://-x/a", "https://host", "https://h/a b", "https://h/a;b",
 "ssh://git@h/a.git", "-https://h/a"].forEach(v =>
  eq("url rejects " + v, V("url", v), false));
["https://github.com/yayuuu/hyprland-scroll-overview", "https://github.com/rosakodu/omarchy-dock.git",
 "git@github.com:foo/baz.git", "https://git.example.com:8443/a/b.git"].forEach(v =>
  eq("url accepts " + v, V("url", v), true));

// omarchy rows cloned from a built-in plugin use a plugin id as ref
eq("omarchy id-shaped ref is valid", C.rowTargetError({ type: "omarchy", ref: "omarchy.bar", id: "x.floating-bar" }), "");
ok("omarchy id-shaped ref: remove by id", C.commandForRow({ type: "omarchy", ref: "omarchy.bar", id: "x.floating-bar" }, "remove").indexOf("remove 'x.floating-bar' --yes") !== -1);
eq("omarchy id-shaped ref: no add stage", C.commandForRow({ type: "omarchy", ref: "omarchy.bar" }, "add"), "");
ok("hyprland ref must still be a URL", /Git URL/.test(C.rowTargetError({ type: "hyprland", ref: "scrolloverview" })));

// every shipped default row is well-formed
require("../catalog.default.json").forEach(r =>
  eq("default row valid: " + r.name, C.rowTargetError(r), ""));

// rowTargetError reasons
ok("rowTargetError pkg", /Invalid package/.test(C.rowTargetError({ type: "pacman", ref: "ok --noconfirm" })));
ok("rowTargetError url", /Git URL/.test(C.rowTargetError({ type: "omarchy", ref: "--upload-pack=x" })));
ok("rowTargetError id", /Invalid id/.test(C.rowTargetError({ type: "hyprland", ref: "https://h/a.git", id: "-f" })));
eq("hasTarget false for invalid", C.hasTarget(C.normalizeRow({ type: "aur", ref: "--overwrite=*" })), false);

// buildCommand never lets user data become an option
const hostile = [
  { type: "pacman", ref: "good --config=/tmp/x -Syu" },
  { type: "aur", ref: "--overwrite=*" },
  { type: "flatpak", ref: "--user org.x.Y" },
  { type: "omarchy", ref: "--help" },
  { type: "omarchy", ref: "https://h/p.git", id: "--yes" },
  { type: "hyprland", ref: "https://h/q.git", id: "-f" },
  { type: "hyprland", ref: "", id: "--force" }
];
["add", "remove"].forEach(action => {
  const cmd = C.buildCommand(C.groupByType(hostile.map(C.normalizeRow)), action);
  ok(action + " hostile rows produce no user-supplied option: " + JSON.stringify(cmd),
    !/'-/.test(cmd));
  // a row with any bad target is skipped entirely, not partially installed
  ok(action + " partially-bad pacman row skipped", cmd.indexOf("'good'") === -1);
});
eq("groupForInstall skips invalid rows", C.groupForInstall(hostile.map(C.normalizeRow)).pacman.length, 0);
eq("commandForRow of invalid row is empty", C.commandForRow({ type: "hyprland", id: "--force" }, "remove"), "");
ok("flatpak install carries -- terminator",
  C.buildCommand(C.groupByType([{ type: "flatpak", ref: "org.x.Y" }]), "add").indexOf(" -y -- flathub ") !== -1);
ok("every stage uses an absolute tool path",
  rmMixed.split(" && ").every(st => st.charAt(0) === "/"));

// importInstalled drops malformed status entries
const badImp = C.importInstalled([], {
  plugins: [{ id: "--evil", firstParty: false }, { id: "ok.id", clonedFrom: "--upload-pack=x", firstParty: false }],
  hyprpm: [{ repo: "-f", plugins: [] }],
  flatpak: ["--user"],
  apps: ["-Syu", "mpv"]
});
eq("importInstalled skips malformed entries", badImp.length, 2);   // ok.id + mpv
ok("importInstalled strips bad clonedFrom", badImp.find(r => r.id === "ok.id").ref === "");

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
  B.flatpak + " install -y -- flathub 'com.nvidia.geforcenow'");
eq("flatpak remove command", C.buildCommand(C.groupByType([fpRows[0]]), "remove"),
  B.flatpak + " uninstall -y -- 'com.nvidia.geforcenow'");
const fpMixed = C.buildCommand(C.groupByType([
  { type: "pacman", ref: "p" }, { type: "flatpak", ref: "org.x.Y" }
]), "add");
ok("flatpak stage after pacman: " + fpMixed,
  fpMixed === B.pkgAdd + " 'p' && " + B.flatpak + " install -y -- flathub 'org.x.Y'");
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

// ── AUR mode ────────────────────────────────────────────────────────────────
eq("aurMode default", C.normalizeAurMode(undefined), "enabled");
eq("aurMode unknown -> enabled", C.normalizeAurMode("sometimes"), "enabled");
eq("aurMode normalizes case", C.normalizeAurMode(" Updates "), "updates");
ok("enabled allows add/update/remove", ["add", "update", "remove"].every(a => C.aurAllows("enabled", a)));
ok("updates blocks add", !C.aurAllows("updates", "add"));
ok("updates allows update + remove", C.aurAllows("updates", "update") && C.aurAllows("updates", "remove"));
ok("disabled blocks everything", ["add", "update", "remove"].every(a => !C.aurAllows("disabled", a)));

const aurMix = C.groupByType([
  { type: "pacman", ref: "cowsay", installed: true },
  { type: "aur", ref: "yay", installed: true }
]);
const addUpd = C.buildCommand(aurMix, "add", undefined, "updates");
ok("updates mode: add keeps pacman: " + addUpd, addUpd.indexOf(B.pkgAdd + " 'cowsay'") === 0);
ok("updates mode: add drops aur", addUpd.indexOf(B.pkgAurAdd) === -1 && addUpd.indexOf("yay") === -1);
eq("enabled mode: add includes aur", C.buildCommand(aurMix, "add", undefined, "enabled").indexOf(B.pkgAurAdd + " 'yay'") !== -1, true);
eq("mode omitted behaves as enabled", C.buildCommand(aurMix, "add").indexOf(B.pkgAurAdd + " 'yay'") !== -1, true);
eq("updates mode: remove still drops aur", C.buildCommand(aurMix, "remove", undefined, "updates"), B.pkgDrop + " 'cowsay' 'yay'");
eq("disabled mode: remove leaves aur alone", C.buildCommand(aurMix, "remove", undefined, "disabled"), B.pkgDrop + " 'cowsay'");
eq("update command", C.buildCommand(aurMix, "update", undefined, "updates"), B.yay + " -S --aur --needed --noconfirm 'yay'");
eq("update ignores non-aur rows", C.buildCommand(C.groupByType([{ type: "pacman", ref: "cowsay" }]), "update"), "");
eq("disabled mode: update is empty", C.buildCommand(aurMix, "update", undefined, "disabled"), "");
eq("update skips invalid aur target", C.buildCommand(C.groupByType([{ type: "aur", ref: "--overwrite=*" }]), "update"), "");
eq("commandForRow passes mode", C.commandForRow({ type: "aur", ref: "yay" }, "add", undefined, "updates"), "");

const updRows = [
  { type: "aur", ref: "yay", installed: true },
  { type: "aur", ref: "paru", installed: false },
  { type: "pacman", ref: "cowsay", installed: true }
];
const gu = C.groupForUpdate(updRows);
eq("groupForUpdate: installed aur only", gu.aur.length, 1);
eq("groupForUpdate: no pacman", gu.pacman.length, 0);

const shown = [{ type: "aur", name: "yay" }, { type: "pacman", name: "cowsay" }];
eq("disabled hides aur rows", C.filterRows(shown, { aurMode: "disabled" }).length, 1);
eq("updates keeps aur rows visible", C.filterRows(shown, { aurMode: "updates" }).length, 2);
eq("disabled + aur filter shows nothing", C.filterRows(shown, { type: "aur", aurMode: "disabled" }).length, 0);

console.log(failed === 0 ? "\nALL PASS" : "\n" + failed + " FAILED");
process.exit(failed === 0 ? 0 : 1);
