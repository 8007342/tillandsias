#!/usr/bin/env bash
# test-archiver-ruby-could-not-run.sh — a missing ruby must read as
# could-not-run (exit 3), never as a claim about the ledger.
# @trace order:965-sxec
# @trace order:923-ws3r (the could-not-run channel this routes into)
#
# THE DEFECT. Inside a forge the image ships NO ruby and puts an on-demand brew
# SHIM on PATH under that name. `command -v ruby` therefore succeeds, the shim's
# install fails by design (attestation is required and no GitHub credential may
# exist in a forge), and it exits 127. build.sh maps rc==3 to "the archiver's
# check COULD NOT RUN ... the instrument is what needs repair" but 127 misses
# that branch and falls through to a substantive claim:
#
#     the plan archiver would CHANGE THE READY SET, orphan events, or leave
#     archived rows unanswerable — do not sweep
#
# asserted on the strength of a command that never executed. MEASURED on
# lenovinha-tillandsias-forge 2026-09-02: rc=127, and the gate reported ledger
# corruption that did not exist.
#
# Hermetic: a stub `ruby` and a stub `toolbox` on PATH, no container, no network.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
pass=0; fail=0
STUB="$(mktemp -d "${TMPDIR:-/tmp}/archiver-ruby-stub.XXXXXX")"
# XDG_* must survive: with a stripped environment `toolbox` writes its runtime
# state into $PWD/toolbox and dirties the worktree. Found the hard way while
# writing this test.
trap 'rm -rf "$STUB"' EXIT

printf '#!/usr/bin/env bash\necho "tillandsias: brew install ruby failed (attestation verification is REQUIRED)." >&2\necho "tillandsias: %s is not installed." >&2\nexit 127\n' "'ruby'" > "$STUB/ruby"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/toolbox"
chmod +x "$STUB/ruby" "$STUB/toolbox"

# ORDER 560: ruby is reached only through the opt-in now; the default Lua
# worker would (correctly) not refuse here at all.
out="$(env PATH="$STUB:$PATH" TILLANDSIAS_ARCHIVER_BACKEND=ruby ./scripts/archive-plan-packets.sh --check 2>&1)"
rc=$?

# 1. The exit code routes to could-not-run, not to a bare 127 and not to 1.
if [ "$rc" -eq 3 ]; then
    pass=$((pass+1))
else
    fail=$((fail+1)); echo "FAIL: expected exit 3 (could-not-run), got $rc"
fi

# 2. THE VERDICT MUST NOT ASSERT ANYTHING ABOUT THE LEDGER. This is the half
#    that made the defect expensive: an agent went looking for ledger damage.
if printf '%s' "$out" | grep -q 'would CHANGE THE READY SET'; then
    fail=$((fail+1)); echo "FAIL: the run asserted a ready-set claim it never tested"
else
    pass=$((pass+1))
fi

# 3. The refusal must NAME the instrument and a remedy — reaching stderr, not
#    swallowed. The ruby-dependent call site redirects stdout to /dev/null, so a
#    refusal printed on stdout is invisible; that was the first version of this
#    fix and this arm is why it was caught.
if printf '%s' "$out" | grep -q 'no usable ruby in this locus' \
   && printf '%s' "$out" | grep -q 'Remedy:'; then
    pass=$((pass+1))
else
    fail=$((fail+1)); echo "FAIL: refusal did not name the instrument and a remedy on stderr"
fi

