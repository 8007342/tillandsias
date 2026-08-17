#!/usr/bin/env bash
# @trace spec:default-image
#
# test-opencode-render-probe.sh — fixtures for the opencode TUI render
# contract (order 626-p4xd).
#
# THE DEFECT. Every harness gate answered "does the binary start and honour
# our flags?" — `--version`, flag greps, `auth list`. None loaded the
# RENDERER. So a build whose TUI cannot initialize passed every gate, was
# installed, and was recorded as LAST-GOOD; the rollback path then
# re-validated with the same blind probe, so it could restore and certify
# another broken snapshot. The user met the failure; the gate never did.
#
# These fixtures are hermetic: stub binaries, no network, no podman, no real
# opencode. What is under test is the GATE's decision, not opencode.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1

# Extract the functions under test from the shipped library. trace_lifecycle
# is a logging shim here — the fixture asserts on RETURN CODES, not on log
# text, so a reworded trace never turns this red.
sed -n '/^opencode_render_contract_ok()/,/^}/p;/^opencode_render_contract_cached()/,/^}/p' \
    "$ROOT/images/default/lib-common.sh" > funcs.sh
printf 'trace_lifecycle() { printf "[trace] %%s\\n" "$*"; }\n' >> funcs.sh
# shellcheck disable=SC1091
source funcs.sh

export HARNESS_CURL_ROOT="$tmp/curl-root"
# Keep the fixture quick: the production ceiling is 20s to tolerate a cold
# bun single-file extraction, which no stub here performs.
export TILLANDSIAS_RENDER_PROBE_BUDGET_S=5

fail() { echo "FAIL: $*" >&2; exit 1; }

# ── Stub 1: starts, answers flags, NEVER renders ────────────────────────────
# This is the shape that defeated every previous gate: healthy `--version`,
# healthy `auth list`, no renderer.
cat > "$tmp/opencode-blind" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    --version) echo "1.18.10"; exit 0 ;;
esac
# Emits plain text only — no alt-screen, no truecolor SGR — then lingers the
# way a hung TUI would.
echo "starting..."
sleep 30
STUB
chmod +x "$tmp/opencode-blind"

# ── Stub 2: renders ─────────────────────────────────────────────────────────
cat > "$tmp/opencode-good" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    --version) echo "1.18.10"; exit 0 ;;
esac
printf '\033[?1049h'          # alt-screen switch: the renderer marker
printf '\033[38;2;128;128;128mhello\033[0m\n'
sleep 30
STUB
chmod +x "$tmp/opencode-good"

# ── Stub 3: exits immediately (the actual OpenTUI failure shape) ────────────
cat > "$tmp/opencode-crash" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    --version) echo "1.18.10"; exit 0 ;;
esac
echo "Failed to initialize OpenTUI" >&2
exit 1
STUB
chmod +x "$tmp/opencode-crash"

# ── CASE 1: a non-rendering binary is REFUSED ───────────────────────────────
if opencode_render_contract_ok "$tmp/opencode-blind" >/dev/null 2>&1; then
    fail "case1: a binary that never renders passed the render contract"
fi
echo "ok case1: non-rendering binary refused"

# ── CASE 2: a rendering binary PASSES (the control) ─────────────────────────
# Without this, case 1 could pass because the probe rejects everything.
if ! opencode_render_contract_ok "$tmp/opencode-good" >/dev/null 2>&1; then
    fail "case2: a rendering binary was refused — the probe rejects everything"
fi
echo "ok case2: rendering binary accepted (control holds)"

# ── CASE 3: an early nonzero exit is REFUSED, without matching its wording ──
# The probe must not depend on upstream's error string; it refuses because no
# marker appeared before the process died.
if opencode_render_contract_ok "$tmp/opencode-crash" >/dev/null 2>&1; then
    fail "case3: a binary that exits before rendering passed"
fi
echo "ok case3: early-exit binary refused"

# ── CASE 4: the probe does not wait out the full budget on a crash ──────────
# A gate that always burned the ceiling would cost 3x20s per launch. The
# marker loop must notice the process died.
start=$(date +%s)
opencode_render_contract_ok "$tmp/opencode-crash" >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -ge "$TILLANDSIAS_RENDER_PROBE_BUDGET_S" ]; then
    fail "case4: probe burned the whole ${TILLANDSIAS_RENDER_PROBE_BUDGET_S}s budget on a crashed binary (${elapsed}s)"
fi
echo "ok case4: crash detected in ${elapsed}s, well under the ${TILLANDSIAS_RENDER_PROBE_BUDGET_S}s ceiling"

# ── CASE 5: the memo is keyed on the BINARY, not on the name ────────────────
# A reinstall must re-probe — the whole point is gating a NEW artifact. Prime
# the cache with the good binary, then swap in the blind one at the same path
# and require a refusal.
cp "$tmp/opencode-good" "$tmp/opencode-swap"
opencode_render_contract_cached "$tmp/opencode-swap" >/dev/null 2>&1 \
    || fail "case5: good binary refused on first probe"
cp "$tmp/opencode-blind" "$tmp/opencode-swap"
if opencode_render_contract_cached "$tmp/opencode-swap" >/dev/null 2>&1; then
    fail "case5: a swapped-in broken binary was served from the cached verdict"
fi
echo "ok case5: memo re-probes when the binary changes"

# ── CASE 6: the memo actually memoizes (cost control) ───────────────────────
opencode_render_contract_cached "$tmp/opencode-good" >/dev/null 2>&1 \
    || fail "case6: good binary refused"
start=$(date +%s%N)
opencode_render_contract_cached "$tmp/opencode-good" >/dev/null 2>&1 \
    || fail "case6: cached verdict not honoured"
elapsed_ms=$(( ( $(date +%s%N) - start ) / 1000000 ))
if [ "$elapsed_ms" -gt 500 ]; then
    fail "case6: second probe took ${elapsed_ms}ms — memo not used"
fi
echo "ok case6: repeat probe served from memo in ${elapsed_ms}ms"

echo "PASS: opencode render-probe fixture (order 626-p4xd) 6/6"
