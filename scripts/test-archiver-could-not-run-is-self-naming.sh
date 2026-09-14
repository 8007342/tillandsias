#!/usr/bin/env bash
# @trace order:1132-r4mt
# @trace order:965-sxec (the could-not-run channel these tokens key)
#
# REGIME: source text, not execution. Every arm reads
# scripts/archive-plan-packets.sh as a FILE; nothing here runs the archiver,
# touches the ledger, or needs ruby, a plan binary or a toolbox. That is
# deliberate and it is the only construction that can cover this subject: the
# exit-3 sites are reachable only under conditions this host cannot create on
# demand (a stale plan binary, an unreadable fragment, a ruby worker that fails
# after starting), and the property under test — "a refusal names its own cause"
# — is a property of what the script CAN emit, not of what it emitted today.
# The behavioural half is already covered by test-archiver-ruby-could-not-run.sh
# and test-archiver-could-not-run-verdict.sh, which drive the one site a stub
# PATH can reach.
#
# NO ABSOLUTE TIMESTAMP IS ENCODED HERE and no line number is cited: the arms
# locate sites by matching text, so an edit that moves a block does not red it.
#
# WHY (1132-r4mt). The archiver has EIGHT exit-3 sites and, until this order,
# one of them printed a machine-readable token. A caller reading rc=3 therefore
# could not tell "the ledger instrument is stale" from "ruby cannot run in this
# locus" without parsing prose — two conditions repaired in different places by
# different people. Measured on yoga 2026-09-12: an in-gate rc=3 whose reason
# string was NOT no-usable-ruby, and the cycle that saw it could not say which
# of the other seven it had been. This fixture is the guard for the fix, and it
# is the same lesson as this row's first criterion ("print $out2 so a refusal
# names its own cause") applied one layer in.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
SRC="scripts/archive-plan-packets.sh"

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

if [ ! -f "$SRC" ]; then
    echo "could-not-run:archiver-self-naming:no-source:$SRC"
    exit 3
fi

# THE ONE DECLARED EXCEPTION, by name and with its reason. This site exits 3
# carrying `refused:no-plan-binary:`, a token spelled in the FLEET-WIDE refusal
# grammar that select-work-batch.sh, check-pickup-role-grammar.sh and
# plan-binary-probe.sh all emit. Respelling it here would break that grammar to
# tidy this one; the inconsistency (a `refused:` token on a could-not-run exit)
# is recorded on 1132-r4mt rather than papered over. An exception that has to be
# named in the fixture is visible; a silent gap is not.
EXCEPTION='refused:no-plan-binary'

# ── 1. every exit-3 site names its cause ────────────────────────────────────
#    Scans BACKWARD from each `exit 3` to the nearest preceding token echo,
#    bounded so a token belonging to an earlier site cannot be credited to a
#    later one: the window stops at the previous `exit 3`.
missing=0; sites=0
# THE WINDOW IS SMALL ON PURPOSE, and the first two versions of this arm were
# wrong in ways worth recording, because both LOOKED like passes.
#   (1) matching `could-not-run:` anywhere credited a site with the COMMENT that
#       explains the token — a self-documenting file is full of those.
#   (2) bounding the window at the PREVIOUS exit-3 let one site borrow a token
#       belonging to another site between them; deleting a real token still
#       passed.
# Measured on the current file, every site emits its token 3 to 8 lines above
# its exit, so 12 is generous and still local to the block. A site that needs a
# wider window is a site whose token is not beside its exit, which is the thing
# being pinned.
WINDOW=12
for ln in $(/usr/bin/grep -n '^[[:space:]]*exit 3[[:space:]]*$' "$SRC" | cut -d: -f1); do
    sites=$((sites+1))
    start=$((ln - WINDOW)); [ "$start" -lt 1 ] && start=1
    found="$(sed -n "${start},${ln}p" "$SRC" | /usr/bin/grep -cE '^[[:space:]]*echo "(could-not-run:|'"$EXCEPTION"')')"
    if [ "$found" = "0" ]; then
        missing=$((missing+1))
        printf '      an exit-3 site near line %s names no cause within %s lines\n' "$ln" "$WINDOW"
    fi
done

if [ "$sites" -eq 0 ]; then
    bad "found NO exit-3 sites at all — the matcher is wrong, which looks exactly like a clean result"
elif [ "$missing" -eq 0 ]; then
    ok "all $sites exit-3 sites name their cause (token, or the declared $EXCEPTION exception)"
else
    bad "$missing of $sites exit-3 sites exit could-not-run without naming which cause"
fi

# ── 2. the causes are DISTINGUISHABLE ───────────────────────────────────────
#    Two sites may share a token only when they are the same condition reached
#    by different paths; that case is asserted explicitly in arm 3.
toks="$(/usr/bin/grep -oE 'could-not-run:[a-z0-9:-]+' "$SRC" | sort)"
uniq_toks="$(printf '%s\n' "$toks" | sort -u)"
n_causes="$(printf '%s\n' "$uniq_toks" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$n_causes" -ge 5 ]; then
    ok "the script emits $n_causes distinct could-not-run causes, not one undifferentiated channel"
else
    bad "only $n_causes distinct causes — a reader still cannot tell the exit-3 sites apart"
fi

# ── 3. the two no-usable-ruby paths share ONE spelling, deliberately ────────
#    _require_ruby and the --check early exit are the SAME condition reached two
#    ways. build.sh's forge skip keys on this token, so a second spelling would
#    make the skip depend on which path got there first.
n_ruby="$(/usr/bin/grep -c 'could-not-run:no-usable-ruby' "$SRC")"
if [ "$n_ruby" -ge 2 ]; then
    ok "both no-usable-ruby paths emit the same token, so the forge skip cannot depend on the path"
else
    bad "expected the no-usable-ruby token on both paths; found $n_ruby occurrence(s)"
fi

# ── 4. NEGATIVE CONTROL: the new tokens are NOT skip-eligible ───────────────
#    This is the arm that stops the fix from becoming leniency. build.sh waves an
#    exit 3 through ONLY in a forge and ONLY on the tokenised ruby cause; a stale
#    plan binary or an unreadable fragment must still stop the gate, because
#    those are repairable in the locus that hit them (965-sxec).
skipline="$(/usr/bin/grep -n 'could-not-run:no-usable-ruby' build.sh | head -1)"
if [ -z "$skipline" ]; then
    bad "build.sh no longer keys its forge skip on the ruby token — the channel this fixture guards is gone"
else
    case "$skipline" in
        *'could-not-run:archiver:'*)
            bad "build.sh's skip now matches an archiver:* token too — a repairable instrument failure became skippable" ;;
        *)
            ok "build.sh's forge skip still keys ONLY on the ruby cause; the new tokens cannot be waved through" ;;
    esac
fi

# ── 5. the tokens are machine-readable, on STDOUT ──────────────────────────
#    A token written to stderr is invisible to build.sh, which reads the
#    archiver's stdout log. The canonical refusal PROSE stays on stderr; the
#    token must not follow it there.
stderr_tokens="$(/usr/bin/grep -E 'echo "could-not-run:[^"]*".*>&2' "$SRC" | wc -l | tr -d ' ')"
if [ "$stderr_tokens" = "0" ]; then
    ok "every could-not-run token is written to stdout, where its reader looks"
else
    bad "$stderr_tokens token(s) are written to stderr, where build.sh's log check cannot see them"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: archiver could-not-run is self-naming $pass/$total (1132-r4mt)"
    exit 0
fi
echo "FAIL: archiver could-not-run is self-naming $pass/$total (1132-r4mt)"
exit 1
