#!/usr/bin/env bash
# Fixture for check-guest-unit-hardening.sh (order 309, criterion 3).
#
# Three directions, because two would not be enough here:
#   1. the live tree passes (the units are unconfined today);
#   2. re-introducing order 308's exact directives FAILS — this is the
#      regression the guard exists to refuse, and asserting it is what
#      distinguishes a real guard from a green light;
#   3. a guard that can no longer FIND the unit text fails CLOSED. A checker
#      whose markers drift silently guards nothing while still printing ok,
#      which is the failure shape 700-nz4n was filed about.
#
# Hermetic: every mutation happens on a COPY under TMPDIR. The live
# crates/ tree is never written.
# freshness: auditor=macos-tlatoanis-macbook-air-fable5 date=2026-08-17 verdict=refreshed scope=309 authoring
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/check-guest-unit-hardening.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/guest-unit-hardening.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0

expect() {
    # expect <name> <want-verdict-prefix> <want-exit> <workdir>
    # Run the checker that lives INSIDE the tree under test: it resolves its
    # own repo root from $BASH_SOURCE, so invoking the original from a `cd`
    # would silently re-measure the live tree — which is exactly how the
    # first run of this fixture "passed" two scenarios it should have failed.
    local name="$1" want="$2" want_rc="$3" dir="$4" got rc
    got="$(cd "$dir" && bash "$dir/scripts/check-guest-unit-hardening.sh" 2>/dev/null)"
    rc=$?
    case "$got" in
        "$want"*) ;;
        *)
            echo "FAIL: $name — got '$got', want '${want}*'" >&2
            fails=$((fails + 1))
            return
            ;;
    esac
    if [ "$rc" -ne "$want_rc" ]; then
        echo "FAIL: $name — exit $rc, want $want_rc" >&2
        fails=$((fails + 1))
    fi
}

# A minimal tree the checker can walk: only the two files it inspects.
seed_tree() {
    local dest="$1"
    mkdir -p "$dest/crates/tillandsias-vm-layer/src"
    cp "$ROOT/crates/tillandsias-vm-layer/src/vz.rs" \
       "$dest/crates/tillandsias-vm-layer/src/vz.rs"
    cp "$ROOT/crates/tillandsias-vm-layer/src/wsl.rs" \
       "$dest/crates/tillandsias-vm-layer/src/wsl.rs"
    # The checker resolves ROOT from its own location, so it must live in the
    # copied tree too.
    mkdir -p "$dest/scripts"
    cp "$CHECKER" "$dest/scripts/"
}

# 1. Live tree: unconfined today.
expect "live-tree-passes" "ok:guest-unit-unconfined" 0 "$ROOT"

# 2. Order 308's exact regression must fail.
seed_tree "$TMP/regress"
awk '
    index($0, "cat > /etc/systemd/system/tillandsias-headless.service") { print; inunit = 1; next }
    inunit && $0 ~ /^\[Service\]$/ {
        print
        print "NoNewPrivileges=yes"
        print "CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
        inunit = 0
        next
    }
    { print }
' "$ROOT/crates/tillandsias-vm-layer/src/vz.rs" > "$TMP/regress/crates/tillandsias-vm-layer/src/vz.rs"
grep -q 'NoNewPrivileges=yes' "$TMP/regress/crates/tillandsias-vm-layer/src/vz.rs" \
    || { echo "FAIL: fixture could not inject the 308 directives — the test would be vacuous" >&2; fails=$((fails + 1)); }
expect "order-308-regression-refused" "blocked:guest-unit-hardened:" 1 "$TMP/regress"

# 3. Drifted markers must fail CLOSED, not pass silently.
seed_tree "$TMP/drift"
sed 's|cat > /etc/systemd/system/tillandsias-headless.service|cat > /etc/systemd/system/renamed-unit.service|g' \
    "$ROOT/crates/tillandsias-vm-layer/src/vz.rs" > "$TMP/drift/crates/tillandsias-vm-layer/src/vz.rs"
sed 's|cat > /etc/systemd/system/tillandsias-headless.service|cat > /etc/systemd/system/renamed-unit.service|g' \
    "$ROOT/crates/tillandsias-vm-layer/src/wsl.rs" > "$TMP/drift/crates/tillandsias-vm-layer/src/wsl.rs"
expect "drifted-markers-fail-closed" "blocked:guest-unit-not-found" 1 "$TMP/drift"

if [ "$fails" -gt 0 ]; then
    echo "FAIL: guest-unit-hardening fixture: $fails scenario(s) diverged" >&2
    exit 1
fi
echo "PASS: guest-unit-hardening fixture 3/3 scenarios green"
exit 0
