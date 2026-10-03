#!/usr/bin/env bash
# @trace order:1443-z3vb, spec:branch-discipline
#
# test-land-discipline-probe.sh — scripts/land-on-platform-branch.sh asks the
# runtime WHERE to land before any fetch or gate (order 1443-z3vb). Scratch
# projects, each with a copy of the tool and the plan binary on PATH:
#
#   1  level 2 seeded AND observed (this repo's seed; refs that derive level 2),
#      `land main` with an UNREACHABLE origin:
#      refused:land:discipline:default-branch-protected, why:, the seed's
#      remedy ending "use /project-discipline for instructions", exit 9, and
#      no attempt/fetch line (the refusal precedes the network)
#   2  level 0 (no seed), `land main`: land:target:main:from=default:level=0,
#      and it proceeds (the floor is absolute: a bare project's default branch
#      is never refused)
#   3  level 2, on work/1443-z3vb, NO argument (forge platform):
#      land:target:linux-next:from=seed:level=2 and the attempt integrates
#      onto origin/linux-next, not the work ref
#   4  origin publishes refs/tillandsias/discipline/…/<digest>/<epoch> with a
#      digest the checkout lacks: refused:land:discipline:seed-drift naming both
#      digests, exit 9; the SAME digest: land:discipline:mirror-agrees; no ref:
#      land:discipline:mirror-silent; the checkout's OWN seed change ahead of
#      origin: land:discipline:seed-change-in-flight, and it proceeds
#   5  `land feature-x` at level 2: refused:land:discipline:ref-outside-grammar
#   7  a seed AHEAD of reality (level 2 seeded, level 0 observed) warns
#      land:discipline:seed-ahead-of-reality with the missing qualifier and
#      proceeds (operator ruling 4: derive, but check against reality)
#   6  with no plan binary that has the discipline verb, the tool says
#      warn:land:discipline:probe-unavailable and behaves as before
#
# The existing land fixtures (scripts/test-land-*.sh) are the regression arm:
# the gate runs them unchanged.
#
# Pre-fix: FAILS at arm 1 (the tool fetches; the refusal, if any, is the
# remote's after the gate).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/land-discipline-probe.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || { echo "FAIL: no runnable plan binary" >&2; exit 1; }
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac
caps="$("$PLAN" capabilities 2>/dev/null)"
grep -qx discipline <<<"$caps" || { echo "FAIL: $PLAN has no discipline verb (stale artifact)" >&2; exit 1; }
mkdir -p "$W/bin" "$W/nobin"
ln -s "$PLAN" "$W/bin/tillandsias-plan"

# Hermetic git: no global hooks or identity from the host (a forge exports a
# global core.hooksPath and GIT_* identity; neither may reach these repos).
printf '[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n' >"$W/gitconfig"
export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL TILLANDSIAS_TRUNK_BRANCH
SEED_SRC="$ROOT/.tillandsias/branch-discipline.yaml"

# project <dir> <seed:yes|no> <branch> — a committed scratch checkout.
project() {
    git init -q -b "$3" "$1"
    mkdir -p "$1/scripts"
    cp "$ROOT/scripts/land-on-platform-branch.sh" "$1/scripts/"
    if [ "$2" = yes ]; then
        mkdir -p "$1/.tillandsias"
        cp "$SEED_SRC" "$1/.tillandsias/"
    fi
    git -C "$1" add -A && git -C "$1" commit -q -m init
}
# land <dir> <path-dir> [args…] — run the copy there; output to $W/out, rc echoed.
land() {
    local d="$1" pdir="$2"
    shift 2
    (cd "$d" && PATH="$pdir:$PATH" bash scripts/land-on-platform-branch.sh "$@") >"$W/out" 2>&1
    echo $?
}
digest_of() { "$PLAN" json get -r '.digest' <<<"$("$PLAN" discipline show --json --root "$1")"; }

