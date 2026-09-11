#!/usr/bin/env bash
# @trace order:721-nyev, spec:ci-release
#
# Every script that RUNS tillandsias-plan must resolve it through the shared
# probe (scripts/plan-binary-probe.sh), never through a hardcoded target/ path.
#
# WHY A GATE RATHER THAN ANOTHER ROUND OF FIXES. 704-zcgi centralised the probe
# on the reasoning that fixing instances is not enough. Four more instances
# appeared afterwards anyway -- check-stranded-in-progress, then
# check-fragment-closure-evidence-added, then select-work-batch, then
# cycle-preflight -- each written by someone who had no reason to know the
# probe existed. A tenth will be written next week. The rule has to be
# enforceable rather than remembered.
#
# THE UNDERLYING FACT: an executable BIT is a claim; RUNNING the binary is
# evidence. On a shared Windows/WSL checkout a WSL build leaves a Linux ELF at
# target/release/tillandsias-plan beside the runnable .exe, and `[ -x ]` is
# true for both. Callers that trusted the bit degraded in three different
# directions -- a silent "binary absent, check skipped", a red gate naming
# violations that did not exist, and a pre-push lane that reported on a
# validation it never ran.
#
# THE INVARIANT, deliberately simple: if a script mentions a target/ plan-binary
# path in code, it must also source the probe. Simple because 727-kmks warns
# against pattern-matchers that need a table of exceptions -- the fix for every
# real site is the same one line, so no exception table should be necessary. If
# a genuine exception ever appears, that is a signal to reconsider the rule, not
# to add an allow-list.
#
# WHY IT NOW SCANS TWO SURFACES (order 751-vega). This gate walked
# `find scripts -name '*.sh'` and had been reporting ok on every windows cycle
# while FOURTEEN litmus files resolved the binary by hand and two of them were
# RED for exactly that. The gate was not wrong about what it measured -- it was
# scoped to scripts/, and its verdict said so nowhere. That is the same defect
# one level up from the one it exists to catch: a signal reporting healthy
# without observing the property. The verdict line now NAMES each surface and
# its counts, so a surface that is not being scanned is visible in the output
# rather than inferable from the source.
#
# THE LITMUS RULE differs in one respect. A litmus command may build its OWN
# tillandsias-plan into a scratch target dir and run it from there:
#
#   CARGO_TARGET_DIR=$F/target cargo build ... && $F/target/release/tillandsias-plan
#
# That is not the shared checkout's binary and the probe must not resolve it --
# the whole point of that step is to run the artifact it just built. So the
# pattern requires the path to be the CHECKOUT-relative one (`./target/...`,
# `target/...`), not one rooted at a variable. This is a distinction in the
# rule, not an allow-list of files: any command naming the shared checkout's
# path is in scope regardless of which file it lives in.
#
# GRAMMAR (exactly one line on stdout)
#   ok:plan-binary-probe-usage:<eligible> eligible of <scanned> scanned \
#       [scripts=<e>/<s> litmus=<e>/<s>]
#   violation:plan-binary-probe-usage:<n>
#
# Exit 0 on ok, 1 on violation, 2 on usage error.

set -uo pipefail

ROOT="${PLAN_PROBE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || { echo "violation:plan-binary-probe-usage:0"; exit 2; }

SCAN_DIR="${1:-scripts}"
PROBE_REL="plan-binary-probe.sh"

violations=()
checked=0
scanned=0

