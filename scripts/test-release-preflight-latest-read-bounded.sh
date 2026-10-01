#!/usr/bin/env bash
# @trace order:1523-rxt6, spec:ci-release
#
# test-release-preflight-latest-read-bounded.sh — release-preflight.sh's
# stable-vs-latest check reads the latest release tag ANONYMOUSLY and BOUNDED,
# so a host whose login keyring is locked cannot stall it. It used `gh api`,
# which waits ~120 s on a locked keyring (lenovinha 120,422 ms, macuahuitl
# 127 s, 2026-10-01) and timed out litmus release-gates-run-locally STEP 1.
#
# Arms:
#   1 BOUNDED   gh and curl both stubbed to sleep 300 s: the script finishes in
#               under 40 s, names the read as could-not-run, and never calls gh
#   2 READS     curl stubbed to return {"tag_name":"v0.0.0.fixture"}: the tag
#               reaches the comparison (the "no peeled tag" note names it).
#               Needs origin reachable for refs/tags/stable; a named skip if not.
#
# PRE-FIX: arm 1 FAILS — the script calls the gh stub and is still running at
# the 40 s bound.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

PLAN="$(. scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || PLAN=""
case "$PLAN" in ./*) PLAN="$ROOT/${PLAN#./}" ;; esac
if [ -z "$PLAN" ]; then
    echo "could-not-run:release-preflight-latest-read-bounded:no-plan-binary — cargo build --release -p tillandsias-plan"
    exit 3
fi
mkdir -p target/plan-scratch
W="$(mktemp -d "$ROOT/target/plan-scratch/relpf-latest.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT INT TERM

# ── ARM 1: BOUNDED ─────────────────────────────────────────────────────────
mkdir -p "$W/bin1"
printf '#!/usr/bin/env bash\ntouch "%s/gh-called"\nsleep 300\n' "$W" > "$W/bin1/gh"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$W/bin1/curl"
chmod +x "$W/bin1/gh" "$W/bin1/curl"
s=$SECONDS
out1="$(PATH="$W/bin1:$PATH" TILLANDSIAS_PLAN_BIN="$PLAN" "$PLAN" run --timeout-ms 40000 -- bash scripts/release-preflight.sh --verbose 2>&1)"
rc1=$?
took=$((SECONDS - s))
a1=""
[ "$rc1" -ne 124 ] || a1="$a1 still running at the 40 s bound (rc=124);"
[ ! -e "$W/gh-called" ] || a1="$a1 gh was called;"
grep -q 'stable-vs-latest: could not read refs/tags/stable' <<<"$out1" \
    || grep -q 'bounded read timed out' <<<"$out1" \
    || a1="$a1 no could-not-run note for the latest read;"
if [ -z "$a1" ]; then
    ok "ARM 1: a hung gh and curl cannot stall it (${took}s, gh never called)"
else
    bad "ARM 1:$a1 took=${took}s"
fi

# ── ARM 2: READS ───────────────────────────────────────────────────────────
mkdir -p "$W/bin2"
printf '#!/usr/bin/env bash\nprintf %%s %s\n' "'{\"tag_name\":\"v0.0.0.fixture\"}'" > "$W/bin2/curl"
chmod +x "$W/bin2/curl"
out2="$(PATH="$W/bin2:$PATH" TILLANDSIAS_PLAN_BIN="$PLAN" "$PLAN" run --timeout-ms 60000 -- bash scripts/release-preflight.sh --verbose 2>&1)"
if grep -q 'could not read refs/tags/stable' <<<"$out2"; then
    echo "skip: ARM 2 — origin unreachable for refs/tags/stable, so the latest read is never asked"
elif grep -q 'no peeled tag for v0.0.0.fixture' <<<"$out2"; then
    ok "ARM 2: the anonymous read's tag reaches the stable-vs-latest comparison"
else
    bad "ARM 2: the stubbed tag never reached the comparison: $(grep 'stable-vs-latest' <<<"$out2" | head -2)"
fi

echo "release-preflight-latest-read-bounded: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
