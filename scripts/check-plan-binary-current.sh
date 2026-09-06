#!/usr/bin/env bash
# ORDER 1079-qb8k. Is the plan binary this host INVOKES current with the fleet?
#
# REWRITTEN 2026-09-06, and the previous version is the reason. It probed for
# ONE commit — yoga's 1079-qb8k claim refusal — and printed
# `ok:plan-binary-current`, a verdict naming the general property on the
# evidence of a single instance. macneo's host PASSED it while its
# `expire-claims --list-live` demonstrably mutated a ledger, because that is a
# different commit (b98f2f9a7) which the probe never touched. It ran correctly
# and measured the wrong thing, which is the harder failure: every hallmark of
# a working check was present.
#
# WORSE, IT WOULD HAVE BEEN ACTIVELY MISLEADING IF WIRED. On 2026-09-05 this
# host's own stale binary carried the claim refusal and lacked b98f2f9a7, so a
# wired guard would have printed `ok:plan-binary-current` on the exact artefact
# that produced a false accusation against another host — a green to cite while
# being wrong. An unwired guard is inert; a wired guard answering a narrower
# question than its NAME is worse, because it produces citations. The path
# existing is necessary and not sufficient: the artefact at the end of it must
# answer the question the path is named for (macneo, 1086-kx8i).
#
# SO IT NO LONGER PROXIES A COMMIT. It delegates to the two-sided fixture,
# which has 16 arms, a known pre-fix signature of 5/16, and seeds its own tree
# under --index so it is safe to run a WRITE-CAPABLE binary in order to find
# out whether it writes.
#
# AND IT REFUSES TO SCORE A BINARY IT COULD NOT EXECUTE (esmeraldinha). On a
# Windows host `./build.sh --check` re-execs into WSL, which cannot execute a
# `.exe` at all: eleven arms then fail with `Exec format error` and the result
# reads 5/16 for a binary that is fine. `cannot execute` and `writes when asked
# to read` MUST NOT produce the same verdict, so executability is probed first
# and a negative is `unmeasured:`, never a refusal.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
FIXTURE="scripts/test-expire-claims-write-is-opt-in.sh"
[ -f "$FIXTURE" ] || { echo "blocked:plan-binary-current:no-fixture:$FIXTURE"; exit 1; }

# THE PRECONDITION, REPORTED AND NEVER INFERRED (macneo). Neither this check
# nor a build-id comparison certifies that what you INVOKED came from the
# checkout. "Does a second copy exist, and does a bare name resolve" is the
# condition under which either means anything, so it is stated in the verdict.
_path_copy="$(command -v tillandsias-plan 2>/dev/null || true)"
_copies="$(type -a tillandsias-plan 2>/dev/null | sed 's/.* is //' | sort -u | grep -c . || true)"
[ -n "${_copies:-}" ] || _copies=0

# Which artefact are we judging? The fixture's own resolution unless a caller
# pins one. An EMPTY `command -v` must not silently become "test the default
# and report it as the installed copy" (macbookair): that is a check whose
# output cannot distinguish "I tested what you named" from "what you named does
# not exist, so I tested something else".
BIN="${TILLANDSIAS_PLAN_BINARY:-}"
if [ -z "$BIN" ]; then
    . scripts/plan-binary-probe.sh 2>/dev/null || true
    if command -v resolve_plan_binary >/dev/null 2>&1; then BIN="$(resolve_plan_binary 2>/dev/null || true)"; fi
fi
[ -n "${BIN:-}" ] || { echo "unmeasured:plan-binary-current:no-binary-resolved copies=$_copies"; exit 0; }

# EXECUTABILITY FIRST, and independent of the fixture's arm semantics. 126 is
# the shell's "found but not executable"; the ENOEXEC text is what WSL prints
# for a PE binary. Either means this locus cannot judge this artefact.
_probe="$("$BIN" build-id 2>&1)"; _prc=$?
case "$_prc:$_probe" in
    126:*|*"Exec format error"*|*"cannot execute binary file"*)
        echo "unmeasured:plan-binary-cannot-execute-here:$BIN rc=$_prc copies=$_copies — this locus cannot run this artefact (a .exe under WSL, or a foreign arch); NOT a staleness verdict"
        exit 0 ;;
esac

# The real ledger must be untouched whatever happens. The fixture seeds its own
# tree, but assert it rather than trusting the comment.
_repo_before="$(ls plan/index.d 2>/dev/null | wc -l | tr -d ' ')"
_out="$(TILLANDSIAS_PLAN_BINARY="$BIN" bash "$FIXTURE" 2>&1)"
_repo_after="$(ls plan/index.d 2>/dev/null | wc -l | tr -d ' ')"
if [ "$_repo_before" != "$_repo_after" ]; then
    echo "blocked:plan-binary-current:probe-had-side-effects plan/index.d $_repo_before -> $_repo_after"
    exit 1
fi

_arms="$(printf '%s' "$_out" | sed -n 's/^expire-claims-write-is-opt-in: \([0-9]*\) passed, \([0-9]*\) failed$/\1\/\2/p' | tail -1)"
[ -n "$_arms" ] || { echo "unmeasured:plan-binary-current:fixture-printed-no-arm-count:$BIN"; exit 0; }
_pass="${_arms%/*}"; _fail="${_arms#*/}"

if [ "$_fail" = 0 ]; then
    echo "ok:plan-binary-write-is-opt-in:$BIN arms=$_pass/0 copies=$_copies path=${_path_copy:-<none-on-PATH>}"
    exit 0
fi
# 5/16 IS NOT PARTIAL SAFETY. The fixture's own header records that two of its
# passing arms pass pre-fix only because `--write` is an UNKNOWN FLAG there.
echo "stale:plan-binary-writes-when-asked-to-read:$BIN arms=$_pass passed/$_fail failed copies=$_copies" >&2
echo "  REMEDY: scripts/cycle-preflight.sh (rebuilds AND installs; runs the binary before replacing the copy on PATH, order 1060-wxdh), then re-run this check and report the ARM COUNT rather than the word fixed." >&2
echo "  Run cycle-preflight in the FOREGROUND: backgrounded through a harness it has produced zero bytes, exit 0, and no rebuild (esmeraldinha, 2026-09-06)." >&2
exit 1