while IFS= read -r f; do
    # The probe itself defines the candidate paths; it cannot source itself.
    scanned=$((scanned + 1))
    case "$f" in */$PROBE_REL) continue ;; esac

    # Code lines only. A comment or a user-facing message may name the path
    # legitimately -- and a checker that flagged its own explanatory comment
    # would be the "gate that greps its own comment" antipattern 601-462g
    # names, one level up.
    code="$(sed 's/#.*//' "$f")"
    if ! grep -qE 'target/(release|debug)/tillandsias-plan' <<<"$code"; then # sigpipe-ok: safe pipeline
        continue
    fi
    # Messages that merely NAME the path (echo/printf/array notes) are not
    # executions. Strip quoted-string contexts that are obviously output.
    if ! printf '%s' "$code" \
        | grep -vE '(echo|printf|LANE_NOTES|note|fail|say)[[:space:]]' \
        | grep -qE 'target/(release|debug)/tillandsias-plan'; then
        continue
    fi

    checked=$((checked + 1))
    # COMPLIANCE IS TESTED ON THE SAME BYTES ELIGIBILITY WAS (order 1060-428m).
    # This read used to be `grep -q "$PROBE_REL" "$f"` — the RAW file, comments
    # included — while eligibility above is computed on comment-STRIPPED $code.
    # The asymmetry made a file compliant if the probe's FILENAME appeared
    # anywhere in it: a comment explaining the rule, or a `for f in
    # plan-binary-probe.sh gate-stamp.sh` copy loop. yoga measured the cost:
    # test-pre-push-issue-capture-lane.sh named the probe twice, never sourced
    # it, hand-rolled `[ -x target/release/tillandsias-plan ]`, and the guard
    # reported ok:24 — which is how 1058-fenk was possible at all.
    #
    # It also tests USE rather than MENTION: sourcing the probe or calling its
    # resolver. A filename is a proxy for the property; the property is that the
    # binary is resolved through the probe. Testing the proxy is the same
    # substitution this guard exists to catch, one level up — and the same shape
    # as the `[ -x ]` check it replaced: a cheap signal standing in for the
    # expensive question.
    # A BARE FILENAME IS NOT USE, and that is the last form of this defect.
    # `cp scripts/plan-binary-probe.sh "$T/"` and `for f in plan-binary-probe.sh
    # gate-stamp.sh` both name the probe without ever sourcing it — the exact
    # shape yoga measured on test-pre-push-issue-capture-lane.sh. So the test is
    # a SOURCE of the probe (`.` or `source`) or a call to its resolver.
    if ! grep -qE '(^|[;&|[:space:]])(\.|source)[[:space:]]+[^;&|]*'"$PROBE_REL"'|resolve_plan_binary|mf_plan_binary' <<<"$code"; then # sigpipe-ok: safe pipeline
        violations+=("$f")
    fi
done < <(find "$SCAN_DIR" -name '*.sh' -type f 2>/dev/null | sort)

sh_checked="$checked"
sh_scanned="$scanned"

