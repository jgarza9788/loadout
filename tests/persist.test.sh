#!/bin/bash
# Run: bash tests/persist.test.sh
# Exercises bin/loadout-catalog's no-follow / bounded / atomic guarantees.

set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
helper=(/usr/bin/python3 -I -S "$here/bin/loadout-catalog")
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failed=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failed=$((failed + 1)); fi; }

run() { timeout 5 "${helper[@]}" "$@"; }

# ── happy path ───────────────────────────────────────────────────────────────
d="$tmp/cfg"
out="$(run read "$d/catalog.json")"; rc=$?
ok "read of missing file -> []" '[[ $rc == 0 && $out == "[]" ]]'
ok "missing dir created 0700" '[[ $(stat -c %a "$d") == 700 ]]'

echo '[{"name":"a"}]' | run write "$d/catalog.json" >/dev/null; rc=$?
ok "write succeeds" '[[ $rc == 0 ]]'
ok "new file is 0600" '[[ $(stat -c %a "$d/catalog.json") == 600 ]]'
out="$(run read "$d/catalog.json")"
ok "read back what was written" '[[ $out == "[{\"name\": \"a\"}]" ]]'

chmod 640 "$d/catalog.json"
ino_before="$(stat -c %i "$d/catalog.json")"
echo '[1,2]' | run write "$d/catalog.json" >/dev/null
ok "write preserves existing 0640 mode" '[[ $(stat -c %a "$d/catalog.json") == 640 ]]'
ok "write replaces via rename (new inode)" '[[ $(stat -c %i "$d/catalog.json") != "$ino_before" ]]'
ok "no temp file left behind" '[[ -z $(find "$d" -name ".*.tmp") ]]'

# ── rejected writes leave the file alone ─────────────────────────────────────
echo 'not json' | run write "$d/catalog.json" >/dev/null; rc=$?
ok "write rejects non-JSON" '[[ $rc == 2 && $(cat "$d/catalog.json") == "[1,2]" ]]'
echo '{"a":1}' | run write "$d/catalog.json" >/dev/null; rc=$?
ok "write rejects non-array" '[[ $rc == 2 ]]'
head -c 1100000 /dev/zero | tr '\0' ' ' | run write "$d/catalog.json" >/dev/null; rc=$?
ok "write rejects oversized input" '[[ $rc == 2 && $(cat "$d/catalog.json") == "[1,2]" ]]'

# ── symlinked file ───────────────────────────────────────────────────────────
s="$tmp/sym"; mkdir -m 700 "$s"
echo '["secret"]' > "$tmp/victim.json"
ln -s "$tmp/victim.json" "$s/catalog.json"
out="$(run read "$s/catalog.json")"; rc=$?
ok "read refuses symlinked catalog" '[[ $rc == 2 && $out == *error* && $out != *secret* ]]'
echo '[]' | run write "$s/catalog.json" >/dev/null; rc=$?
ok "write refuses symlinked catalog" '[[ $rc == 2 && $(cat "$tmp/victim.json") == "[\"secret\"]" ]]'
ok "symlink itself not replaced" '[[ -L "$s/catalog.json" ]]'

# ── symlinked directory ──────────────────────────────────────────────────────
mkdir -m 700 "$tmp/realdir"
ln -s "$tmp/realdir" "$tmp/linkdir"
echo '[]' | run write "$tmp/linkdir/catalog.json" >/dev/null; rc=$?
ok "write refuses symlinked config dir" '[[ $rc == 2 && ! -e "$tmp/realdir/catalog.json" ]]'
run read "$tmp/linkdir/catalog.json" >/dev/null; rc=$?
ok "read refuses symlinked config dir" '[[ $rc == 2 ]]'

# ── special files ────────────────────────────────────────────────────────────
f="$tmp/fifo"; mkdir -m 700 "$f"; mkfifo -m 600 "$f/catalog.json"
start=$SECONDS
run read "$f/catalog.json" >/dev/null; rc=$?
ok "read refuses FIFO without blocking" '[[ $rc == 2 && $((SECONDS - start)) -lt 3 ]]'
echo '[]' | run write "$f/catalog.json" >/dev/null; rc=$?
ok "write refuses FIFO without blocking" '[[ $rc == 2 && -p "$f/catalog.json" ]]'

# ── size / permissions ───────────────────────────────────────────────────────
b="$tmp/big"; mkdir -m 700 "$b"
head -c 2097152 /dev/zero > "$b/catalog.json"; chmod 600 "$b/catalog.json"
run read "$b/catalog.json" >/dev/null; rc=$?
ok "read refuses 2 MiB catalog" '[[ $rc == 2 ]]'

w="$tmp/ww"; mkdir -m 700 "$w"
echo '[]' > "$w/catalog.json"; chmod 666 "$w/catalog.json"
run read "$w/catalog.json" >/dev/null; rc=$?
ok "read refuses world-writable catalog" '[[ $rc == 2 ]]'

g="$tmp/gw"; mkdir -m 770 "$g"
run read "$g/catalog.json" >/dev/null; rc=$?
ok "read refuses group-writable config dir" '[[ $rc == 2 ]]'

echo
if ((failed)); then echo "$failed FAILED"; exit 1; else echo "ALL PASS"; fi
