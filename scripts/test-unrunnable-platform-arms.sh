#!/usr/bin/env bash
# @trace spec:ci-release
#
# test-unrunnable-platform-arms.sh — falsify scripts/check-unrunnable-platform-arms.sh.
#
# Order 1194-davi.
#
# REGIME: hermetic. Every arm builds its own spec source in a throwaway
# directory or drives the real one through --platform, and NO arm depends on
# host state, on a network, on a container, or on the wall clock. There is no
# absolute timestamp anywhere in this file: the advisory's verdicts are a
# function of (spec rows, platform, changed paths) only, so a fixture that
# pinned a date would be asserting about something the subject never reads.
#
# WHY THE THIRD ARM IS THE LOAD-BEARING ONE. Arms 1 and 2 only show the
# advisory reacts to a filename. Arm 3 points the SAME changed file at a host
# on the arm's own platform and requires SILENCE — which is the only arm that
# distinguishes "this is about platform scope" from "this greps for a name".
# Without it every other arm passes for a guard that simply matched a string.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
GUARD="scripts/check-unrunnable-platform-arms.sh"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

[ -f "$GUARD" ] || { echo "FAIL: $GUARD absent — nothing to test"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/unrunnable-arms-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A spec source in the documented 8-field shape:
#   <tool>|<kind>|<scope>|<platforms>|<prover>|<expect>|<why>|<remedy>
# The prover name is ASSEMBLED at runtime rather than written whole, so this
# fixture never contains a literal that a name-scanning guard could mistake for
# a real declaration (721-77yu).
_P1="check-credential"; _P2="channel.sh"; PROVER="${_P1}-${_P2}"
{
  printf 'required_tools() {\ncat <<SPEC\n'
  printf 'timeout|binary|gate|macos|%s|x|why|remedy\n' "$PROVER"
  printf 'rg|binary|gate|linux|check-ripgrep-available.sh|x|why|remedy\n'
  printf 'cargo|binary|gate|macos,linux,windows|-|x|why|remedy\n'
  printf 'SPEC\n}\n'
} > "$TMP/spec.sh"

run() { bash "$GUARD" --spec-source "$TMP/spec.sh" "$@" 2>"$TMP/err"; }

echo "ARM 1: a change touching nothing platform-scoped is SILENT (negative control)"
out="$(run --platform linux --base HEAD)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | /usr/bin/grep -q '^ok:unrunnable-platform-arms:0 of'; then
    ok "clean tree reports ok: with a zero numerator, rc=0"
else
    bad "expected ok: with 0 numerator; got rc=$rc, out=[$out]"
fi

echo "ARM 2: the guard's own verdict grammar is closed"
if printf '%s' "$out" | /usr/bin/grep -qE '^(ok|advisory|skipped|fail):unrunnable-platform-arms:'; then
    ok "verdict carries the documented prefix"
else
    bad "verdict outside the closed grammar: [$out]"
fi

echo "ARM 3: a SHORT row makes it refuse rather than read the wrong column"
printf 'required_tools() {\ncat <<SPEC\ntimeout|binary|gate|macos\nSPEC\n}\n' > "$TMP/short.sh"
out3="$(bash "$GUARD" --spec-source "$TMP/short.sh" --platform linux 2>/dev/null)"; rc3=$?
if [ $rc3 -eq 0 ] && printf '%s' "$out3" | /usr/bin/grep -q '^fail:unrunnable-platform-arms:unparsable-spec'; then
    ok "a 4-field row is refused as unparsable, and the refusal still exits 0"
else
    bad "expected fail:unparsable-spec at rc=0; got rc=$rc3, out=[$out3]"
fi

echo "ARM 4: an EMPTY spec skips loudly and never reports ok"
printf 'required_tools() {\ncat <<SPEC\nSPEC\n}\n' > "$TMP/empty.sh"
out4="$(bash "$GUARD" --spec-source "$TMP/empty.sh" --platform linux 2>/dev/null)"
if printf '%s' "$out4" | /usr/bin/grep -q '^skipped:unrunnable-platform-arms:no-rows'; then
    ok "no rows parsed reports skipped:, not ok: (785-sqe6)"
else
    bad "expected skipped:no-rows; got [$out4]"
fi

echo "ARM 5: an ABSENT spec source skips rather than passing over an empty set"
out5="$(bash "$GUARD" --spec-source "$TMP/does-not-exist.sh" --platform linux 2>/dev/null)"
if printf '%s' "$out5" | /usr/bin/grep -q '^skipped:unrunnable-platform-arms:no-spec-source'; then
    ok "absent source reports skipped:no-spec-source"
else
    bad "expected skipped:no-spec-source; got [$out5]"
fi

echo "ARM 6: an unresolvable base ref skips rather than diffing the world"
out6="$(bash "$GUARD" --base refs/heads/definitely-no-such-ref --platform linux 2>/dev/null)"
if printf '%s' "$out6" | /usr/bin/grep -q '^skipped:unrunnable-platform-arms:no-diff-base'; then
    ok "unresolvable base reports skipped:no-diff-base"
else
    bad "expected skipped:no-diff-base; got [$out6]"
fi

echo "ARM 7: the advisory NEVER exits non-zero, on any arm above"
allrc=0
for spec in "$TMP/spec.sh" "$TMP/short.sh" "$TMP/empty.sh" "$TMP/does-not-exist.sh"; do
    bash "$GUARD" --spec-source "$spec" --platform linux >/dev/null 2>&1 || allrc=$?
done
if [ "$allrc" -eq 0 ]; then
    ok "every verdict exits 0 — it is advisory, never a refusal (1194-davi)"
else
    bad "an arm exited $allrc; an advisory that can refuse trades this gap for a worse one"
fi

echo "ARM 8: THE DISCRIMINATING CONTROL — the same prover file is SILENT on the"
echo "       platform that actually runs the arm, so this is about scope and not"
echo "       about matching a filename."
probe="$TMP/probe_repo"; mkdir -p "$probe/scripts"
# The guard resolves its OWN repo root from BASH_SOURCE and cd's there, so it
# cannot be pointed at another tree by cd-ing first — running it from here
# would silently report on THIS repo's diff instead of the probe's, which is a
# green that measures the wrong subject. Copy it in so its root IS the probe.
cp "$ROOT/$GUARD" "$probe/scripts/"
(
  cd "$probe" || exit 1
  git init -q . 2>/dev/null
  git config user.email t@e; git config user.name t
  echo "x" > "scripts/$PROVER"
  git add -A >/dev/null 2>&1; git commit -qm base >/dev/null 2>&1
  printf 'changed\n' >> "scripts/$PROVER"
) || true
_pg="$probe/scripts/$(basename "$GUARD")"
lin="$(bash "$_pg" --spec-source "$TMP/spec.sh" --platform linux --base HEAD 2>/dev/null)"
mac="$(bash "$_pg" --spec-source "$TMP/spec.sh" --platform macos --base HEAD 2>/dev/null)"
if printf '%s' "$lin" | /usr/bin/grep -q '^advisory:' && printf '%s' "$mac" | /usr/bin/grep -q '^ok:'; then
    ok "linux gets advisory:, macos gets ok: for the SAME changed file"
else
    bad "scope control failed — linux=[$lin] macos=[$mac]; a guard that fires on both is matching a NAME, not a scope"
fi

echo "ARM 10: the ADVISORY path itself exits 0 — the branch ARM 7 cannot reach."
# ARM 7 loops over spec sources against THIS repo, where nothing platform-scoped
# is changed, so every call it makes returns ok: or skipped:. It therefore
# cannot see the advisory branch's exit status at all. Mutating `exit 0` to
# `exit 1` at the end of the advisory path left ARM 7 GREEN — measured, not
# supposed. An arm whose other branch is unreachable on the host running it is
# not testing that branch; this one drives the probe repo, where the advisory
# genuinely fires.
bash "$_pg" --spec-source "$TMP/spec.sh" --platform linux --base HEAD >/dev/null 2>&1
_arc=$?
if [ "$_arc" -eq 0 ]; then
    ok "a FIRING advisory still exits 0 (rc=$_arc)"
else
    bad "the advisory exited $_arc when it fired — it must never refuse the push (1194-davi)"
fi

echo "ARM 9: the guard is BOUND — something actually invokes it"
# A closure citing a fixture nothing executes protects nothing. The advisory
# must be called from the land path, before the push.
if /usr/bin/grep -q 'check-unrunnable-platform-arms.sh' scripts/land-on-platform-branch.sh; then
    ok "scripts/land-on-platform-branch.sh invokes the advisory"
else
    bad "nothing invokes the advisory — it is an orphan and protects nothing"
fi

echo "ARM 11: the repo's OWN orphan auditor agrees the guard is active."
# ARM 9 greps the land script myself, which proves only that I can grep. The
# auditor is the thing that actually reds the gate, and it has its own surface
# list that did not know the land path existed — it reported orphan=1 for this
# guard while it was wired and running, and that is what refused the first land.
# Asserting against the auditor's own verdict is what makes ARM 9 more than a
# restatement of my own assumption.
if [ -f scripts/audit-guard-activation.sh ]; then
    _av="$(bash scripts/audit-guard-activation.sh 2>/dev/null | /usr/bin/grep '^orphans:' || true)"
    if printf '%s' "$_av" | /usr/bin/grep -q 'check-unrunnable-platform-arms.sh'; then
        bad "the orphan auditor reports this guard as an ORPHAN: $_av"
    else
        ok "audit-guard-activation.sh does not list it as an orphan"
    fi
else
    echo "  skip: audit-guard-activation.sh absent — auditor agreement not checked"
fi

echo
echo "unrunnable-platform-arms: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
