#!/usr/bin/env bash
# @trace order:1446-664f, spec:branch-discipline
#
# Fixture for `tillandsias-plan discipline derive` and the reality check it
# gives `check-ref` (order 1446-664f; operator 2026-09-27: "We should try to
# derive the discipline but check against reality"). Scratch projects with
# scratch bare origins:
#
#   1. one committer, no integration branch, no seed -> derived=0 seed=none
#      effective=0, and check-ref main is ok:discipline:default-branch:level=0;
#   2. a level-2 seed (default_branch enforced) over a project with no
#      integration branch and one committer -> check-ref main WARNS
#      :seed-ahead-of-reality with a remedy naming the missing qualifier, and
#      does not refuse;
#   3. no seed, origin carries linux-next and work/1446-664f, two authors ->
#      derived=2 seed=none and the affordance `discipline raise --to 2; use
#      /project-discipline for instructions`; nothing is refused;
#   4. the two-host scratch project with THIS seed: derived=2 seed=2
#      effective=2, and check-ref main is refused (enforced). THIS repository's
#      main stays refused with source=seed level=2, regardless of live diversity;
#   5. derive --json names every observation with the command that made it.
#
# PRE-FIX RESULT: FAILS at arm 1 — there was no derive verb, and the seed alone
# decided every refusal.
set -uo pipefail
# A forge exports its anonymised identity in these, and they override the
# per-commit identities the arms construct, so every author collapsed into one
# unattributed bucket and arm 3 failed in every forge (measured by
# macuahuitl-forge, 1446-xqi6: 4/5 with them set, 5/5 without).
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; total=5
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

_plan="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac
[ -n "$_plan" ] || { echo "skip:discipline-derive:no-plan-binary — build one: cargo build --release -p tillandsias-plan"; exit 0; }
PLAN="$_plan"
command -v git >/dev/null 2>&1 || { echo "skip:discipline-derive:no-git"; exit 0; }

_tmpbase="${TMPDIR:-/tmp}"
[ ! -d /tmp/opencode ] || _tmpbase=/tmp/opencode
W="$(mktemp -d "$_tmpbase/discipline-derive.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

first() { printf '%s' "${1%%$'\n'*}"; }
g() { git -c init.defaultBranch=main -c user.name=fixture -c user.email="${EMAIL:-one@host-a.test}" -c commit.gpgsign=false "$@"; }

# project <name> -> a clone at $W/<name> of a bare origin with one commit on main.
project() {
    local name="$1"
    g init -q --bare "$W/$name.git"
    g clone -q "$W/$name.git" "$W/$name" 2>/dev/null
    g -C "$W/$name" commit -q --allow-empty -m initial
    g -C "$W/$name" push -q origin main 2>/dev/null
    g -C "$W/$name" remote set-head origin main >/dev/null 2>&1
    g -C "$W/$name" fetch -q origin
}
dis() { "$PLAN" discipline "$@" 2>&1; }

# 1 — a bare one-committer project derives 0 and refuses nothing.
project p1
d1="$(dis derive --root "$W/p1")"
c1="$(dis check-ref refs/heads/main --root "$W/p1")"; rc1=$?
# …and a project that never fetched says so, instead of looking like level 0.
mkdir -p "$W/nofetch"; g -C "$W/nofetch" init -q; g -C "$W/nofetch" commit -q --allow-empty -m x
d1n="$(dis derive --root "$W/nofetch")"
if [ "$(first "$d1")" = "derived=0 seed=none effective=0" ] && [ "$rc1" -eq 0 ] \
   && [ "$(first "$c1")" = "ok:discipline:default-branch:level=0" ] \
   && ! grep -q '^note: no refs/remotes/origin' <<<"$d1" \
   && grep -q '^note: no refs/remotes/origin/\* here' <<<"$d1n"; then
    ok "arm 1: derived=0 seed=none effective=0; main is ok at level 0; a never-fetched project gets the fetch note"
else
    bad "arm 1: derive=[$(first "$d1")] check-ref rc=$rc1 [$(first "$c1")] nofetch=[$d1n]"
fi

