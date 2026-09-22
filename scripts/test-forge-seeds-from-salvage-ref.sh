#!/usr/bin/env bash
# Order 1350-8hmy. A forge seeded from a `salvage/*` ref must CONTAIN that
# ref's content.
#
# WHY A SENTINEL AND NOT AN EXIT STATUS. checkout_forge_seed_branch() is
# fail-soft by contract (B6, images/default/lib-common.sh): a seed branch that
# is missing, unresolvable, or that `git switch` refuses leaves the clone on
# its own HEAD, prints a WARNING, and RETURNS 0. Every failure this fixture
# exists to catch is therefore invisible to `$?`. The assertion is a file
# placed on the salvage ref and read back out of the seeded tree, with its
# CONTENT compared -- the next named checkpoint past the seed, never the
# absence of an error.
#
# Hermetic and offline: a bare repo stands in for the mirror and the real
# function is awk-extracted from lib-common.sh, the idiom
# litmus-forge-clone-reachability-probe-shape.yaml already uses on
# probe_mirror_reachable (the file cannot be sourced whole on a host).
set -uo pipefail

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

ROOT="$(git rev-parse --show-toplevel)"
LIB="$ROOT/images/default/lib-common.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB not present"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TOKEN="salvage-sentinel-1350-8hmy-$$"
SALVAGE="salvage/1350-8hmy-rescue"
TRUNK="linux-next"

# ── THE MIRROR ───────────────────────────────────────────────────────────────
# Trunk plus a salvage ref carrying the sentinel. The mirror's HEAD stays on
# trunk, which is the sticky-symref case the seed pin exists for: a fresh clone
# lands on trunk and the salvage content is reachable but NOT checked out.
MIRROR="$TMP/mirror.git"
SEEDSRC="$TMP/seedsrc"
git init -q "$SEEDSRC"
git -C "$SEEDSRC" config user.email s@s; git -C "$SEEDSRC" config user.name s
git -C "$SEEDSRC" config commit.gpgsign false
git -C "$SEEDSRC" checkout -q -b "$TRUNK"
echo trunk > "$SEEDSRC/trunk.txt"
git -C "$SEEDSRC" add -A; git -C "$SEEDSRC" commit -qm trunk
git -C "$SEEDSRC" checkout -q -b "$SALVAGE"
printf '%s\n' "$TOKEN" > "$SEEDSRC/SENTINEL.txt"
git -C "$SEEDSRC" add -A; git -C "$SEEDSRC" commit -qm 'salvage: the rescued work'
git -C "$SEEDSRC" checkout -q "$TRUNK"
git clone -q --bare "$SEEDSRC" "$MIRROR"
git -C "$MIRROR" symbolic-ref HEAD "refs/heads/$TRUNK"

# fresh_clone -- a forge's clone of the mirror, before any seed pin is applied.
fresh_clone() {
    local d="$1"
    git clone -q "$MIRROR" "$d"
    git -C "$d" config user.email f@f; git -C "$d" config user.name f
    git -C "$d" config commit.gpgsign false
}

# run_seed <clone-dir> <seed-or-empty> -- evaluate the REAL function in the
# clone, exactly as the forge does at startup. stdout+stderr captured; rc kept
# but deliberately never used as the pass criterion.
run_seed() {
    local d="$1" seed="$2"
    ( cd "$d" \
      && trace_lifecycle() { :; } \
      && eval "$(awk '/^checkout_forge_seed_branch\(\) \{/,/^\}/' "$LIB")" \
      && TILLANDSIAS_FORGE_SEED_BRANCH="$seed" checkout_forge_seed_branch ) 2>&1
}

# ── ARM 1: THE PREMISE ───────────────────────────────────────────────────────
# A GUARD FED ITS OWN SUBJECT CANNOT FAIL. If the sentinel were already in the
# tree a fresh clone hands back, arm 2 would be green however badly the seed
# behaved -- it would assert the fixture's own scaffolding. So the broken world
# is asserted first: the clone starts on trunk WITHOUT the sentinel.
C1="$TMP/c1"; fresh_clone "$C1"
if [ -e "$C1/SENTINEL.txt" ]; then
    bad "ARM 1 (premise): a fresh clone already carries SENTINEL.txt — arm 2 would be green by construction and this fixture proves nothing"
elif [ "$(git -C "$C1" symbolic-ref --short -q HEAD)" != "$TRUNK" ]; then
    bad "ARM 1 (premise): a fresh clone did not land on $TRUNK — the sticky-HEAD scenario this fixture models is not set up"
