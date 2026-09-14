#!/usr/bin/env bash
# @trace order:1179-yshc, spec:accel-capability-probe
#
# CLOSURE for 1179-yshc: test-capabilities-envelope-names-its-source.sh must
# resolve the binary the GATE built, not whatever artifact happens to sit
# in-tree. On every host where the builder re-execs with CARGO_TARGET_DIR
# redirected (every Windows host, via scripts/with-wsl2-builder.sh) a
# hardcoded `$ROOT/target/debug/tillandsias` grades a stale in-tree binary
# while the fresh one the gate just built sits unused in the redirected dir.
# MEASURED by esme on esmeraldinha, 2026-09-14: 5/6 arms red with
# accel_source='' (the field ABSENT) under exactly that regime, 6/6 standalone
# once the in-tree binary was rebuilt.
#
# HERMETIC: nothing here touches this host's real target/ or its real
# CARGO_TARGET_DIR (if any is set in the caller's environment — both
# candidate roots below are mktemp paths and CARGO_TARGET_DIR is pinned to
# one of them for the duration of each resolution call). Both "binaries" are
# tiny shell fakes; the fixture never builds or execs the real product.
#
# THE RESOLUTION LOGIC UNDER TEST IS A LITERAL COPY of the two shapes this
# packet's row concerns: `resolve_pre_fix` is
# `BIN="${TILLANDSIAS_BIN:-$ROOT/target/debug/tillandsias}"` byte-for-byte —
# the exact line the row cites as the defect — and `resolve_post_fix` is the
# fixed shape now live in test-capabilities-envelope-names-its-source.sh
# (source plan-binary-probe.sh, call resolve_target_binary, fall back to the
# same in-tree default). A change to the real suite's resolution without a
# matching change here is drift this file cannot see — keep them lined up by
# eye at every edit to either file.
#
# THE PRE-FIX ARM IS NOT DECORATION (see "Exit criteria must fail on the
# pre-fix code"): arm 1 proves the OLD line actually fails the closure's own
# assertion — "the redirected, current binary is chosen" — before arm 2
# proves the NEW line satisfies it. Without arm 1, a litmus that only checks
# "a binary was found" would have passed against the pre-fix suite too (the
# stale in-tree binary IS a binary, and is executable) — which is exactly the
# trap the row's own text names: "an arm that only checks 'a binary was
# found' passes today."
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/envelope-resolve.XXXXXX")" || exit 3
trap 'rm -rf "$TMP"' EXIT

FAKE_ROOT="$TMP/checkout"
REDIR_TARGET="$TMP/redirected-target"
mkdir -p "$FAKE_ROOT/target/debug" "$REDIR_TARGET/debug"

# A STALE in-tree fake: answers with envelope_source ABSENT — the shape the
# row's esme transcript shows (accel_source='', the field absent entirely).
cat > "$FAKE_ROOT/target/debug/tillandsias" <<'FAKE'
#!/usr/bin/env bash
echo "stale=true envelope_absent=true"
FAKE
chmod +x "$FAKE_ROOT/target/debug/tillandsias"

# A CURRENT, redirected fake: answers WITH accel_source= — the field the real
# suite's arms 1, 2, 5 and 6 key on.
cat > "$REDIR_TARGET/debug/tillandsias" <<'FAKE'
#!/usr/bin/env bash
echo "accel_source=measured envelope_source=redirected"
FAKE
chmod +x "$REDIR_TARGET/debug/tillandsias"

# ── PRE-FIX resolution: a byte-for-byte copy of the defect line the row
#    cites — never consults CARGO_TARGET_DIR at all.
resolve_pre_fix() (
    _root="$1"
    unset TILLANDSIAS_BIN
    ROOT="$_root"
    BIN="${TILLANDSIAS_BIN:-$ROOT/target/debug/tillandsias}"
    printf '%s\n' "$BIN"
)

# ── POST-FIX resolution: the shape now live in the real suite — the shared
#    probe, honouring CARGO_TARGET_DIR, falling back to the same in-tree
#    default. The probe itself is sourced from THIS repo's real
#    scripts/plan-binary-probe.sh (order 1154-6big lives there, not inside
#    the fake checkout, which carries only a planted target/ tree); the fake
#    root is passed to resolve_target_binary as the `root` argument, which is
#    the only thing that determines where it looks.
resolve_post_fix() (
    _fake_root="$1"
    unset TILLANDSIAS_BIN
    _probe="$ROOT/scripts/plan-binary-probe.sh"
    if [ -r "$_probe" ]; then
        . "$_probe"
    else
        resolve_target_binary() { return 1; }
    fi
    BIN="$(resolve_target_binary tillandsias debug "$_fake_root" 2>/dev/null)"
    [ -n "$BIN" ] || BIN="$_fake_root/target/debug/tillandsias"
    printf '%s\n' "$BIN"
)

# ── arm 1: the PRE-FIX line, run against this fixture's planted pair, FAILS
#    the closure's own assertion — it picks the stale in-tree binary and
#    never sees the redirected, current one at all. This is measured, not
#    asserted from prose: we actually run the resolved path and read its
#    envelope.
pre_bin="$(CARGO_TARGET_DIR="$REDIR_TARGET" resolve_pre_fix "$FAKE_ROOT")"
pre_out="$("$pre_bin" --capabilities 2>/dev/null)"
case "$pre_out" in
    *accel_source=*)
        bad "pre-fix resolution unexpectedly reached the redirected binary ($pre_bin) — this control is not exercising the row's defect"
        ;;
    *)
        ok "pre-fix resolution ($pre_bin) fails the closure: it picks the stale in-tree binary, exactly the row's defect"
        ;;
esac

# ── arm 2: THE CLOSURE. POST-FIX resolution picks the REDIRECTED, current
#    artifact — the binary the gate actually built.
post_bin="$(CARGO_TARGET_DIR="$REDIR_TARGET" resolve_post_fix "$FAKE_ROOT")"
post_out="$("$post_bin" --capabilities 2>/dev/null)"
case "$post_out" in
    *accel_source=*)
        ok "post-fix resolution ($post_bin) picks the redirected, current binary"
        ;;
    *)
        bad "post-fix resolution picked '$post_bin' — expected the redirected current binary, got the stale in-tree one"
        ;;
esac

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: envelope-suite-resolves-the-gates-artifact $pass/$total (1179-yshc)"
    exit 0
fi
echo "FAIL: envelope-suite-resolves-the-gates-artifact $pass/$total (1179-yshc)"
exit 1
