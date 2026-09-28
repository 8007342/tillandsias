#!/usr/bin/env bash
# @trace order:1434-vm7g
#
# Fixture for scripts/check-windows-tray-clippy.sh. Portable: it lints tiny
# scratch crates through the decider's manifest seam, and fakes the platform
# through its uname seam, so every arm runs on any host with cargo clippy.
#
#   ARM 1  a crate with a clippy warning is REFUSED (exit 1), by name.
#          PRE-FIX RESULT: FAILS, the decider does not exist.
#   ARM 2  NEGATIVE CONTROL: the same crate without the warning is ok.
#   ARM 3  off Windows it skips by name and never runs cargo.
#   ARM 4  a change that does not touch the crate skips by name; touching it
#          (an untracked file under the crate) makes it run and refuse.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEC="$ROOT/scripts/check-windows-tray-clippy.sh"
[ -f "$DEC" ] || { echo "skip:windows-tray-clippy-fixture:decider-absent"; exit 0; }
command -v cargo >/dev/null 2>&1 && cargo clippy --version >/dev/null 2>&1 \
    || { echo "skip:windows-tray-clippy-fixture:no-cargo-clippy"; exit 0; }

W="$(mktemp -d)" || exit 1
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

R="$W/repo"
mkdir -p "$R/scripts" "$R/crate/src"
cp "$DEC" "$R/scripts/"
cat > "$R/crate/Cargo.toml" <<'EOF'
[package]
name = "clippy-fixture"
version = "0.1.0"
edition = "2021"
[workspace]
EOF
lint_src='pub fn one() -> i32 {
    return 1;
}
'
clean_src='pub fn one() -> i32 {
    1
}
'
printf '%s' "$clean_src" > "$R/crate/src/lib.rs"
git -C "$R" init -q 2>/dev/null
git -C "$R" config user.email f@x.invalid; git -C "$R" config user.name f
# clippy writes crate/Cargo.lock on its first run; it is not a change to the
# crate, and here it would read as one (the real tray's lock is at the root).
printf 'Cargo.lock\n' > "$R/.gitignore"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm base
git -C "$R" update-ref refs/remotes/origin/linux-next HEAD
export CARGO_TARGET_DIR="$W/target"

run() { (cd "$R" && TILLANDSIAS_WINDOWS_CLIPPY_MANIFEST=crate/Cargo.toml "$@" 2>/dev/null); }

# ARM 1: the lint (clippy::needless_return) is refused.
printf '%s' "$lint_src" > "$R/crate/src/lib.rs"
o1="$(run env TILLANDSIAS_WINDOWS_CLIPPY_UNAME=MINGW64_NT bash scripts/check-windows-tray-clippy.sh --all)"; rc1=$?
if [ "$rc1" -eq 1 ] && [ "$(printf '%s' "$o1" | tail -1)" = "refused:windows-tray-clippy:1-errors" ]; then
    ok "ARM 1 a clippy warning is refused by name"
else
    bad "ARM 1 expected refused:windows-tray-clippy:1-errors, rc 1 (rc=$rc1): $(printf '%s' "$o1" | tail -1)"
fi

# ARM 2: negative control.
printf '%s' "$clean_src" > "$R/crate/src/lib.rs"
o2="$(run env TILLANDSIAS_WINDOWS_CLIPPY_UNAME=MINGW64_NT bash scripts/check-windows-tray-clippy.sh --all)"; rc2=$?
if [ "$rc2" -eq 0 ] && [ "$(printf '%s' "$o2" | tail -1)" = "ok:windows-tray-clippy:clean" ]; then
    ok "ARM 2 the same crate without the warning is clean"
else
    bad "ARM 2 expected ok:windows-tray-clippy:clean (rc=$rc2): $(printf '%s' "$o2" | tail -1)"
fi

# ARM 3: off Windows, skip by name without running cargo (a cargo that would
# fail is first on PATH, so a run would not read as a skip).
mkdir -p "$W/nocargo"; printf '#!/bin/sh\necho ran >> "%s/cargo.ran"\nexit 1\n' "$W" > "$W/nocargo/cargo"; chmod +x "$W/nocargo/cargo"
o3="$(run env PATH="$W/nocargo:$PATH" TILLANDSIAS_WINDOWS_CLIPPY_UNAME=Linux bash scripts/check-windows-tray-clippy.sh --all)"; rc3=$?
if [ "$rc3" -eq 0 ] && [ "$(printf '%s' "$o3" | tail -1)" = "skip:windows-tray-clippy:not-windows:Linux" ] && [ ! -e "$W/cargo.ran" ]; then
    ok "ARM 3 off Windows it skips by name and never runs cargo"
else
    bad "ARM 3 expected skip:...:not-windows:Linux with no cargo run (rc=$rc3): $(printf '%s' "$o3" | tail -1)"
fi

# ARM 4: scope. Clean tree against the base -> untouched; then an untracked
# file under the crate plus the lint -> runs and refuses.
o4a="$(run env TILLANDSIAS_WINDOWS_CLIPPY_UNAME=MINGW64_NT bash scripts/check-windows-tray-clippy.sh)"
printf '%s' "$lint_src" > "$R/crate/src/lib.rs"
o4b="$(run env TILLANDSIAS_WINDOWS_CLIPPY_UNAME=MINGW64_NT bash scripts/check-windows-tray-clippy.sh)"; rc4b=$?
if [ "$(printf '%s' "$o4a" | tail -1)" = "skip:windows-tray-clippy:crate-untouched" ] \
   && [ "$rc4b" -eq 1 ] && [ "$(printf '%s' "$o4b" | tail -1)" = "refused:windows-tray-clippy:1-errors" ]; then
    ok "ARM 4 an untouched crate skips; a changed one runs and refuses"
else
    bad "ARM 4 scope: untouched='$(printf '%s' "$o4a" | tail -1)' changed='$(printf '%s' "$o4b" | tail -1)' (rc=$rc4b)"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:windows-tray-clippy-fixture:$pass"; exit 0; fi
echo "violation:windows-tray-clippy-fixture:$pass/$total"; exit 1
