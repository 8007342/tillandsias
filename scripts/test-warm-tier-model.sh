#!/usr/bin/env bash
# @trace order:965-hz3f, spec:inference-container
# test-warm-tier-model.sh — fixture proof for the tier-model warm selection.
#
# The selection is a PURE function fed the accel class and the models the
# endpoint actually reports, so every branch is provable without an endpoint,
# an accelerator, or a forge. That is the whole reason it was written as a
# separate function rather than inline in warm_tier_model_fail_soft.
#
# Branches:
#   1. GPU lanes prefer the model that satisfies the citation contract (14b)
#   2. ...but only among models PRESENT: a GPU host with just 7b warms 7b
#   3. CPU floor prefers the small default, never a multi-GB model
#   4. Nothing present -> no candidate, non-zero (caller reports skipped)
#   5. An unknown accel class falls to the CPU floor, never to the GPU order
#   6. The CPU floor is 0.5b-first and never selects 7b
#   7. The selection is EXPORTED to expert-serve (the warmed model is the
#      model that serves), and an operator TILLANDSIAS_INFERENCE_MODEL wins
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${WARM_TEST_LIB:-$ROOT/images/default/lib-common.sh}"
fail=0

# lib-common.sh hard-fails at source time outside the forge image (vendor CA
# bundle), so extract the pure function rather than sourcing the file — the
# same constraint that put the inference probe in its own lib.
fn="$(sed -n '/^_tillandsias_select_warm_model() {$/,/^}$/p' "$LIB")"
[ -n "$fn" ] || { echo "FAIL: could not extract _tillandsias_select_warm_model from $LIB" >&2; exit 1; }
eval "$fn"

check() {
    local name="$1" class="$2" avail="$3" want="$4" want_rc="$5" got rc
    got="$(_tillandsias_select_warm_model "$class" "$avail")" && rc=0 || rc=$?
    if [ "$got" = "$want" ] && [ "$rc" = "$want_rc" ]; then
        echo "ok: $name (${got:-<none>} rc=$rc)"
    else
        echo "FAIL: $name expected '${want:-<none>}' rc=$want_rc, got '${got:-<none>}' rc=$rc" >&2
        fail=1
    fi
}

ALL="qwen2.5:0.5b,qwen2.5:3b,qwen2.5:7b,qwen2.5:14b,nomic-embed-text:latest"

check "gpu-prefers-14b"            workstation-gpu  "$ALL" "qwen2.5:14b" 0
check "hybrid-prefers-14b"         hybrid-gpu-npu   "$ALL" "qwen2.5:14b" 0
check "gpu-without-14b-takes-7b"   workstation-gpu  "qwen2.5:3b,qwen2.5:7b" "qwen2.5:7b" 0
check "gpu-with-only-3b-takes-3b"  workstation-gpu  "qwen2.5:3b" "qwen2.5:3b" 0
check "cpu-floor-prefers-0.5b"     cpu-only         "$ALL" "qwen2.5:0.5b" 0
check "mobile-npu-uses-cpu-floor"  mobile-npu       "$ALL" "qwen2.5:0.5b" 0
check "unknown-class-uses-floor"   ""               "$ALL" "qwen2.5:0.5b" 0
check "no-candidate-is-nonzero"    workstation-gpu  "nomic-embed-text:latest" "" 1
check "empty-inventory-is-nonzero" workstation-gpu  "" "" 1

# THE ONE THAT MATTERS FOR THE CPU FLOOR: a 14b must never be selected on a
# host that cannot serve it inside a tier budget, even though it is present.
got="$(_tillandsias_select_warm_model cpu-only "$ALL")"
if [ "$got" = "qwen2.5:14b" ]; then
    echo "FAIL: cpu-only selected a 14b — the floor must not warm a model it cannot serve" >&2
    fail=1
else
    echo "ok: cpu-only never selects 14b even when present (got $got)"
fi

# Substring safety: a model whose name CONTAINS a candidate must not match it.
check "no-substring-false-match" workstation-gpu "notqwen2.5:14bx" "" 1

