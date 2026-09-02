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
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
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
check "cpu-floor-prefers-3b"       cpu-only         "$ALL" "qwen2.5:3b" 0
check "mobile-npu-uses-cpu-floor"  mobile-npu       "$ALL" "qwen2.5:3b" 0
check "unknown-class-uses-floor"   ""               "$ALL" "qwen2.5:3b" 0
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

[ "$fail" -eq 0 ] || { echo "test-warm-tier-model: FAILED" >&2; exit 1; }
echo "ok:warm-tier-model-select:11"
echo "PASS: test-warm-tier-model all branches proven"
