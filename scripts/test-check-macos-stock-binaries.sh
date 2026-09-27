#!/usr/bin/env bash
# @trace spec:macos-native-tray, order:1420-umka
#
# Fixture for check-macos-stock-binaries.sh. Hermetic: each arm copies the
# checked sources into a scratch root, mutates one thing, and runs the lint
# with --root, so the checkout is never edited.
#
#   1  the current tree passes
#   2  MUTATION: an added Command::new("qemu-img") in vz.rs is refused, naming it
#   3  MUTATION: hdiutil back to a bare name is refused (the pre-fix state)
#   4  MUTATION: a bare name through the tray's spawn_bounded helper is refused
#   5  MUTATION: the installer's PATH pin removed is refused
#   6  MUTATION: a PATH pin that adds /opt/homebrew/bin is refused
#   7  CONTROL: an added absolute stock spawn (/usr/bin/true) still passes
#
#   PASS: check-macos-stock-binaries <n>/<n>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$ROOT/scripts/check-macos-stock-binaries.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/macos-stock.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$W"' EXIT

# A fresh scratch root holding exactly what the lint reads.
fresh() {
    rm -rf "$W/r"
    mkdir -p "$W/r/crates/tillandsias-macos-tray" "$W/r/crates/tillandsias-vm-layer/src/materialize" "$W/r/scripts"
    cp -R "$ROOT/crates/tillandsias-macos-tray/src" "$W/r/crates/tillandsias-macos-tray/src"
    cp "$ROOT/crates/tillandsias-vm-layer/src/vz.rs" "$W/r/crates/tillandsias-vm-layer/src/vz.rs"
    cp "$ROOT/crates/tillandsias-vm-layer/src/materialize/macos.rs" "$W/r/crates/tillandsias-vm-layer/src/materialize/macos.rs"
    cp "$ROOT/scripts/install-macos.sh" "$W/r/scripts/install-macos.sh"
}
lint() { bash "$LINT" --root "$W/r" 2>&1; }
VZ="$W/r/crates/tillandsias-vm-layer/src/vz.rs"
INST="$W/r/scripts/install-macos.sh"

# ARM 1
fresh; out="$(lint)"; rc=$?
case "$rc:$out" in
    0:*"ok:macos-stock-binaries:"*) ok "ARM 1: the current tree passes" ;;
    *) bad "ARM 1: rc=$rc $(printf '%s' "$out" | tail -3)" ;;
esac

# ARM 2
fresh; printf '\nfn regression() { let _ = std::process::Command::new("qemu-img"); }\n' >> "$VZ"
out="$(lint)"; rc=$?
case "$rc:$out" in
    1:*'spawns "qemu-img"'*"violation:macos-stock-binaries:1"*) ok "ARM 2: an added qemu-img spawn is refused and named" ;;
    *) bad "ARM 2: rc=$rc $(printf '%s' "$out" | tail -3)" ;;
esac

# ARM 3
fresh; sed -i.bak 's|Command::new("/usr/bin/hdiutil")|Command::new("hdiutil")|' "$VZ"
out="$(lint)"; rc=$?
case "$rc:$out" in
    1:*'spawns "hdiutil"'*) ok "ARM 3: a bare hdiutil is refused" ;;
    *) bad "ARM 3: rc=$rc $(printf '%s' "$out" | tail -3)" ;;
esac

# ARM 4
fresh; sed -i.bak 's|spawn_bounded("/usr/bin/security",|spawn_bounded("security",|' "$W/r/crates/tillandsias-macos-tray/src/installation_uuid.rs"
out="$(lint)"; rc=$?
case "$rc:$out" in
    1:*'spawns "security"'*) ok "ARM 4: a bare name through spawn_bounded is refused" ;;
    *) bad "ARM 4: rc=$rc $(printf '%s' "$out" | tail -3)" ;;
esac

# ARM 5
fresh; sed -i.bak '/^export PATH=\/usr\/bin:\/bin:\/usr\/sbin:\/sbin$/d' "$INST"
out="$(lint)"; rc=$?
case "$rc:$out" in
    1:*"install-macos.sh: the first statement after"*) ok "ARM 5: removing the installer's PATH pin is refused" ;;
    *) bad "ARM 5: rc=$rc $(printf '%s' "$out" | tail -3)" ;;
esac

# ARM 6
fresh; sed -i.bak 's|^export PATH=/usr/bin:/bin:/usr/sbin:/sbin$|export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin|' "$INST"
out="$(lint)"; rc=$?
case "$rc:$out" in
    1:*"install-macos.sh: the first statement after"*) ok "ARM 6: a PATH pin that adds Homebrew is refused" ;;
    *) bad "ARM 6: rc=$rc $(printf '%s' "$out" | tail -3)" ;;
esac

# ARM 7
fresh; printf '\nfn fine() { let _ = std::process::Command::new("/usr/bin/true"); }\n' >> "$VZ"
out="$(lint)"; rc=$?
case "$rc:$out" in
    0:*"ok:macos-stock-binaries:"*) ok "ARM 7 (control): an absolute stock spawn still passes" ;;
    *) bad "ARM 7: rc=$rc $(printf '%s' "$out" | tail -3)" ;;
esac

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: check-macos-stock-binaries $pass/$total"
    exit 0
fi
echo "FAIL: check-macos-stock-binaries $pass/$total"
exit 1