# observed_level2 <dir> — make `discipline derive` OBSERVE level 2, as it does
# in this repository: two committer domains, and an integration branch other
# than the default plus a work ref among origin's refs as of the last fetch.
observed_level2() {
    GIT_AUTHOR_EMAIL=b@hostb.example GIT_COMMITTER_EMAIL=b@hostb.example \
        git -C "$1" commit -q --allow-empty -m "second host"
    for r in linux-next osx-next work/1443-abcd; do
        git -C "$1" update-ref "refs/remotes/origin/$r" HEAD
    done
    git -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/linux-next
}

# ── 7 (before arm 1 makes reality level 2): a seed AHEAD of reality ────────
project "$W/l2" yes linux-next
git -C "$W/l2" remote add origin "$W/nowhere.git"
rc="$(land "$W/l2" "$W/bin" main 1)"
out="$(cat "$W/out")"
if grep -q '^land:discipline:seed-ahead-of-reality — warn:discipline:default-branch-protected:seed-ahead-of-reality' <<<"$out" &&
    grep -q '^  missing: .*integration branch on origin' <<<"$out" && grep -q '^land: attempt 1/1' <<<"$out" &&
    ! grep -q 'refused:land:discipline' <<<"$out"; then
    ok "arm 7: a seed ahead of reality warns (naming the missing qualifier) and proceeds instead of refusing"
else
    bad "arm 7: rc=$rc [$out]"
fi

# ── 1 ───────────────────────────────────────────────────────────────────────
observed_level2 "$W/l2"
rc="$(land "$W/l2" "$W/bin" main 1)"
out="$(cat "$W/out")"
if [ "$rc" = 9 ] && grep -qx 'refused:land:discipline:default-branch-protected' <<<"$out" &&
    grep -q '^  why: ' <<<"$out" && grep -q '^  remedy: push to main denied: .*use /project-discipline for instructions$' <<<"$out" &&
    ! grep -qE 'land: attempt|land:fetch-failed' <<<"$out"; then
    ok "arm 1: level 2 refuses main before any fetch (exit 9, the seed's remedy, the skill named)"
else
    bad "arm 1: rc=$rc [$out]"
fi

# ── 2 ───────────────────────────────────────────────────────────────────────
project "$W/l0" no main
git -C "$W/l0" remote add origin "$W/nowhere.git"
rc="$(land "$W/l0" "$W/bin" main 1)"
out="$(cat "$W/out")"
if grep -qx 'land:target:main:from=default:level=0' <<<"$out" && grep -q '^land: attempt 1/1' <<<"$out" &&
    ! grep -q 'refused:land:discipline' <<<"$out"; then
    ok "arm 2: level 0 lands its default branch unrefused (land:target:main:from=default:level=0, then the attempt)"
else
    bad "arm 2: rc=$rc [$out]"
fi

# ── 3 ───────────────────────────────────────────────────────────────────────
git -C "$W/l2" switch -q -c work/1443-z3vb
rc="$(cd "$W/l2" && TILLANDSIAS_HOST_KIND=forge land "$W/l2" "$W/bin")"
out="$(cat "$W/out")"
if grep -qx 'land:target:linux-next:from=seed:level=2' <<<"$out" &&
    grep -q '^land: attempt 1/4 — fetch + integrate onto origin/linux-next$' <<<"$out" &&
    ! grep -q 'onto origin/work/' <<<"$out"; then
    ok "arm 3: with no argument on a work ref the seed names linux-next, and the attempt integrates onto it"
else
    bad "arm 3: rc=$rc [$out]"
fi
git -C "$W/l2" switch -q linux-next

# ── 4 ───────────────────────────────────────────────────────────────────────
real="$(digest_of "$W/l2")"
fake="$(printf '%064d' 7)"
git init -q --bare "$W/mirror.git"
blob="$(git -C "$W/mirror.git" hash-object -w "$SEED_SRC")"
git -C "$W/l2" remote set-url origin "$W/mirror.git"
git -C "$W/mirror.git" update-ref "refs/tillandsias/discipline/2/enforced/$fake/1700000000" "$blob"
rc="$(land "$W/l2" "$W/bin" linux-next 1)"
out="$(cat "$W/out")"
if [ "$rc" = 9 ] && grep -qx "refused:land:discipline:seed-drift:mirror=$fake:checkout=$real" <<<"$out" &&
    ! grep -q 'land: attempt' <<<"$out"; then
    ok "arm 4: a published digest the checkout lacks is refused:land:discipline:seed-drift naming both, exit 9"
