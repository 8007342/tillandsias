#!/usr/bin/env bash
# @trace order:1137-da83
# test-land-verdict-through-a-pipe.sh — pin what a caller sees when it reads a
# land verdict through a pipe, because three false claims in one hour came from
# exactly that and none was caught by anything structural.
#
# THE INCIDENT. `scripts/land-on-platform-branch.sh windows-next | tail -25` was
# read as exit 0 for a run that exited 3 after printing
# `refused:land:gate-failed`. Two parties were then told the land tool reports
# success over a refused gate. It does not — and that tool's header says, in as
# many words, that neither a zero exit status nor a ref-update line is
# sufficient evidence a commit landed, because someone once shipped precisely
# that bug. So the tool was accused of the defect it was written to prevent, by
# a reading that had the defect, and a sibling host was about to file a row
# against it.
#
# WHAT THIS FIXTURE IS FOR. Not to fix the land tool: arm D shows it is correct.
# It is to make the TRAP executable, so the next reader meets it as a passing
# test with named outcomes instead of as folklore or as a wasted cycle. The
# expensive part is not that `$?` is wrong — it is arm A, where the refusal is
# not merely mis-statused but ABSENT from what the caller captured, because the
# tool routes its verdict to stderr and a bare `|` pipes only stdout.
#
# REGIME: hermetic. Every arm runs in its own scratch repo with a local bare
# remote and a STUB `./build.sh` that refuses; no network, no real gate, and the
# real repository is never touched. The land script is copied into the scratch
# tree because it resolves its own root from `${BASH_SOURCE[0]}/..` and would
# otherwise operate on this checkout. Nothing here pins a wall-clock time or a
# host identity; the only host-shaped assumption is a POSIX shell with git.

# NOTE `set -u` WITHOUT `-o pipefail`, and that is deliberate rather than an
# omission. Arms A and C exist to observe what a caller gets from a BARE
# pipeline, and `pipefail` is one of the three sanctioned remedies for exactly
# that — enabling it here would make the pipeline report the land tool's 3 and
# every trap arm would pass while measuring the remedy instead of the defect.
# It did, on this fixture's first run: arms A, B, C2 and F all went red against
# a correct tool because the file began `set -uo pipefail`. Arm F turns it on
# deliberately, in a subshell, which is the only place it belongs here.
set -u

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANDSH="$REAL_ROOT/scripts/land-on-platform-branch.sh"
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

# A scratch repo whose `./build.sh --check` REFUSES, with a local bare origin
# and one unpushed commit, i.e. the exact state in which the land tool reaches
# its gate and turns it down.
scratch_refusing_land() {
    local d bare
    d="$(mktemp -d "${TMPDIR:-/tmp}/land-pipe-test.XXXXXX")"
    bare="$d/origin.git"
    git init -q --bare "$bare"
    git init -q -b windows-next "$d/w"
    git -C "$d/w" remote add origin "$bare"
    mkdir -p "$d/w/scripts"
    cp "$LANDSH" "$d/w/scripts/land-on-platform-branch.sh"
    # The stub IS the seam. The land tool hardcodes `./build.sh --check`, so a
    # refusing gate is produced by giving the scratch tree a build.sh that
    # refuses — and it prints a line matching the tool's own first-failing-line
    # grep, so arm E can check the tool surfaces the CAUSE and not just a code.
    printf '#!/usr/bin/env bash\necho "violation:stub-gate-refuses:1"\nexit 1\n' \
        > "$d/w/build.sh"
    chmod +x "$d/w/build.sh"
    git -C "$d/w" -c user.email=t@t -c user.name=t add -A
    git -C "$d/w" -c user.email=t@t -c user.name=t commit -q -m base
    git -C "$d/w" push -q origin windows-next
    # The trunk ref must EXIST on the scratch remote. The land tool merges
    # origin/$TRUNK before every non-trunk push (pull_merge_cadence), so without
    # this the run dies at `land:fetch-failed:linux-next` with exit 4 and never
    # reaches the gate — every arm below then measures a missing branch instead
    # of a refused gate, which is how this fixture first ran.
    git -C "$d/w" push -q origin windows-next:linux-next
    git -C "$d/w" -c user.email=t@t -c user.name=t commit -q --allow-empty -m unpushed
    printf '%s\n' "$d/w"
}

W="$(scratch_refusing_land)"
LAND="$W/scripts/land-on-platform-branch.sh"

# ── D. THE POSITIVE CONTROL, FIRST. Everything below is only interesting if the
#       tool is right, so establish that before documenting how to misread it.
( cd "$W" && bash "$LAND" windows-next 1 >/dev/null 2>"$W/err.txt" )
drc=$?
if [ "$drc" -eq 3 ]; then
    ok "arm D: unpiped, the land tool exits 3 for a refused gate (its documented code)"
else
    bad "arm D: unpiped land exited $drc, expected 3 — the rest of this fixture describes a tool that no longer behaves as pinned"
fi
if grep -q "refused:land:gate-failed" "$W/err.txt"; then
    ok "arm D2: and names the refusal on stderr"
else
    bad "arm D2: no refused:land:gate-failed on stderr — got: $(head -2 "$W/err.txt" 2>/dev/null)"
fi

# ── E. The refusal carries its CAUSE, not just a code (order 1033-iycs).
if grep -q "violation:stub-gate-refuses:1" "$W/err.txt"; then
    ok "arm E: the refusal names the first failing line from the gate log"
