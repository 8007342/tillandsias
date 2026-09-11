#!/usr/bin/env bash
# @trace spec:ci-release, plan 1076-kft9
#
# check-sigpipe-verdict-measured.sh — decide a verdict-position pipeline by
# RUNNING it and reading PIPESTATUS, never by modelling it.
#
# ── THE MECHANISM, corrected 2026-09-06 on FOUR loci ────────────────────────
#
# EPIPE happens iff the producer still has bytes to write when the consumer
# exits. That is a RACE. Everything below is a term in it, and none of them is
# "the" mechanism — three successive single-cause stories were falsified here,
# two of them mine, each by a measurement that contradicted the last:
#
#   "producer LATENCY decides it"   INCOMPLETE — latency is one route. A FAST
#     producer with an early match and a large unwritten remainder races the
#     same way with no I/O slowness at all (macneo, litmus-covering-specs.sh).
#   "MSYS never delivers SIGPIPE"   FALSE — it does, above ~168,894 B.
#   "the pipe buffers differ"       FALSE — capacity is exactly 65,536 B on
#     every locus measured: Fedora 20-core, two WSL2 distros, and MSYS.
#
# EPIPE is reachable BELOW capacity (60,894 B, dd bs=1: 7/40), so the buffer is
# a term and not the boundary. The CONSUMER's appetite is another term, and it
# is not the same term everywhere:
#
#   Linux, 72,894 B    grep -qxF 17/40   head -c 1 40/40   consumer MOVES it
#   MSYS, 108,894 B    grep -qxF  0/40   head -c 1  0/40   consumer IRRELEVANT
#   MSYS, 168,894 B    all consumers flip together
#
# On Linux the consumer's read size is live; on MSYS every consumer flips at the
# same place, far above the shared 65,536 B capacity. That is positive evidence
# for TWO mechanisms, not one at different offsets — and it is the result worth
# keeping from the investigation, because it rests on a measured difference
# rather than on anyone's inferred cause.
#
# ── WHY THIS REPLACES A PRODUCER-NAME LIST ──────────────────────────────────
#
# check-sigpipe-verdict-pipelines-added.sh recognises producers by NAME. The
# live instance on 2026-09-05 was `sed 's/#.*//' "$lane" | grep -qE ...`, which
# met its verdict-context and early-exit-consumer tests and escaped solely
# because `sed` is absent from UNBOUNDED_PRODUCER_RE. That list had already
# failed the same way for `grep -r` (1069-c9w6, 1070-a4gc). A check that
# executes has no list to be absent from.
#
# ── A SYNTHETIC CALIBRATION IS FINE; A SINGLE-SAMPLE ONE IS NOT ─────────────
#
# An earlier note here said no synthetic reproduces the defect and only a
# deliberately slowed producer is a portable known-bad. That was drawn from
# synthetics that all sat below the racing region. A synthetic DOES reproduce it
# — `seq 1 20000 | grep -qxF 1` is 40/40 on one host — but the SAME synthetic is
# 8/60 on another and 0/40 on MSYS. The hazard was never the synthetic; it was
# reading one sample of a race as a property. Arm 1 keeps the slowed producer
# because it is the most reliable known-bad across loci, not because synthetics
# cannot work.
# Verdicts, closed vocabulary — TWO, and deliberately no clean one:
#   sigpipe-decided:<file>:<line>:<n>/<reps>   a 141 was OBSERVED. Conclusive:
#                                              one observation is enough, and a
#                                              positive can never be spurious.
#   unmeasured:<file>:<line>:<reason>          no 141 observed, or the pipeline
#                                              could not be run. NOT a safety
#                                              claim at any rep count — see the
#                                              block above measure_pipeline for
#                                              the four-locus measurements that
#                                              retired `measured-clean:`.
set -uo pipefail

# REFUSE TO BE EXECUTED. This file is a LIBRARY: sourced it defines the
# verdict functions, executed it did nothing and exited 0 — and under its
# original `check-` prefix that was indistinguishable from passing. A
# zero-byte, zero-exit `check-*.sh` is the strongest possible green and
# the weakest possible evidence; macuahuitl's --ci-full orphan sweep
# found it. Renamed out of the check- namespace (lib-, per lib-ca-path.sh
# and lib-cargo-sites.sh), AND made to refuse, because a rename stops it
# being wired by mistake while the refusal stops it passing if it is.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "refused:not-a-check:lib-sigpipe-verdict.sh is a library, not a guard — source it, or run scripts/test-sigpipe-verdict-measured.sh" >&2
    exit 2
fi

REPS="${SIGPIPE_REPS:-10}"

# A slowed producer, for calibration only. Reading a file a line at a time is
# the causal control from the header, expressed as a command.
SLOW_READ() { while IFS= read -r _l; do printf '%s\n' "$_l"; done < "$1"; }
export -f SLOW_READ 2>/dev/null || true

