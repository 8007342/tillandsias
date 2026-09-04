#!/usr/bin/env bash
# @trace order:1003-v3dc
#
# test-spec-index-durable-tier-demotion.sh — pin the two properties 1003-v3dc
# fixes, and pin them on the SHARED BLOCK rather than on a copy of it.
#
# WHAT WENT WRONG, and why a weaker test would not have caught it
#
# The spec index's durable tier is a podman named volume (801-a2by). Rung 3
# tested it with `[ ! -d "$mountpoint" ]`. On a rootless-podman host the
# mountpoint lives under the user's container storage, where stat fails with
# EACCES from OUTSIDE the user namespace — so the test failed for PERMISSION
# and was read as ABSENCE. Every host of that class silently demoted to rung 4,
# which was `target/`, which Start-Of-Day `cargo clean` removes WHOLESALE.
# Measured on lenovinha 2026-09-04: 23,154 embeddings published into a GC
# target, with `--where` reporting serving-exists=yes throughout.
#
# So there are two independent properties, and a test that only checked the
# path would have passed on the old code the day before the data loss:
#
#   1. RUNG 4 IS NOT target/. A cache must not live where a routine GC sweeps.
#   2. NOT-PERMITTED IS DISTINGUISHABLE FROM ABSENT. A volume podman can name
#      but we cannot stat is a DEMOTION and must be reported; a volume podman
#      does not know is simply absent and must stay quiet. Collapsing the two
#      is the original defect, and reporting both loudly would be a new one —
#      a host with no volume at all is not degraded.
#
# HOW: the block is extracted from the real carrier and executed under a STUB
# `podman`, the same technique check-spec-index-resolution-agreement.sh uses.
# Testing a re-implementation of the resolver would prove nothing about the
# resolver — that is the mistake test-yaml-reader-availability made when its
# input came from the tree it was checking.

set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

CARRIER="scripts/spec-index-ensure.sh"
BEGIN_RE='^# >>> BEGIN spec-index resolution (801-a2by)'
END_RE='^# <<< END spec-index resolution (801-a2by)'

work="$(mktemp -d)" || { echo "fail:no-tmpdir"; exit 1; }
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

block="$work/block.sh"
sed -n "/$BEGIN_RE/,/$END_RE/p" "$CARRIER" > "$block"
[ -s "$block" ] || { echo "fail:extractor-returned-empty — markers moved in $CARRIER"; exit 1; }

# A checkout the resolver can discover: it looks for plan/index.yaml upward.
co="$work/checkout"; mkdir -p "$co/plan"; : > "$co/plan/index.yaml"

# _run <podman-behaviour> -> "root|serving|reason|"
# podman-behaviour: a shell snippet that becomes the stub's body.
_run() {
    _pb="$1"
    mkdir -p "$work/bin"
    { echo '#!/bin/sh'; echo "$_pb"; } > "$work/bin/podman"
    chmod +x "$work/bin/podman"
    env -i HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" \
        TILLANDSIAS_SPEC_INDEX_CHECKOUT="$co" \
        TILLANDSIAS_SPEC_INDEX_VOLUME="testvol" \
        sh -c ". '$block'; cd '$co'; _tillandsias_spec_index_paths | tr '\n' '|'"
}

fails=0
_expect() {
    _name="$1"; _got="$2"; _pred="$3"; _why="$4"
    if eval "$_pred"; then echo "PASS  $_name"; else
        echo "FAIL  $_name"; echo "        $_why"; echo "        got: $_got"
        fails=$((fails+1))
    fi
}

# ── 1. Volume EXISTS and is reachable: rung 3 wins, no demotion reported ─────
good="$work/goodvol"; mkdir -p "$good"
out="$(_run "echo '$good'")"
root="${out%%|*}"; reason="$(printf '%s' "$out" | cut -d'|' -f3)"
_expect "reachable volume wins rung 3 with no demotion" "$out" \
    '[ "$root" = "$good" ] && [ -z "$reason" ]' \
    "expected root=$good and an empty reason"

# ── 2. THE REGRESSION: volume podman NAMES but we cannot stat (real EACCES) ──
# A 000 parent makes stat of the child fail with EACCES while the volume very
# much exists — precisely the rootless-podman shape.
denied="$work/denied"; mkdir -p "$denied/vol"; chmod 000 "$denied"
out="$(_run "echo '$denied/vol'")"
root="${out%%|*}"; reason="$(printf '%s' "$out" | cut -d'|' -f3)"
_expect "unreadable volume is a DEMOTION, not an absence" "$out" \
    '[ -n "$reason" ] && [ "$root" != "$denied/vol" ]' \
    "a volume podman named but we cannot stat must set a reason and fall through"
_expect "the demotion reason names the volume" "$out" \
    'case "$reason" in *not-permitted*testvol*) true;; *) false;; esac' \
    "expected a reason mentioning not-permitted and the volume name"
chmod 755 "$denied"

# ── 3. Volume genuinely ABSENT: fall through QUIETLY, no reason ──────────────
# Reporting this as a demotion would be a new defect: a host with no volume is
# not degraded, and a warning it can never act on is noise.
out="$(_run 'exit 1')"
reason="$(printf '%s' "$out" | cut -d'|' -f3)"
_expect "absent volume falls through with NO reason (ENOENT stays quiet)" "$out" \
    '[ -z "$reason" ]' \
    "ENOENT must not be reported as a demotion"

# ── 4. Rung 4 is not target/ — the data-loss half ───────────────────────────
out="$(_run 'exit 1')"
root="${out%%|*}"
_expect "rung 4 does not live under target/ (cargo clean removes it wholesale)" "$out" \
    'case "$root" in */target/*) false;; *) true;; esac' \
    "rung 4 resolved under target/, which Start-Of-Day cargo clean deletes"
_expect "rung 4 is the checkout's .cache/spec-index" "$out" \
    '[ "$root" = "$co/.cache/spec-index" ]' \
    "expected $co/.cache/spec-index"

# ── 5. The block still emits three lines, or --where cannot render a reason ──
out="$(_run 'exit 1')"
n="$(printf '%s' "$out" | awk -F'|' '{print NF-1}')"
_expect "resolver emits root, serving AND reason" "$out" \
    '[ "$n" -eq 3 ]' \
    "expected 3 fields; a missing third line silently disables demotion reporting"

if [ "$fails" -eq 0 ]; then
    echo "ok:test-spec-index-durable-tier-demotion:7-passed"
    exit 0
fi
echo "fail:test-spec-index-durable-tier-demotion:${fails}-failed"
exit 1