# ── Surface 2: litmus step commands (order 751-vega) ──────────────────────────
# A litmus `command:` runs in a bash -c child that has already sourced
# scripts/litmus-stdlib.sh, so the compliant form there is `mf_plan_binary`
# (which delegates to the same probe) rather than sourcing the probe directly.
LITMUS_DIR="${LITMUS_SCAN_DIR:-openspec/litmus-tests}"
lit_checked=0
lit_scanned=0
if [ -d "$LITMUS_DIR" ]; then
    while IFS= read -r f; do
        lit_scanned=$((lit_scanned + 1))
        # Only `command:` lines execute. A precondition or a comment naming the
        # path is documentation, and flagging it would be the "gate that greps
        # its own comment" antipattern 601-462g names.
        cmds="$(grep -E '^[[:space:]]*-?[[:space:]]*command:' "$f")"
        [ -n "$cmds" ] || continue
        # The CHECKOUT-relative path only: `$F/target/release/...` is a binary
        # the step built for itself and must not be redirected to the probe.
        # PER-COMMAND, NOT PER-FILE (1060-428m, second correction). Testing the
        # whole command BLOCK let one compliant step cover a hand-rolled one:
        # litmus-fragment-status-loss-attribution-shape.yaml has five steps that
        # source the probe and at least one that runs
        # `./target/release/tillandsias-plan` directly, and a file-level test
        # calls that compliant. That is the mention-confers-compliance defect
        # this packet exists to remove, reproduced at a smaller scope — I wrote
        # it here and found it only by checking a prediction the guard had just
        # turned green.
        hardcoded=0
        bad_cmd=0
        while IFS= read -r _cmd; do
            [ -n "$_cmd" ] || continue
            printf '%s' "$_cmd" \
                | grep -qE '(^|[^/$[:alnum:]_])\.?/?target/(release|debug)/tillandsias-plan' \
                || continue   # sigpipe-ok: safe pipeline
            hardcoded=1
            # mf_plan_binary ONLY on this surface. The header above states it is
            # the compliant form here (the bash -c child has already sourced
            # litmus-stdlib.sh), and accepting a probe FILENAME instead let a
            # `cp scripts/plan-binary-probe.sh` inside a fixture-building command
            # confer compliance on the step that hardcoded the path beside it.
            printf '%s' "$_cmd" | grep -q 'mf_plan_binary' || bad_cmd=1  # sigpipe-ok: safe pipeline
        done <<< "$cmds"
        # SAME CORRECTION ON THIS SURFACE (1060-428m). `grep -q "$PROBE_REL" "$f"`
        # read the whole YAML, so a probe mention in a description, a comment or
        # a precondition conferred compliance on a file whose command: lines
        # resolved the binary by hand. Only command: lines execute, so only
        # command: lines can establish compliance.
        #
        # MEASURED before the change: of 19 counted litmus files, 7 were
        # compliant ONLY via a raw-file mention. Six of those hardcode nothing
        # and simply leave the count — they were never eligible, and counting
        # them inflated the surface total. That inflation matters here for the
        # reason this file already argues below: a total that does not track the
        # real population is how a surface hides.
        compliant=0
        if [ "$hardcoded" -eq 0 ]; then
            printf '%s' "$cmds" | grep -q 'mf_plan_binary' && compliant=1
        elif [ "$bad_cmd" -eq 0 ]; then
            compliant=1
        fi
        # Count every file that USES the plan binary, not only the ones still
        # naming the path. Counting eligibility as "still broken" would make the
        # surface total FALL as the sweep fixed files, so a fully-converted
        # directory would report the same `litmus=0/347` as one nobody had ever
        # looked at -- the exact ambiguity that hid this surface in the first
        # place.
        [ "$hardcoded" -eq 1 ] || [ "$compliant" -eq 1 ] || continue
        lit_checked=$((lit_checked + 1))
        [ "$compliant" -eq 1 ] || violations+=("$f")
    done < <(find "$LITMUS_DIR" -name '*.yaml' -type f 2>/dev/null | sort)
fi
checked=$((checked + lit_checked))
scanned=$((scanned + lit_scanned))

if [ "${#violations[@]}" -gt 0 ]; then
    echo "violation:plan-binary-probe-usage:${#violations[@]}"
    for v in ${violations[@]+"${violations[@]}"}; do
        echo "  $v runs tillandsias-plan from a hardcoded target/ path without sourcing scripts/$PROBE_REL" >&2
    done
    echo "  REMEDY (scripts): . \"\$(dirname \"\${BASH_SOURCE[0]}\")/plan-binary-probe.sh\"; PLAN=\"\$(resolve_plan_binary)\"" >&2
    echo "  REMEDY (litmus):  MFPLAN=\"\$(mf_plan_binary)\" || { echo 'FAIL: no runnable tillandsias-plan'; exit 1; }" >&2
    echo "  An executable bit is a claim; running the binary is evidence (704-zcgi, 721-nyev, 751-vega)." >&2
    exit 1
fi

# Say BOTH numbers, and say them PER SURFACE. "1 checked" reads as "it only
# looked at one file" when it means "one file mentions the path and it is
# compliant" -- the count invites the same misreading this whole class is
# about. The per-surface breakdown exists for a sharper reason: this gate was
# green for weeks while a whole directory sat outside its beam, and a single
# total could never have shown that (751-vega).
echo "ok:plan-binary-probe-usage:${checked} eligible of ${scanned} scanned [scripts=${sh_checked}/${sh_scanned} litmus=${lit_checked}/${lit_scanned}]"
exit 0