# ORDER 1132-r4mt, criterion 4. SNAPSHOT THE SCRATCH PATHS BEFORE ANY ARM RUNS
# THE ARCHIVER, so arm 5 can tell state THIS FIXTURE created from state that was
# already here.
#
# WHY IT MATTERS, measured rather than supposed: arm 5 has NO INVOCATION OF ITS
# OWN. It audits the worktree after every preceding arm, so it is a
# post-condition over their side effects and not an independent assertion — that
# is the answer to this row's "are arms 4 and 5 independent" criterion, and the
# answer is NO, in one direction: an arm-4 path that leaks produces an arm-5
# failure, while arm 5 can also fail with arm 4 green.
#
# AND IN THE GATE IT AUDITS SOMEBODY ELSE'S RUN. build.sh invokes
# scripts/archive-plan-packets.sh --check on its own, with `|| true`, EARLIER in
# the same gate than it invokes this fixture. Standalone there is no such run.
# So in situ this arm inspects a worktree a different archiver invocation has
# already touched, and its message — "the refusal path left scratch state" —
# names a subject it never observed. That is an accusation, not a measurement,
# and it is one concrete in-gate/standalone difference for this fixture.
#
# THIS DOES NOT EXPLAIN THE ARM-4 rc=3, and must not be read as doing so. That
# refusal is a different arm with a different mechanism, still open.
_scratch_paths='plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb toolbox'
# shellcheck disable=SC2086
_dirt_before="$(git status --porcelain --untracked-files=all -- $_scratch_paths 2>/dev/null)"

# 4. A working lane must still WORK — the guard must not refuse a host that has
#    ruby, natively or through the builder toolbox. Negative control: without it
#    a guard that refused everything would satisfy arms 1-3.
out2="$(./scripts/archive-plan-packets.sh --check 2>&1)"; rc2=$?
if [ "$rc2" -eq 0 ]; then
    pass=$((pass+1))
elif [ "$rc2" -eq 3 ] && printf '%s' "$out2" | grep -q 'no usable ruby'; then
    echo "SKIP: this host has no usable ruby in either lane, so the positive control cannot run here"
    pass=$((pass+1))
else
    fail=$((fail+1)); echo "FAIL: positive control did not pass on a host with ruby (rc=$rc2)"
    # PRINT WHAT IT SAID (order 1132-r4mt). $out2 is captured at the call above
    # WITH 2>&1 and was then discarded -- every refusal of this arm printed the
    # exit code and threw away the sentence naming its own cause. That happened
    # on two hosts on 2026-09-12, twice each, in gates costing ~8 minutes apiece,
    # and both times the run that would have explained it was already gone.
    #
    # It matters more here than usual because this arm SKIPS on a CONJUNCTION
    # (rc2==3 AND the output says "no usable ruby"), so a bare rc=3 means the
    # archiver refused for some OTHER reason and that reason is the whole
    # question. yoga measured rc=0 standalone against rc=3 in situ, same tree.
    echo "  what the archiver actually said (rc=$rc2):"
    printf '%s\n' "$out2" | sed 's/^/    /'
fi

# 5. The worktree must be clean afterwards. The archiver copies plan/ and a
#    crash used to leave the copy behind, which starts every boundary-guarded
#    cycle dirty (the 2026-08-23 WSL incident). A refusal path is a new exit and
#    must honour the same trap.
# shellcheck disable=SC2086
_dirt_after="$(git status --porcelain --untracked-files=all -- $_scratch_paths 2>/dev/null)"
if [ -z "$_dirt_after" ]; then
    pass=$((pass+1))
elif [ "$_dirt_after" = "$_dirt_before" ]; then
    # PRE-EXISTING, and therefore NOT this fixture's refusal path. Saying so is
    # the whole point: in the gate the dirt is most likely from build.sh's own
    # earlier archiver run. Reported, never silent — a leak is still a leak and
    # somebody owns it — but attributed honestly and not counted as this
    # fixture's failure, because this fixture did not cause it.
    pass=$((pass+1))
    echo "NOTE: scratch state was ALREADY PRESENT before this fixture ran, and is"
    echo "  unchanged by it — so it is not the refusal path's doing. In a gate the"
    echo "  likely owner is build.sh's own archive-plan-packets.sh --check, which"
    echo "  runs earlier in the same gate. Unchanged state, listed:"
    printf '%s\n' "$_dirt_before" | sed 's/^/    /'
else
    fail=$((fail+1)); echo "FAIL: the refusal path left scratch state in the worktree"
    echo "  before this fixture ran:"
    printf '%s\n' "${_dirt_before:-    (clean)}" | sed 's/^/    /'
    echo "  after:"
    printf '%s\n' "$_dirt_after" | sed 's/^/    /'
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: archiver could-not-run on absent ruby $pass/$total (965-sxec)"
    exit 0
fi
echo "FAIL: archiver could-not-run on absent ruby $pass/$total (965-sxec)"
exit 1