# 2 — a seed ahead of reality warns, naming the missing qualifier.
project p2
mkdir -p "$W/p2/.tillandsias"; cp "$ROOT/.tillandsias/branch-discipline.yaml" "$W/p2/.tillandsias/"
c2="$(dis check-ref refs/heads/main --root "$W/p2")"; rc2=$?
if [ "$rc2" -eq 0 ] && [ "$(first "$c2")" = "warn:discipline:default-branch-protected:seed-ahead-of-reality" ] \
   && grep -q '^remedy: .*an integration branch on origin other than the default branch' <<<"$c2"; then
    ok "arm 2: seed 2 over a bare project -> warn :seed-ahead-of-reality naming the missing qualifier, rc 0"
else
    bad "arm 2: rc=$rc2 [$c2]"
fi

# 3 — a project that outgrew its (absent) seed: derived 2, raise affordance, no refusal.
project p3
g -C "$W/p3" push -q origin main:linux-next 2>/dev/null
EMAIL=two@host-b.test g -C "$W/p3" commit -q --allow-empty -m second
g -C "$W/p3" push -q origin HEAD:refs/heads/work/1446-664f 2>/dev/null
g -C "$W/p3" push -q origin HEAD:main 2>/dev/null
g -C "$W/p3" fetch -q origin
d3="$(dis derive --root "$W/p3")"
c3="$(dis check-ref refs/heads/main --root "$W/p3")"; rc3=$?
if [ "$(first "$d3")" = "derived=2 seed=none effective=0" ] \
   && grep -qx 'drift:seed-behind-reality: discipline raise --to 2; use /project-discipline for instructions' <<<"$d3" \
   && [ "$rc3" -eq 0 ]; then
    ok "arm 3: derived=2 seed=none -> raise --to 2 affordance; main not refused"
else
    bad "arm 3: derive=[$d3] check-ref rc=$rc3 [$(first "$c3")]"
fi

# 4 — Seed/reality agreement uses p3's explicit two-host history, never the
# checkout's rolling last-50 window (sole-builder checkpoints can derive 1).
mkdir -p "$W/p3/.tillandsias"; cp "$ROOT/.tillandsias/branch-discipline.yaml" "$W/p3/.tillandsias/"
d4="$(dis derive --root "$W/p3")"
c4="$(dis check-ref refs/heads/main --root "$W/p3")"; rc4=$?
live_main="$(dis check-ref refs/heads/main --root "$ROOT")"; live_rc=$?
if [ "$(first "$d4")" = "derived=2 seed=2 effective=2" ] && [ "$rc4" -eq 1 ] \
   && [ "$(first "$c4")" = "refused:discipline:default-branch-protected:enforced" ] \
   && grep -qx 'source=seed level=2 enforcement=enforced' <<<"$c4" \
   && [ "$live_rc" -eq 1 ] \
   && [ "$(first "$live_main")" = "refused:discipline:default-branch-protected:enforced" ] \
   && grep -qx 'source=seed level=2 enforcement=enforced' <<<"$live_main"; then
    ok "arm 4: two-host scratch derives 2 = seed 2; scratch and live main stay refused (source=seed level=2 enforced)"
else
    bad "arm 4: scratch derive=[$(first "$d4")] check-ref rc=$rc4 [$c4] | live main rc=$live_rc [$live_main]"
fi

# 5 — every observation carries the command that made it.
j5="$("$PLAN" discipline derive --json --root "$W/p3" 2>/dev/null)"
pairs="$(printf '%s\n' "$j5" | "$PLAN" json get -c '.observations[] | [.name, .command]' 2>/dev/null)"
n_obs="$(grep -c '^\["[a-z_]*","\(git \|ls \)' <<<"$pairs")"
n_all="$(grep -c . <<<"$pairs")"
if [ "$n_all" -ge 5 ] && [ "$n_obs" = "$n_all" ] && grep -q '"distinct_committer_hosts","git log -n 50 --format=%ae' <<<"$pairs"; then
    ok "arm 5: derive --json names all $n_all observations with the command that made each"
else
    bad "arm 5: $n_obs/$n_all observations carry a command: [$pairs]"
fi

if [ "$pass" -eq "$total" ]; then
    echo "ok:discipline-derive:$pass/$total"
    exit 0
fi
echo "fail:discipline-derive:$pass/$total"
exit 1