else
    bad "arm E: refusal did not surface the gate's first failing line — a caller is sent back to re-run a different invocation, which is the defect 1033-iycs fixed"
fi

# ── A. THE TRAP, in its worst form: status wrong AND verdict absent. ─────────
# `cmd | tail` pipes stdout only. The land tool's refusal goes to stderr, so a
# caller who pipes without 2>&1 captures output that does not contain the word
# "refused" anywhere, and reads $? as tail's 0. Both halves of the evidence are
# gone at once, which is why this misreading survived long enough to be
# published to two parties.
# RUN THE PIPELINE IN THIS SHELL — not in `$( )`, not in `( )` — and read
# PIPESTATUS on the very next line. THREE ways to lose the thing this arm
# measures, all three hit while writing it:
#
#   1. `x="$(cmd | tail)"` — PIPESTATUS then describes the ASSIGNMENT, a simple
#      command, so [0] is 0.
#   2. `( cd d && cmd | tail )` — PIPESTATUS describes the SUBSHELL, again a
#      simple command, so [0] is 0. This one survived fix 1 and looks correct.
#   3. `arc=$?; astatus="${PIPESTATUS[0]}"` — even on ONE LINE. `;` separates
#      two commands, and the first assignment RESETS the array before the
#      second reads it. Measured:
#
#        bash -c 'exit 3' | tail -1 >/dev/null
#        a=$?; b="${PIPESTATUS[0]}"   ->  a=0 b=0      (both wrong)
#        ps=("${PIPESTATUS[@]}")      ->  ps=(3 0)     (correct)
#
# So the status of a pipeline is destroyed by the ordinary acts of saving it,
# scoping it, or capturing its output — this fixture's own subject, one level
# in. THE REMEDY ITSELF HAS THE TRAP: `${PIPESTATUS[0]}` is the advice given in
# 1137-da83's row and in the drill, and reaching for it the obvious way yields
# 0 and looks like a tool that exited cleanly. The only form that works is to
# SNAPSHOT THE WHOLE ARRAY as the next command after the pipeline, then index
# it — first element for the command, last for what bare `$?` would have said.
_prev="$PWD"; cd "$W" || { bad "arm A: could not enter scratch"; exit 1; }
bash "$LAND" windows-next 1 2>/dev/null | tail -3 > "$W/apiped.txt"
_ps=("${PIPESTATUS[@]}")
cd "$_prev" || exit 1
astatus="${_ps[0]}"                      # the land tool's
arc="${_ps[${#_ps[@]}-1]}"               # tail's — what bare `$?` would report
apiped="$(cat "$W/apiped.txt")"
if [ "$arc" -eq 0 ]; then
    ok "arm A: \$? after the pipe is 0 — tail's status, not the land tool's 3"
else
    bad "arm A: \$? after the pipe was $arc; this fixture's premise is that it is tail's 0"
fi
case "$apiped" in
    *refused:land*) bad "arm A2: the captured stdout contained the refusal — the tool's verdict routing changed, and this arm's claim that piping HIDES it is now false" ;;
    *)              ok "arm A2: and the refusal is ABSENT from the captured stdout — nothing in what the caller kept says the land failed" ;;
esac

# ── B. The correct read of the same pipeline. ───────────────────────────────
if [ "$astatus" -eq 3 ]; then
    ok "arm B: \${PIPESTATUS[0]} recovers the land tool's 3 from that same pipeline"
else
    bad "arm B: \${PIPESTATUS[0]} was $astatus, expected 3 — the recommended remedy does not work here"
fi

# ── C. Merging stderr restores the verdict TEXT but not the status. ──────────
# This is the shape that actually occurred: `2>&1 | tail -25` showed the
# refusal on screen while the harness reported the pipeline's 0, so the reader
# had the right answer in front of them and believed the wrong one.
# `tail -25`, the window the actual incident used. A smaller one cuts the
# refusal off entirely — the tool prints its remedy paragraph after the verdict
# line — which would make arm C fail for a reason that has nothing to do with
# what it measures.
cpiped="$( cd "$W" && bash "$LAND" windows-next 1 2>&1 | tail -25 )"
crc=$?
case "$cpiped" in
    *refused:land:gate-failed*) ok "arm C: with 2>&1 the refusal text IS captured" ;;
    *)                          bad "arm C: 2>&1 pipeline did not capture the refusal: $cpiped" ;;
esac
if [ "$crc" -eq 0 ]; then
    ok "arm C2: but \$? is STILL 0 — seeing the verdict and reading the status are independent, and only one of them was believed"
else
    bad "arm C2: \$? after the 2>&1 pipeline was $crc, expected tail's 0"
fi

# ── F. set -o pipefail is the other sanctioned remedy; prove it, do not assert it.
fpipe="$( cd "$W" && set -o pipefail; bash "$LAND" windows-next 1 2>/dev/null | tail -3 >/dev/null; echo $? )"
if [ "$fpipe" -eq 3 ]; then
    ok "arm F: set -o pipefail propagates the land tool's 3 through the pipe"
else
    bad "arm F: with pipefail the pipeline reported $fpipe, expected 3"
fi

rm -rf "$(dirname "$W")"

if [ "$fail" -eq 0 ]; then
    echo "ok:land-verdict-pipe-fixture:all"
    exit 0
fi
echo "fail:land-verdict-pipe-fixture"
exit 1