# measure_pipeline <file> <line> <producer> <grep-args> — RAW. No allowlist.
# Runs in a CHILD so PIPESTATUS describes the STAGES. `eval "$prod | grep $cons"`
# in this shell does not work: eval is a single simple command, so PIPESTATUS
# afterwards has ONE element describing eval. Under pipefail that lone value is
# 141, so the sigpipe arm passes by accident while the no-match arm never fires
# — a check that measures nothing and reports plausibly.
# WHY THERE IS NO CLEAN VERDICT (order 1076-kft9, measured 2026-09-06 on four
# loci: macuahuitl 20-core Fedora, esmeraldinha's distro, yolanda's distro, and
# MSYS/Git Bash).
#
# This library once emitted `measured-clean:` when it saw no 141 in REPS
# attempts, gated by a probe that claimed to detect a "permissive regime". Both
# the verdict and the probe are gone. Three successive mechanism stories were
# falsified by measurement, and the third falsified my own second:
#
#   "MSYS never delivers SIGPIPE"      FALSE — it does, above ~168,894 B
#   "the pipe buffers differ"          FALSE — capacity is exactly 65,536 B on
#                                      every locus measured, all four
#   "p is a property of the regime"    FALSE — at fixed host and fixed 65,536 B
#                                      pipe, p ranges 0.00 to 1.00 with PRODUCER
#                                      SIZE, and moves again with the CONSUMER's
#                                      appetite (72,894 B: grep -qxF 17/40,
#                                      head -c 1 40/40)
#
# EPIPE is reachable BELOW pipe capacity (60,894 B, dd bs=1: 7/40), so capacity
# is one term in a race and not the governing quantity. The race is: does the
# producer still have bytes to write when the consumer exits.
#
# THE OBSERVATION RATE AT A FIXED PRODUCER SIZE SPANS THE WHOLE RANGE ACROSS
# HOSTS — 108,894 B gave 1.00 / 0.75 / 0.13 / ~0 on the four loci — and the host
# where --ci-full actually runs sits at the blind end. So a clean reading is not
# portable, and its unreliability is anti-correlated with where it is trusted.
#
# THE DECISIVE POINT IS IDENTIFIABILITY, not sampling. To separate "this site is
# safe" from "this site is unsafe and p is low" you need a reference at the
# site's OWN producer size and consumer — and no rep count substitutes for it.
# A strictly more dangerous variant IS constructible (keep the producer, swap in
# a minimum-appetite consumer, which is the worst case since EPIPE happens iff
# the consumer exits first). That amplifies p; it cannot prove p is zero, and on
# MSYS it saturates at 0/40 for every consumer. So it does not support a clean
# verdict either — it is recorded here only as the place anyone reviving one
# should start, rather than re-deriving a calibration.
#
# WHAT SURVIVES ALL THREE FALSIFICATIONS is the original observation: the same
# site reads sigpipe-decided on one host and silent on another. So:
#
#   sigpipe-decided:   a 141 was OBSERVED. Conclusive — one is enough.
#   unmeasured:        no 141 observed. NOT a safety claim, at any rep count.
#
# Deleting the clean verdict removes the only verdict that can be FALSE, at a
# rate nobody can bound. It also removes the calibration entirely: with nothing
# to gate on, there is no regime probe, no cache, no polarity and no reference
# size — every one of which was a premise that turned out wrong.
measure_pipeline() {
    local file="$1" line="$2" prod="$3" cons="$4"
    local i sig=0 nomatch=0 pstat first last     # NOT `line`: that is a parameter
    for i in $(seq "$REPS"); do
        pstat="$(bash -c "set -o pipefail; $prod | grep $cons >/dev/null 2>&1; echo \${PIPESTATUS[*]}" 2>/dev/null)"
        first="${pstat%% *}"; last="${pstat##* }"
        [ "$first" = "141" ] && sig=$((sig+1))
        [ "$first" = "0" ] && [ "$last" != "0" ] && nomatch=$((nomatch+1))
    done
    if [ "$sig" -gt 0 ]; then
        echo "sigpipe-decided:$file:$line:${sig}/${REPS}"
    elif [ "$nomatch" = "$REPS" ]; then
        echo "unmeasured:$file:$line:no-match-today-safe-only-while-absent"
    else
        # NOT a clean bill. 0 of REPS means NOT OBSERVED, never CANNOT HAPPEN:
        # the same site reads 40/40 on one locus and 0/40 on another.
        echo "unmeasured:$file:$line:not-observed-in-${REPS}-reps"
    fi
}

# verdict <file> <line> <producer> <grep-args> — classification, then measure.
# Only a pure read of a literal tracked path is executed: a gate is not entitled
# to cause side effects from corpus text.
verdict() {
    local file="$1" line="$2" prod="$3" cons="$4"
    case "$prod" in
        *'printf'*|*'echo '*|*'$('*|*'`'*)
            echo "unmeasured:$file:$line:producer-size-is-a-runtime-property"; return ;;
    esac
    case "$prod" in
        sed\ *|grep\ *|cat\ *|awk\ *|tr\ *|SLOW_READ\ *) : ;;
        *) echo "unmeasured:$file:$line:producer-is-not-a-pure-read"; return ;;
    esac
    local path
    path="$(printf '%s' "$prod" | grep -oE '[A-Za-z0-9_./-]+\.(sh|yaml|yml|md|rs|toml|txt)' | head -1)"
    if [ -z "$path" ] || [ ! -f "$path" ]; then
        echo "unmeasured:$file:$line:producer-path-not-a-literal-file"; return
    fi
    measure_pipeline "$file" "$line" "$prod" "$cons"
}
