#!/usr/bin/env bash
# ORDER 1021-a944. A gate that cannot RUN a fragment-events check must never
# assert what the check would have FOUND.
#
# Measured by esme-windows on esmeraldinha 2026-09-04: ./build.sh --check ran
# `check-fragment-events-land.sh`, whose plan-binary probe could not resolve a
# FRESH binary, so the script exited 2 with `blocked:fragment-events-land:
# no-fresh-plan-binary`. The call site's `if ! _run ... then exit 1` collapsed
# that could-not-run exit into the exit-1 violation branch and emitted "an event
# is attached to no packet — invisible, not merely unfolded", which names the
# SILENT-DATA-LOSS class the guard guards — so the reader chased a misfiled
# packet_id that does not exist. The script distinguishes could-not-run (exit 2)
# from a real violation (exit 1) on purpose; the call site flattened the
# distinction. An UNEARNED RED on a run where the instrument never executed.
#
# THIS FIXTURE PINS THE VERDICT TEXT, not the exit code alone, for the same
# reason 965-sxec gives for the archiver: the exit code was never the defect —
# build.sh failed (or succeeded wrongly) either way. What was wrong was WHAT IT
# SAID, and a test that only checked the code would have stayed green.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

pass=0
fail=0
ok()   { echo "ok   $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL $*"; fail=$((fail + 1)); }

# ARM 1 — THE ONE THAT MATTERS: the check script's own exit-2 channel. Drive it
# with a TILLANDSIAS_PLAN_BIN that cannot resolve (a nonexistent explicit
# override is honoured on existence alone, plan-binary-probe.sh:40-41, so
# ensure_fresh_plan_binary returns 1 and the script exits 2). The script must
# report could-not-run with its own verdict token and exit 2, never a bare 1 or
# a substantive "events attached to no packet" claim.
out="$(TILLANDSIAS_PLAN_BIN="${TMPDIR:-/tmp}/does-not-exist-plan-bin" \
    bash scripts/check-fragment-events-land.sh 2>&1)"
rc=$?

if [ "$rc" -eq 2 ]; then
    ok "no runnable plan binary -> exit 2 (could-not-run), not a bare 1/0"
else
    bad "no runnable plan binary -> exit $rc, expected 2 (this is what build.sh must route on)"
fi

if printf '%s' "$out" | grep -q 'blocked:fragment-events-land:no-fresh-plan-binary'; then
    ok "the could-not-run token is emitted"
else
    bad "no blocked:fragment-events-land:no-fresh-plan-binary token — build.sh cannot tell this exit from a real violation"
fi

if printf '%s' "$out" | grep -qi 'event is attached to no packet'; then
    bad "the output claims an event is attached to no packet on a run that never ran the check"
else
    ok "no substantive orphans claim on a check that could not run"
fi

# ARM 2 — build.sh's call-site routing. A grep on the source rather than a full
# gate run: the routing is a small decision and running ./build.sh --check here
# would cost minutes to re-test one `if`. Grep for the exit-2 arm keying on the
# script's own verdict token, that it is distinct from the exit-1 violation
# text, and that the exit-1 violation still names the silent-loss class.
if grep -q 'check-fragment-events-land COULD NOT RUN' build.sh \
   && grep -q '_events_land_rc' build.sh \
   && grep -q 'cycle-preflight' build.sh; then
    ok "build.sh names the could-not-run case and the remedy (cycle-preflight)"
else
    bad "build.sh no longer names the could-not-run case and its remedy"
fi

if grep -q 'an event is attached to no packet — invisible, not merely unfolded' build.sh; then
    ok "the exit-1 violation text is still present (not removed with the exit-2 arm)"
else
    bad "the exit-1 violation text is missing from the call site — a real orphan would now be misreported"
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: fragment-events could-not-run verdict ${pass}/${pass} (1021-a944)"
    exit 0
fi
echo "FAIL: fragment-events could-not-run verdict ${pass} passed, ${fail} failed (1021-a944)"
exit 1
