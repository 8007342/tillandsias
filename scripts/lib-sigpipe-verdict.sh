#!/usr/bin/env bash
# @trace spec:ci-release, plan 1076-kft9
#
# check-sigpipe-verdict-measured.sh — decide a verdict-position pipeline by
# RUNNING it and reading PIPESTATUS, never by modelling it.
#
# ── THE MECHANISM, measured 2026-09-05 on two hosts ─────────────────────────
#
# The verdict is decided by PRODUCER LATENCY. It is NOT decided by output size,
# by bytes remaining after the match, or by the pipe buffer.
#
#   byte-identical file (one md5), same command, same consumer:
#     drvfs  /mnt/c/...  esmeraldinha   10/10 SIGPIPE   read 207 ms / 5 passes
#     ext4   /tmp/...    (a copy)        0/10           read  10 ms / 5
#     btrfs on NVMe      macuahuitl      0/10           read   6 ms / 5
#
#   CAUSAL CONTROL — a filesystem differs in more than speed, so the difference
#   above is not on its own a cause. Slowing the producer ON EXT4 with a
#   per-line read loop, same bytes and same consumer, reproduces it 10/10.
#   Nothing about drvfs is required; latency is.
#
#   WHY: a FAST producer writes all its output into the 64 KB pipe buffer before
#   `grep -q` is scheduled to exit, so it has nothing left to write and never
#   sees EPIPE. A SLOW producer is still blocked on read I/O when grep matches
#   and exits; its next write goes to a pipe with no reader, and that is the 141.
#   Size matters only above the buffer. Latency decides everything below it.
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
# ── DO NOT CALIBRATE THIS WITH A SYNTHETIC ON A DIFFERENT FILESYSTEM ────────
#
# Every synthetic built while investigating lived on ext4 and NONE reproduced
# the defect, across four variables: total size, match position, ERE complexity,
# and sed doing real substitution work. A synthetic calibration case reports
# SAFE and makes this check confidently blind — the exact failure it exists to
# catch. Scratch corpora must live inside the checkout, and the portable
# known-bad case is a deliberately slowed producer.
#
# Verdicts, closed vocabulary:
#   sigpipe-decided:<file>:<line>:<n>/<reps>   producer died 141; the verdict was not the question
#   measured-clean:<file>:<line>:0/<reps>      executed, producer exited 0
#   unmeasured:<file>:<line>:<reason>          not decidable without running the system
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
# THE INSTRUMENT'S OWN CALIBRATION (order 1076-kft9, measured 2026-09-06).
#
# measure_pipeline counts 141s and, seeing none, would report `measured-clean:`
# with no evidence a 141 was REACHABLE at that producer size. Whether it is
# reachable depends on the PLATFORM'S PIPE BUFFER, which is not constant:
#
#     producer bytes      Linux (tillandsias-build)     MSYS (Git Bash)
#        78,894                  0/5                         -
#       108,894                  5/5                        0/5
#       168,894                   -                         5/5
#       288,894                   -                        10/10
#
# Linux refuses a producer that MSYS lets finish. Roughly 109KB-169KB of output
# is SIGPIPE-decided on Linux and clean on MSYS, so `measured-clean:` DOES NOT
# PORT between them: the same call site is defective on one and spotless on the
# other. A sweep run on the more permissive platform under-reports, silently.
#
# I FIRST READ THIS AS "MSYS NEVER DELIVERS SIGPIPE" on a single measurement at
# 108,894 bytes — which sits almost exactly in the band where the two disagree.
# One sample cannot tell "never" from "not yet"; a boundary looks like an
# absence if you only sample one side of it. The table above is the corrected
# claim and the reason this probe is a THRESHOLD question, not a yes/no one.
#
# So the calibration asks: IS THIS REGIME AT LEAST AS STRICT AS THE REFERENCE?
# The reference is the size at which Linux — the gate's own platform and the
# smaller buffer of the two — reliably refuses. A regime that also refuses there
# can be trusted to have produced a meaningful clean; a more permissive one
# cannot, and its cleans are downgraded to `unmeasured:`.
#
# RETRY IS SOUND HERE and is not the anti-pattern it resembles. The pipeline is
# a RACE: at the reference size the distro gave 39/40 idle but 17/20 under load.
# One 141 PROVES the regime refuses at this size; a miss proves nothing. So the
# loop exits on first success and only a full run of misses concludes anything.
# That is retrying a test whose POSITIVE is conclusive — the opposite case, "is
# this site clean now", needs every repetition to pass and must never be retried.
_SIGPIPE_REFERENCE_LINES=20000   # ~108,894 bytes: Linux refuses here, MSYS does not
_sigpipe_regime_is_reference_strict() {
    if [ -z "${_SIGPIPE_REGIME_STRICT:-}" ]; then
        local _p _try
        _SIGPIPE_REGIME_STRICT=no
        for _try in 1 2 3 4 5 6 7 8; do
            _p="$(bash -c "set -o pipefail; seq 1 ${_SIGPIPE_REFERENCE_LINES} | grep -qxF 1 >/dev/null 2>&1; echo \${PIPESTATUS[0]}" 2>/dev/null)"
            if [ "$_p" = "141" ]; then _SIGPIPE_REGIME_STRICT=yes; break; fi
        done
    fi
    [ "$_SIGPIPE_REGIME_STRICT" = "yes" ]
}

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
    elif ! _sigpipe_regime_is_reference_strict; then
        # This regime tolerates a producer the reference platform refuses, so a
        # clean count here is permissive rather than informative: the same site
        # may be sigpipe-decided where the gate actually runs.
        echo "unmeasured:$file:$line:regime-pipe-buffer-larger-than-reference"
    else
        echo "measured-clean:$file:$line:0/${REPS}"
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