else
    ok "ARM 1 (premise): a fresh clone of the mirror is on $TRUNK and does NOT contain the sentinel — the salvage content is reachable but not checked out"
fi

# ── ARM 2: THE ASSERTION ─────────────────────────────────────────────────────
out2="$(run_seed "$C1" "$SALVAGE")"; rc2=$?
if [ ! -f "$C1/SENTINEL.txt" ]; then
    bad "ARM 2: the forge seeded from '$SALVAGE' does NOT contain that ref's content (SENTINEL.txt absent). The seed returned rc=$rc2 — which is 0 on every failure path by contract, so the status never said so:
$(printf '%s' "$out2" | tail -3)"
else
    got2="$(cat "$C1/SENTINEL.txt")"
    if [ "$got2" = "$TOKEN" ]; then
        ok "ARM 2: a forge seeded from a salvage/* ref CONTAINS that ref's content (SENTINEL.txt = $TOKEN), asserted in the seeded tree and not by an exit status"
    else
        bad "ARM 2: SENTINEL.txt is present but carries '$got2', not '$TOKEN' — the tree was seeded from the wrong ref"
    fi
fi

# ── ARM 3: A SLASHED REF IS THE POINT ────────────────────────────────────────
# `salvage/<order>` contains a slash; `work/<order>` and the trunk do not. The
# switch DWIMs a local branch from origin/<seed>, and a slashed name is the
# case most likely to be mishandled by a refname assembled with string
# concatenation. Asserting HEAD by NAME here (not the sentinel) because the
# distinct failure is landing on a differently-named ref that happens to carry
# the same content.
head3="$(git -C "$C1" symbolic-ref --short -q HEAD || echo '<detached>')"
if [ "$head3" = "$SALVAGE" ]; then
    ok "ARM 3: HEAD is the slashed ref '$SALVAGE' itself, not a flattened or detached approximation of it"
else
    bad "ARM 3: the tree may hold the content but HEAD is '$head3', not '$SALVAGE' — work committed here does not land on the salvage ref"
fi

# ── ARM 4: FAIL-SOFT IS PRESERVED (B6) ───────────────────────────────────────
# The complement, and it is what stops arm 2 being satisfied by "hard-fail
# unless the seed resolves". A never-pushed seed must NOT hard-fail the launch:
# it stays on the clone's HEAD, says so LOUDLY, and returns 0.
C4="$TMP/c4"; fresh_clone "$C4"
out4="$(run_seed "$C4" "salvage/never-pushed-9999-zzzz")"; rc4=$?
head4="$(git -C "$C4" symbolic-ref --short -q HEAD || echo '<detached>')"
# Matched with `case`, not `printf | grep -q`: grep -q exits on its FIRST match,
# the producer dies 141, and under pipefail the pipeline's status is 141 WITH
# the pattern present -- a verdict guard that inverts exactly when it matters
# (795-imz3, 1307-ermc).
warned4=0
case "$out4" in *WARNING*) warned4=1 ;; esac
if [ "$rc4" -ne 0 ]; then
    bad "ARM 4: a never-pushed seed hard-failed (rc=$rc4) — B6 forbids this; it DOAs a launch inside the mirror's reconcile window"
elif [ "$head4" != "$TRUNK" ]; then
    bad "ARM 4: a never-pushed seed left HEAD on '$head4' instead of the clone's own '$TRUNK'"
elif [ "$warned4" -ne 1 ]; then
    bad "ARM 4: a never-pushed seed was silent — it fell back to '$TRUNK' with nothing in the log, and a silent fallback is indistinguishable from a successful seed"
else
    ok "ARM 4: a never-pushed seed stays on '$TRUNK', warns LOUDLY, and returns 0 — fail-soft (B6) survives"
fi

# ── ARM 5: AN UNSET SEED IS A NO-OP ──────────────────────────────────────────
C5="$TMP/c5"; fresh_clone "$C5"
out5="$(run_seed "$C5" "")"; rc5=$?
head5="$(git -C "$C5" symbolic-ref --short -q HEAD || echo '<detached>')"
if [ "$rc5" -eq 0 ] && [ "$head5" = "$TRUNK" ] && [ -z "$out5" ]; then
    ok "ARM 5: an empty seed is byte-identical to the pre-501 path — no switch, no output, rc=0"
else
    bad "ARM 5: an empty seed was not a no-op (rc=$rc5 head=$head5 out='$out5') — end-user transparency is lost"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    echo "ok:forge-seeds-from-salvage-ref:$pass/$pass"
    exit 0
fi
echo "blocked:forge-seeds-from-salvage-ref:$fail-failed-of-$((pass + fail))"
exit 1
