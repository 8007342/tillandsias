#!/usr/bin/env bash
# @trace spec:accel-capability-probe
# @trace order:967-6ax6
#
# Fixture for the inference-container name-agreement guard.
#
# THE NEGATIVE CONTROL IS THE WHOLE POINT. The defect this guard ratchets is a
# SILENT UNDER-CLAIM — nothing fails, a rung just reads `-` forever — so a guard
# that cannot be shown to refuse a real drift is indistinguishable from one that
# always passes. Both arms therefore drive the REAL guard against synthetic
# files, rather than asserting on its source.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-inference-container-name-agreement.sh"
[ -x "$GUARD" ] || { echo "blocked:no-guard:$GUARD"; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/inference-name.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() {
    if [ "$1" = ok ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$2"
    else fail=$((fail + 1)); printf 'FAIL %s\n' "$2"; [ -n "${3:-}" ] && printf '     %s\n' "$3"; fi
}

# $1 = name the script creates, $2 = candidate array body
write_pair() {
    cat > "$tmp/script.sh" <<EOS
#!/usr/bin/env bash
# A comment mentioning tillandsias-totally-different on purpose.
DEV_CONTAINER="$1"
EOS
    cat > "$tmp/probe.rs" <<EOS
/// Doc comment naming tillandsias-totally-different on purpose.
const INFERENCE_CONTAINER_CANDIDATES: [&str; 2] =
    [$2];
EOS
}
run() {
    TILLANDSIAS_DEV_INFERENCE_SCRIPT="$tmp/script.sh" \
    TILLANDSIAS_ACCEL_PROBE_SRC="$tmp/probe.rs" bash "$GUARD" 2>/dev/null
}

# 1. AGREEMENT PASSES.
write_pair "tillandsias-dev-inference" '"tillandsias-inference", "tillandsias-dev-inference"'
out="$(run)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "ok:inference-container-name-agreement:tillandsias-dev-inference" ]; then
    check ok "agreeing names pass with the name in the verdict"
else
    check FAIL "agreeing names pass" "rc=$rc out=[$out]"
fi

# 2. NEGATIVE CONTROL — the exact 967-6ax6 shape: the creator renamed, the
#    consumer not. This is the state yoga measured, and it must REFUSE.
write_pair "tillandsias-dev-inference" '"tillandsias-inference", "tillandsias-prod-inference"'
out="$(run)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '^violation:inference-container-name-drift:creates=tillandsias-dev-inference:'; then
    check ok "NEGATIVE: a renamed creator is refused, and the verdict names both sides"
else
    check FAIL "NEGATIVE: a renamed creator is refused" "rc=$rc out=[$out]"
fi

# 3. A MENTION IN A COMMENT MUST NOT SATISFY IT. Both real files discuss these
#    names at length, so a pattern matching the string anywhere would pass over
#    every rename — the guard would exist and check nothing.
write_pair "tillandsias-totally-different" '"tillandsias-inference", "tillandsias-dev-inference"'
out="$(run)"; rc=$?
if [ "$rc" -ne 0 ]; then
    check ok "a name appearing only in prose does not count as agreement"
else
    check FAIL "a name appearing only in prose does not count" "rc=$rc out=[$out]"
fi

# 4. A missing assignment is BLOCKED, not passed. Fail closed: if the guard
#    cannot find what the creator names, it knows nothing, and "knows nothing"
#    must not render as "agrees".
printf '#!/usr/bin/env bash\necho hi\n' > "$tmp/script.sh"
cat > "$tmp/probe.rs" <<'EOS'
const INFERENCE_CONTAINER_CANDIDATES: [&str; 1] = ["tillandsias-inference"];
EOS
out="$(run)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q '^blocked:no-dev-container-assignment-in:'; then
    check ok "a missing assignment blocks rather than passing"
else
    check FAIL "a missing assignment blocks" "rc=$rc out=[$out]"
fi

# 5. THE LIVE TREE AGREES. Without this the fixture proves the guard works on
#    synthetic input while the real pair could be drifting right now.
out="$(bash "$GUARD" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ok:inference-container-name-agreement:'; then
    check ok "the live tree's two names agree"
else
    check FAIL "the live tree's two names agree" "rc=$rc out=[$out]"
fi

# 6. The guard is REACHABLE FROM THE GATE. An unwired guard is dead text
#    (865-n8vq), and the auditor greps for the name, so a mention would clear
#    the audit while leaving it as dead as it was.
#
#    build.sh runs THIS FIXTURE, not the guard directly, and that is the right
#    wiring: arm 5 above runs the guard against the live tree, so the gate gets
#    the live verdict AND the proof that the guard can still refuse. Wiring the
#    guard alone would check the tree without ever checking the checker.
if grep -q 'test-inference-container-name-agreement.sh' "$ROOT/build.sh"; then
    check ok "build.sh consults this fixture, which carries the live-tree arm"
else
    check FAIL "build.sh consults this fixture"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: inference-container name agreement ${pass}/${total} (967-6ax6)"
    exit 0
fi
echo "FAIL: inference-container name agreement ${fail}/${total} red (967-6ax6)"
exit 1
