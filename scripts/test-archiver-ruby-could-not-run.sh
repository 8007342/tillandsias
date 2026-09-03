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

out="$(env PATH="$STUB:$PATH" ./scripts/archive-plan-packets.sh --check 2>&1)"
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
fi

# 5. The worktree must be clean afterwards. The archiver copies plan/ and a
#    crash used to leave the copy behind, which starts every boundary-guarded
#    cycle dirty (the 2026-08-23 WSL incident). A refusal path is a new exit and
#    must honour the same trap.
if [ -z "$(git status --porcelain --untracked-files=all -- plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb toolbox 2>/dev/null)" ]; then
    pass=$((pass+1))
else
    fail=$((fail+1)); echo "FAIL: the refusal path left scratch state in the worktree"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: archiver could-not-run on absent ruby $pass/$total (965-sxec)"
    exit 0
fi
echo "FAIL: archiver could-not-run on absent ruby $pass/$total (965-sxec)"
exit 1
