#!/usr/bin/env bash
# ORDER 1139-ipqt. A closure is judged on WHAT IT NAMES, not on how YAML quoted
# it.
#
# check-scorable-obligation-added.sh anchors its patterns to the first character
# of the closure (scripts/*.sh*, litmus:*, cargo test*). Written as a
# double-quoted scalar the value began with a quote character, matched nothing,
# and the row was refused as carrying no scorable obligation — while the same
# words as a block scalar passed. Measured on lenovinha while filing 1137-dzzu,
# a row whose closure names two scripts and ran them both.
#
# WHY THIS IS WORTH A GUARD rather than a formatting convention nobody wrote
# down: the refusal text tells the filer to add a closure naming a litmus or a
# script. The filer HAS done that. The available next moves are to discover an
# undocumented quoting rule by trial, or to write `unscoreable:` about a row
# that is plainly scorable — recording a falsehood in the ledger to satisfy a
# gate. That is the 994-8r3w failure mode: a verdict correct about the letter
# and wrong about the intent, pushing the honest path below the escape hatch.
#
# REGIME. Every arm EXECUTES the real guard against a fragment written to a
# temporary directory, and reads the verdict it prints. No arm inspects the
# guard source, so deleting the unquoting would fail this fixture rather than
# pass it on the strength of a surviving comment. The guard reads the git index,
# so each arm runs inside a throwaway detached worktree and the caller index is
# never staged into. Fragment filenames derive from the clock at run time; no
# arm asserts any absolute moment.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

pass=0
fail=0
ok()  { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/scorable-quoting.XXXXXX")"
wt="$tmp/wt"
cleanup() {
    [ -d "$wt" ] && git -C "$ROOT" worktree remove --force "$wt" >/dev/null 2>&1
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

if ! git worktree add --detach -q "$wt" HEAD 2>"$tmp/wterr"; then
    echo "FAIL could not create a throwaway worktree: $(head -1 "$tmp/wterr")"
    echo "scorable-closure-quoting: 0 passed, 1 failed"
    exit 1
fi

# THE WORKTREE IS FOR AN ISOLATED INDEX, NOT FOR AN OLDER GUARD. `git worktree
# add HEAD` checks out the COMMITTED guard, so a fixture that stopped here would
# test the last commit rather than the change being made — reporting the old
# behaviour as a failure before the commit, and the new behaviour as a pass
# afterwards, without either being about the working tree. The guard under test
# is therefore copied in from the working tree. Only the index needs to be
# isolated; the code under test must be the code the author is editing.
cp "$ROOT/scripts/check-scorable-obligation-added.sh" \
   "$wt/scripts/check-scorable-obligation-added.sh" || {
    echo "FAIL could not stage the working-tree guard into the worktree"
    echo "scorable-closure-quoting: 0 passed, 1 failed"
    exit 1
}

# verdict <closure-yaml-line> — stage a one-packet fragment carrying that exact
# closure line and echo the guard verdict token.
verdict() {
    local closure_line="$1" frag n
    n="$(date -u +%Y%m%dt%H%M%Sz)-$RANDOM"
    frag="plan/index.d/${n}-9999-zzzz-quoting-probe.yaml"
    mkdir -p "$wt/plan/index.d"
    {
        printf 'packets:\n'
        printf '  - packet_id: probe-closure-quoting-%s\n' "$RANDOM"
        printf '    order: 9999-zzzz\n'
        printf '    status: ready\n'
        printf '    title: probe row for the 1139-ipqt fixture\n'
        printf '%s\n' "$closure_line"
    } > "$wt/$frag"
    git -C "$wt" add "$frag" >/dev/null 2>&1
    ( cd "$wt" && bash scripts/check-scorable-obligation-added.sh 2>&1 )
    git -C "$wt" rm -q --cached "$frag" >/dev/null 2>&1
    rm -f "$wt/$frag"
}

# ── ARM 1 — THE MEASURED REFUSAL, now a pass. This is 1137-dzzu closure verbatim
#           in the form it was originally written, which is what the guard
#           refused.
v="$(verdict '    verifiable_closure: "scripts/test-gate-step-skip-exit.sh passes (10/10 on lenovinha)"')"
if printf '%s' "$v" | grep -q '^ok:scorable-obligations'; then
    ok "a double-quoted closure naming a script is accepted — the refusal that provoked this row"
else
    bad "a double-quoted closure naming a script is still refused: $(printf '%s' "$v" | head -1)"
fi

# ── ARM 2 — THE FORM THAT ALWAYS WORKED still works. If the unquoting had been
#           written as a blanket strip of leading punctuation it could break
#           this, and nothing else would have noticed.
v="$(verdict '    verifiable_closure: scripts/test-gate-step-skip-exit.sh passes')"
if printf '%s' "$v" | grep -q '^ok:scorable-obligations'; then
    ok "an unquoted closure is still accepted — the fix did not trade one form for another"
else
    bad "an unquoted closure regressed: $(printf '%s' "$v" | head -1)"
fi

# ── ARM 3 — SINGLE QUOTES, the other YAML scalar style. A filer who reaches for
#           quotes at all may reach for either.
v="$(verdict "    verifiable_closure: 'scripts/test-gate-step-skip-exit.sh passes'")"
if printf '%s' "$v" | grep -q '^ok:scorable-obligations'; then
    ok "a single-quoted closure is accepted — both YAML scalar styles judged alike"
else
    bad "a single-quoted closure is refused: $(printf '%s' "$v" | head -1)"
fi

# ── ARM 4 — THE NEGATIVE CONTROL, and the reason unquoting is not just a strip.
#           An empty quoted scalar is SILENCE, which is precisely what this gate
#           exists to refuse. If stripping turned "" into a pass, the fix would
#           have opened a hole wider than the bug it closed: every row could
#           satisfy the gate by naming nothing at all, in quotes.
v="$(verdict '    verifiable_closure: ""')"
if printf '%s' "$v" | grep -q '^violation:scorable-obligation-missing'; then
    ok "NEGATIVE CONTROL: an empty quoted closure still refuses — unquoting cannot launder silence into a pass"
else
    bad "an empty quoted closure now PASSES — the fix opened a hole: $(printf '%s' "$v" | head -1)"
fi

# ── ARM 5 — THE SECOND NEGATIVE CONTROL. Quoted prose names nothing mechanical
#           and must still refuse; otherwise arm 1 would be indistinguishable
#           from "any quoted string passes".
v="$(verdict '    verifiable_closure: "we will know it works when the operator is happy"')"
if printf '%s' "$v" | grep -q '^violation:scorable-obligation-missing'; then
    ok "NEGATIVE CONTROL: quoted PROSE still refuses — unquoting exposes the value to the patterns, it does not bypass them"
else
    bad "quoted prose now passes, so the patterns are no longer being applied: $(printf '%s' "$v" | head -1)"
fi

echo "scorable-closure-quoting: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