# The CPU floor never selects 7b either: a 16GB-RAM CPU host's inference
# container background-pulls T2 (qwen2.5:7b), and the selection is now also
# the SERVING model, so picking it would put a multi-GB model behind every
# Quick-tier query on a host that cannot answer inside the budget.
check "cpu-floor-never-7b" cpu-only "qwen2.5:7b,nomic-embed-text:latest" "" 1

# ── THE TRANSFER: the warmed model is the model expert-serve uses ─────────
# expert-serve synthesises with TILLANDSIAS_INFERENCE_MODEL, defaulting to
# qwen2.5:0.5b. Pre-fix, the warm selected and loaded 14b on a GPU lane but
# exported nothing, so the server answered with a cold 0.5b. Drive the real
# warm function against a stubbed endpoint and assert the selection reaches
# the environment start_expert_serve_fail_soft inherits.
wfn="$(sed -n '/^warm_tier_model_fail_soft() {$/,/^}$/p' "$LIB")"
[ -n "$wfn" ] || { echo "FAIL: could not extract warm_tier_model_fail_soft from $LIB" >&2; exit 1; }
eval "$wfn"
STATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/warm-tier-model.XXXXXX")"
trap 'rm -rf "$STATE_TMP"' EXIT
curl() {
    case "$*" in
        */api/tags*) printf '{"models":[{"name":"qwen2.5:0.5b"},{"name":"qwen2.5:7b"},{"name":"qwen2.5:14b"}]}\n' ;;
        */v1/chat/completions*) return 0 ;;
        *) return 7 ;;
    esac
}
transfer() {
    local name="$1" envelope="$2" preset="$3" want="$4" got
    got="$(
        unset TILLANDSIAS_INFERENCE_MODEL
        if [ -n "$preset" ]; then export TILLANDSIAS_INFERENCE_MODEL="$preset"; fi
        export FORGE_EXPERTS_STATE_DIR="$STATE_TMP" TILLANDSIAS_ACCEL_ENVELOPE="$envelope"
        export TILLANDSIAS_INFERENCE_ENDPOINT="http://stub:11434/v1"
        warm_tier_model_fail_soft >/dev/null 2>&1
        printf '%s' "${TILLANDSIAS_INFERENCE_MODEL:-<unset>}"
    )"
    if [ "$got" = "$want" ]; then
        echo "ok: $name (serving model $got)"
    else
        echo "FAIL: $name expected serving model '$want', got '$got' — the warm did not reach expert-serve" >&2
        fail=1
    fi
}
transfer "gpu-warm-exports-14b"        "accel_class=workstation-gpu" ""           "qwen2.5:14b"
transfer "cpu-warm-exports-0.5b"       "accel_class=cpu-only"        ""           "qwen2.5:0.5b"
transfer "operator-model-is-preserved" "accel_class=workstation-gpu" "qwen2.5:7b" "qwen2.5:7b"

# The export reaches expert-serve only if the lane calls the warm in the SAME
# shell (not a subshell or $(...)) and BEFORE start_expert_serve_fail_soft.
warm_ln="$(grep -n '^        warm_tier_model_fail_soft >>/tmp/forge-lifecycle.log 2>&1 || true$' "$LIB" | cut -d: -f1 || true)"
serve_ln="$(grep -n '^        start_expert_serve_fail_soft >>/tmp/forge-lifecycle.log 2>&1 || true$' "$LIB" | cut -d: -f1 || true)"
if [ -n "$warm_ln" ] && [ -n "$serve_ln" ] && [ "$warm_ln" -lt "$serve_ln" ]; then
    echo "ok: lifecycle lane warms in-shell before expert-serve (lines $warm_ln < $serve_ln)"
else
    echo "FAIL: the lane must call warm_tier_model_fail_soft in-shell before start_expert_serve_fail_soft (warm=${warm_ln:-missing} serve=${serve_ln:-missing})" >&2
    fail=1
fi

[ "$fail" -eq 0 ] || { echo "test-warm-tier-model: FAILED" >&2; exit 1; }
echo "ok:warm-tier-model-select:16"
echo "PASS: test-warm-tier-model all branches proven"