else
    bad "arm 4 drift: rc=$rc [$out]"
fi
git -C "$W/mirror.git" update-ref -d "refs/tillandsias/discipline/2/enforced/$fake/1700000000"
git -C "$W/mirror.git" update-ref "refs/tillandsias/discipline/2/enforced/$real/1700000000" "$blob"
rc="$(land "$W/l2" "$W/bin" linux-next 1)"
out="$(cat "$W/out")"
grep -qx "land:discipline:mirror-agrees:$real" <<<"$out" && grep -q '^land: attempt 1/1' <<<"$out" &&
    ok "arm 4: the same digest reads land:discipline:mirror-agrees and proceeds" || bad "arm 4 agrees: rc=$rc [$out]"
git -C "$W/mirror.git" update-ref -d "refs/tillandsias/discipline/2/enforced/$real/1700000000"
rc="$(land "$W/l2" "$W/bin" linux-next 1)"
out="$(cat "$W/out")"
grep -q '^land:discipline:mirror-silent' <<<"$out" && grep -q '^land: attempt 1/1' <<<"$out" &&
    ok "arm 4: no published ref reads land:discipline:mirror-silent and proceeds" || bad "arm 4 silent: rc=$rc [$out]"
# The checkout's OWN seed change, ahead of origin/linux-next, is not drift.
git -C "$W/l2" push -q origin linux-next
git -C "$W/l2" fetch -q origin
git -C "$W/mirror.git" update-ref "refs/tillandsias/discipline/2/enforced/$real/1700000000" "$blob"
printf '# changed\n' >>"$W/l2/.tillandsias/branch-discipline.yaml"
git -C "$W/l2" commit -q -am "seed change"
rc="$(land "$W/l2" "$W/bin" linux-next 1)"
out="$(cat "$W/out")"
if grep -q "^land:discipline:seed-change-in-flight:mirror=$real:checkout=" <<<"$out" &&
    grep -q '^land: attempt 1/1' <<<"$out" && ! grep -q 'refused:land:discipline' <<<"$out"; then
    ok "arm 4: this checkout's own seed change is land:discipline:seed-change-in-flight, not drift"
else
    bad "arm 4 in-flight: rc=$rc [$out]"
fi

# ── 5 ───────────────────────────────────────────────────────────────────────
git -C "$W/l2" remote set-url origin "$W/nowhere.git"
rc="$(land "$W/l2" "$W/bin" feature-x 1)"
out="$(cat "$W/out")"
[ "$rc" = 9 ] && grep -qx 'refused:land:discipline:ref-outside-grammar' <<<"$out" && ! grep -q 'land: attempt' <<<"$out" &&
    ok "arm 5: a target outside the seed's grammar is refused:land:discipline:ref-outside-grammar" || bad "arm 5: rc=$rc [$out]"

# ── 6 ───────────────────────────────────────────────────────────────────────
printf '#!/bin/sh\necho query\n' >"$W/nobin/tillandsias-plan"
chmod +x "$W/nobin/tillandsias-plan"
rc="$(land "$W/l2" "$W/nobin" main 1)"
out="$(cat "$W/out")"
grep -q '^warn:land:discipline:probe-unavailable' <<<"$out" && grep -q '^land: attempt 1/1 — fetch + integrate onto origin/main$' <<<"$out" &&
    ok "arm 6: with no discipline verb the probe says probe-unavailable and the tool proceeds as before" || bad "arm 6: rc=$rc [$out]"

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: land-discipline-probe $pass/$total (1443-z3vb)"
    exit 0
fi
echo "FAIL: land-discipline-probe $pass/$total (1443-z3vb)"
exit 1
