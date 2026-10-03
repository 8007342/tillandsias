#!/usr/bin/env bash
# @trace plan 795-imz3
# Proves that the if-not-pipeline gate behaves correctly.
#
# PORTED to Lua (1525-c6jm): the gate is scripts/lua/check-no-spawn-in-if-not.lua,
# run through the one runner (`script run`); no runner is a loud
# could-not-run, never a silent pass. Scratch moved from an outside-the-repo
# mktemp to target/plan-scratch (1384-ddua's convention) because the guard's
# fs.read is repo-rooted: a fixture file outside the repo and every declared
# read-env root is refused, not read.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
cd "$ROOT"

PLAN_BIN="$(. scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
if [ -z "$PLAN_BIN" ] || ! grep -qx script <<<"$("$PLAN_BIN" capabilities 2>/dev/null)"; then
    echo "skip:if-not-pipeline-guard:no-script-runner — no tillandsias-plan with \`script run\` resolves; rebuild it (cargo build --release -p tillandsias-plan)"
    exit 0
fi
CHECK="$ROOT/scripts/lua/check-no-spawn-in-if-not.lua"

mkdir -p target/plan-scratch
WORK="$(mktemp -d "$ROOT/target/plan-scratch/if-not-pipeline-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail_fixture="$WORK/fail_fixture.sh"
echo '#!/usr/bin/env bash' > "$fail_fixture"
echo 'if ! printf "%s" "foo" | grep -q "foo"; then' >> "$fail_fixture"
echo '    exit 1' >> "$fail_fixture"
echo 'fi' >> "$fail_fixture"
chmod +x "$fail_fixture"

pass_fixture1="$WORK/pass_fixture1.sh"
echo '#!/usr/bin/env bash' > "$pass_fixture1"
echo 'if ! grep -q "foo" <<<"foo"; then' >> "$pass_fixture1"
echo '    exit 1' >> "$pass_fixture1"
echo 'fi' >> "$pass_fixture1"
chmod +x "$pass_fixture1"

pass_fixture2="$WORK/pass_fixture2.sh"
echo '#!/usr/bin/env bash' > "$pass_fixture2"
echo 'case $'"'\n'foo'\n'"' in' >> "$pass_fixture2"
echo '    *$'"'\n'foo'\n'"'*) ;;' >> "$pass_fixture2"
echo '    *) exit 1 ;;' >> "$pass_fixture2"
echo 'esac' >> "$pass_fixture2"
chmod +x "$pass_fixture2"

# 1. Pipeline fixture must FAIL
if "$PLAN_BIN" script run "$CHECK" -- "$fail_fixture" >/dev/null 2>&1; then
    echo "violation:if-not-pipeline-guard: failed to refuse pipeline" >&2
    exit 1
fi

# 2. Bare command fixture must PASS
if ! "$PLAN_BIN" script run "$CHECK" -- "$pass_fixture1" >/dev/null 2>&1; then
    echo "violation:if-not-pipeline-guard: refused bare command" >&2
    exit 1
fi

# 3. Case idiom fixture must PASS
if ! "$PLAN_BIN" script run "$CHECK" -- "$pass_fixture2" >/dev/null 2>&1; then
    echo "violation:if-not-pipeline-guard: refused case idiom" >&2
    exit 1
fi

echo "ok:if-not-pipeline-guard-shape:3"
exit 0
