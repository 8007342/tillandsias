#!/usr/bin/env bash
# @trace order:1309-qc95, spec:git-mirror-service
#
# test-ssh-lane-refuses-when-unwired.sh — pin that the AUTHENTICATED ssh push
# lane REFUSES when it is enabled but its host-CA cache is absent, instead of
# falling open to the anonymous git:// path.
#
# WHY THIS EXISTS. With TILLANDSIAS_MIRROR_SSHD=1 and no host-CA cache, the lane
# used to print a stderr warning, write "Pushes fall back to the anonymous
# mirror redirect above" into the generated gitconfig, and let the push SUCCEED
# unauthenticated. Loud on stderr, SILENT IN OUTCOME — no gate, hook or reader
# downstream learned the transport had changed. Found 2026-09-20 by dogfooding
# 749-54pv's dark lane as 1288-5qpn's first authenticated client.
#
# WHY OMITTING THE PUSH REDIRECT IS NOT THE FIX, which is the trap the pre-fix
# test fell into by ASSERTING it: the anonymous `insteadOf` written earlier in
# the same function covers PUSH as well as fetch, so an absent push redirect
# means the anonymous path silently wins. Failing closed needs a push redirect
# that CANNOT ROUTE.
#
# THE TEETH. Arm 1 runs the behavioural unit arms. Arm 2 is the MUTATION arm: it
# reintroduces the pre-fix wording into a COPY of the source and requires the
# unit arms to RED against it. A guard that only passes is not a guard.
#
# Verdicts:
#   ok: ssh-lane-refuses-when-unwired PASS
#   FAIL: <arm>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3

SRC="crates/tillandsias-headless/src/main.rs"
[ -f "$SRC" ] || { echo "skip: $SRC absent"; exit 3; }

fail=0
ok()  { echo "  PASS  $1"; }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

echo "arm 1 — the behavioural unit arms pass on the fixed source"
if out="$(cargo test --quiet -p tillandsias-headless --bin tillandsias write_forge_gitconfig 2>&1)"; then
    ok "write_forge_gitconfig arms green"
else
    bad "the gitconfig arms do not pass on the current source:"$'\n'"$out"
fi

echo "arm 2 — MUTATION: reintroducing the fallback must RED the unit arms"
# Mutate a COPY, restore unconditionally. Any exit path must put the tree back:
# a fixture that can leave a mutated source behind is worse than no fixture.
BACKUP="$(mktemp)" || { echo "skip: no tmpfile"; exit 3; }
cp "$SRC" "$BACKUP"
restore() { cp "$BACKUP" "$SRC"; rm -f "$BACKUP"; }
trap restore EXIT INT TERM

# Reintroduce the pre-fix announcement. Built by concatenation so this FIXTURE
# does not itself contain the literal string its own guard forbids — the
# self-matching-instrument shape filed as 1287-myx8.
_pre_fix="Pushes fall ""back to the anonymous mirror redirect"
# CAPTURE THEN TEST (795-imz3). This was `if ! sed -i ...`, which the gate
# refused: under pipefail a negated pipeline can invert the verdict, and the
# arm that decides whether a MUTATION APPLIED is the last place to want an
# inverted verdict — a mutation that silently did not apply would read as a
# passing guard. Hazard shape 3 of 1252-r72q, written here by the person who
# filed that order.
sed -i "s|Pushes REFUSE\. The anonymous mirror redirect above is NOT used in their|${_pre_fix}|" "$SRC"
_mutation_rc=$?
# A zero exit from sed is not proof the text changed — sed succeeds on no match.
# Verify the mutation is PRESENT before drawing any conclusion from the tests.
_mutation_present=1
grep -q "$_pre_fix" "$SRC" || _mutation_present=0
if [ "$_mutation_rc" -ne 0 ] || [ "$_mutation_present" -ne 1 ]; then
    bad "could not apply the mutation (sed rc=$_mutation_rc, present=$_mutation_present) — arm 2 proves nothing and must not read as a pass"
else
    _mutant_out="$(cargo test --quiet -p tillandsias-headless --bin tillandsias write_forge_gitconfig 2>&1)"
    _mutant_rc=$?
    if [ "$_mutant_rc" -eq 0 ]; then
        bad "MUTATION SURVIVED: the pre-fix fallback wording was reintroduced and the unit arms still passed — the guard has no teeth"
    else
        ok "the mutated source REDS, so the guard bites"
    fi
fi
restore
trap - EXIT INT TERM

if [ "$fail" -eq 0 ]; then
    echo "ok: ssh-lane-refuses-when-unwired PASS"
    exit 0
fi
echo "fail: ssh-lane-refuses-when-unwired ($fail arm(s))"
exit 1
