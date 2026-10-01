#!/usr/bin/env bash
# Negative controls for check-all-fragments-intact.sh (orders 846-idhn,
# 746-htj9). Runs against an external fixture root and never touches plan/.
#
# PORTED to Lua (1527-v7cy): the guard is scripts/lua/check-all-fragments-intact.lua,
# run through the one runner; no runner is a loud skip, never a silent pass.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN_BIN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
if [ -z "$PLAN_BIN" ] || ! grep -qx script <<<"$("$PLAN_BIN" capabilities 2>/dev/null)"; then
    echo "skip:all-fragments-intact-fixture:no-script-runner — no tillandsias-plan with \`script run\` resolves; rebuild it (cargo build --release -p tillandsias-plan)"
    exit 0
fi
SUT="$ROOT/scripts/lua/check-all-fragments-intact.lua"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/all-fragments-intact.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/plan/index.d" "$WORK/bin"

fail() { echo "FAIL: $*" >&2; exit 1; }

# A fake Ruby proves the checker does not trip the forge's on-demand shim.
cat > "$WORK/bin/ruby" <<SH
#!/bin/sh
: > "$WORK/ruby-called"
exit 97
SH
chmod +x "$WORK/bin/ruby"

cat > "$WORK/plan/index.d/good.yaml" <<'YAML'
events:
  - packet_id: fixture
    event:
      type: note
      summary: valid
YAML

out="$(TILLANDSIAS_FRAGMENT_SCAN_ROOT="$WORK" PATH="$WORK/bin:$PATH" "$PLAN_BIN" script run "$SUT" 2>/dev/null)" \
    || fail "valid fixture refused: $out"
[ "$out" = "ok:all-fragments-intact:1 checked" ] \
    || fail "unexpected valid verdict: $out"
[ ! -e "$WORK/ruby-called" ] \
    || fail "checker invoked Ruby instead of the repository validator"
echo "ok: valid YAML uses the repository validator, not Ruby"

cat > "$WORK/plan/index.d/bad.yaml" <<'YAML'
events:
  - packet_id: [
YAML
out="$(TILLANDSIAS_FRAGMENT_SCAN_ROOT="$WORK" "$PLAN_BIN" script run "$SUT" 2>/dev/null)"
rc=$?
[ "$rc" -ne 0 ] || fail "unparseable YAML must be refused"
[ "$out" = "blocked:all-fragments-intact:1 damaged" ] \
    || fail "unexpected parse-failure verdict: $out"
rm "$WORK/plan/index.d/bad.yaml"
echo "ok: unparseable YAML is refused"

cat > "$WORK/plan/index.d/conflict.yaml" <<'YAML'
events:
  - packet_id: fixture
    event:
      type: note
      summary: |
        <<<<<<< ours
        valid YAML, damaged ledger content
        >>>>>>> theirs
YAML
out="$(TILLANDSIAS_FRAGMENT_SCAN_ROOT="$WORK" "$PLAN_BIN" script run "$SUT" 2>/dev/null)"
rc=$?
[ "$rc" -ne 0 ] || fail "an indented conflict marker must be refused"
[ "$out" = "blocked:all-fragments-intact:1 damaged" ] \
    || fail "unexpected conflict-marker verdict: $out"
echo "ok: conflict markers inside valid block scalars are refused"

echo "PASS: all-fragments-intact (3/3)"
