#!/usr/bin/env bash
# metrics-log-path.sh — one answer to "where does a metrics log live", shared by
# every script that writes or reads one.
# @trace order:890-t9pu
#
# WHY THIS IS A SHARED FILE AND NOT THREE COPIES
#
# `/tmp` was the default in four places across three scripts, and `/tmp` IS NOT
# ONE PLACE. On a Windows host `./build.sh` re-execs into WSL2 and writes there,
# while `cycle-metrics.sh` runs in Git Bash and reads a different filesystem.
# MEASURED on yolanda 2026-08-25: 322 `build-check` records on the WSL side, 0
# on the Git Bash side. `timing:` reported `build_check_ms_avg=-` while 322
# measurements sat in a log the reader could not open, and named a `slowest`
# step from a two-day-old file. Every timing metric that host ever published was
# stale or absent — including, until it was found, the measurement of the
# boundary itself.
#
# The defect is a WRITER and a READER disagreeing about a path. Fixing it in one
# script and not the others would have re-created it between the health PROBE
# (`check-mcp-expert-health.sh`, writer) and the health REPORT
# (`cycle-metrics.sh`, reader) — the same bug, one subsystem over. So the path
# rule lives in exactly one file and every participant asks it.
#
# WHERE IT POINTS
#
# The checkout is the one thing both userlands agree on, so the default lives
# under `.cache/metrics/` — gitignored, host-local machine state rather than
# project content. Falls back to `/tmp` when there is no writable checkout (a
# bare invocation, a read-only tree), so a forge or an out-of-repo call keeps
# working exactly as before.
#
# NOT `target/`, AND THIS IS LOAD-BEARING (macuahuitl, 2026-08-26). `target/`
# was the first choice and it is wrong: daily maintenance runs `cargo clean`
# (`check-build-cache-sweep.sh` fires above 40 GiB or a 14-day-old marker, from
# Finalization 9c and Start-Of-Day), and `cargo clean` removes the target
# directory WHOLESALE — taking `target/metrics/` with it. Measured in a
# throwaway crate: `target/metrics` 1 -> 0 across a clean, `.cache/metrics`
# 1 -> 1. And it is not hypothetical: that host's `target/` went 24 GiB -> 31
# GiB in a single cycle against a 40 GiB threshold.
#
# The failure would have been near-undetectable, which is why it is pinned:
# a routine GC silently resets every rolling series, and the reset looks
# EXACTLY like the documented one-time migration cost below. Someone would see
# `source=absent` months later, remember the migration note, and shrug at a
# sweep that had just eaten the history.
#
# A repo-relative path also fixes something `/tmp` never could: two worktrees
# on one host share `/tmp` and collide there, and do not collide here.
#
# The default deliberately does NOT vary by platform, though the bug it fixes is
# Windows-only. A path that differs by lane is the shape that produced three
# defects in eight hours on 2026-08-26 (`ps -o ppid=` absent on MSYS, GNU-only
# `du -sb`, GNU-only `\S`), and it would mean the next person debugging metrics
# must first work out which lane they are on. It also kept 902-j49y findable:
# that defect surfaced because a log reset on a path EVERY host shares, and a
# Windows-only path would have hidden it from everyone else.
#
# An explicit `TILLANDSIAS_*_LOG` env var always wins — every fixture that names
# its own log keeps working untouched.
#
# ONE-TIME COST, stated rather than hidden: a host with history in `/tmp` starts
# a fresh series here. The rolling views degrade gracefully — they report
# `source=absent` until the first append — so this costs recent averages, not
# correctness. That is the price of the numbers being attributable at all.

# metrics_default_log <basename> [repo_root]
# Prints an absolute path. Never fails; always prints something usable.
# ORDER 1268-m2ir. IS THIS A CHECKOUT? Not "is .git a directory".
#
# The previous test was `[ -d "$root/.git" ]`, and A GIT WORKTREE HAS .git AS A
# FILE containing "gitdir: ...". So did a submodule. For those the test answered
# "not a checkout" about a tree that unambiguously is one, and every metrics
# record went to /tmp — where cycle-metrics.sh's metrics-log-split guard then
# correctly refuses to publish, reddening the next release gate on that host.
# Reproduced on yoga 2026-09-20 with `git worktree add`: condition decided, and
# the records left the checkout.
_metrics_is_checkout() {
    [ -n "${1:-}" ] && [ -e "$1/.git" ]
}

# ORDER 1299-s2sv. THE JSON FIELDS THAT SAY WHERE A RECORD WAS WRITTEN FROM.
#
# Derived from the RESOLVED PATH in the caller's own shell, deliberately, not
# reported by metrics_default_log: that function's result is consumed through a
# command substitution, which is a SUBSHELL, so any global it sets is discarded
# before the caller can read it. Measured here on the first attempt — the
# variables came back empty in both the resolved and the fallback case.
#
# Emits a JSON fragment beginning with a comma, or nothing when it cannot tell.
#   resolved:  ,"root":"<checkout>"
#   fallback:  ,"root_unusable":"<candidate>","fallback_reason":"<why>"
# The canonical read is `.root // .root_unusable // "unknown"` (the absent-case
# rule on this row), which is why the fallback path must emit root_unusable:
# without it the chain has a hole exactly where the diagnosis is needed.
#
# ABSENT MEANS PRE-FIELD, NEVER /tmp. A record with none of these keys was
# written before this field existed; ~124k such records exist and they are not
# evidence about where they were written.
metrics_root_fields() {
    _mrf_path="${1:-}"
    case "$_mrf_path" in
        */.cache/metrics/*)
            _mrf_root="${_mrf_path%/.cache/metrics/*}"
            printf ',"root":"%s"' "$_mrf_root"
            return 0
            ;;
        /tmp/*)
            # ONLY THE RESOLVER'S OWN FALLBACK SHAPE COUNTS, which is exactly
            # /tmp/<basename> with nothing between. A caller naming its own log
            # under /tmp — TILLANDSIAS_TIMING_LOG=/tmp/whatever/t.jsonl, which is
            # what every fixture does — is NOT a fallback, and the first version
            # of this case labelled those records root_unusable. Caught by
            # emitting one: a throwaway log in a temp dir was reported as an
            # unusable checkout.
            case "${_mrf_path#/tmp/}" in
                */*) _metrics_root_of_process; return 0 ;;  # a caller's own path
            esac

            # Re-derive WHY by ASKING the same questions the resolver asked,
            # rather than assuming the remaining branch. The first version's
            # else-arm asserted cache-dir-not-creatable without testing mkdir,
            # so a perfectly writable checkout was blamed for a condition it did
            # not have — a reason that reads as measured and was not.
            _mrf_cand="${PROJECT_ROOT:-}"
            if [ -z "$_mrf_cand" ]; then
                _mrf_cand="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-.}")/.." 2>/dev/null && pwd)" || _mrf_cand=""
            fi
            if [ -z "$_mrf_cand" ]; then
                printf ',"root_unusable":"","fallback_reason":"no-candidate-root"'
            elif ! _metrics_is_checkout "$_mrf_cand"; then
                printf ',"root_unusable":"%s","fallback_reason":"not-a-checkout"' "$_mrf_cand"
            elif ! mkdir -p "$_mrf_cand/.cache/metrics" 2>/dev/null; then
                printf ',"root_unusable":"%s","fallback_reason":"cache-dir-not-creatable"' "$_mrf_cand"
            else
                # It is a checkout and the cache dir is creatable, yet the log
                # resolved to /tmp: the tree changed between the resolve and
                # this read. Say that rather than pick one of the above.
                printf ',"root_unusable":"%s","fallback_reason":"resolved-elsewhere-then-usable"' "$_mrf_cand"
            fi
            return 0
            ;;
        *)
            # A CALLER-NAMED LOG ANYWHERE ELSE. The record still knows which
            # checkout the PROCESS ran in, and saying so is the point of the
            # field. Emitting nothing here would make the record
            # indistinguishable from a pre-field one, and clause 3 of this row's
            # absent-case rule is that absent means PRE-FIELD — so leaving these
            # blank would put ~124k old records and every fixture's throwaway log
            # in the same bucket.
            _metrics_root_of_process
            return 0
            ;;
    esac
    return 0
}

# The checkout THIS PROCESS is running in, when there is one. Silent otherwise:
# a process genuinely outside any checkout has no root to report, and inventing
# one would be the same failure as reporting /tmp as a location.
_metrics_root_of_process() {
    _mrp="${PROJECT_ROOT:-}"
    if [ -z "$_mrp" ]; then
        _mrp="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-.}")/.." 2>/dev/null && pwd)" || _mrp=""
    fi
    [ -n "$_mrp" ] || return 0
    _metrics_is_checkout "$_mrp" || return 0
    printf ',"root":"%s"' "$_mrp"
}

metrics_default_log() {
    _mdl_base="${1:?metrics_default_log: basename required}"
    _mdl_root="${2:-}"
    _mdl_derived="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-.}")/.." 2>/dev/null && pwd)" || _mdl_derived=""

    # ORDER 1268-m2ir. CANDIDATES IN ORDER, first usable one wins: the root the
    # caller named, then PROJECT_ROOT when a parent exported one, then the root
    # derived from this library's own location. PROJECT_ROOT is consulted
    # because a runner that KNOWS where the checkout is should not be overruled
    # by a resolver guessing from its own path — arm 3 of the row.
    for _mdl_cand in "$_mdl_root" "${PROJECT_ROOT:-}" "$_mdl_derived"; do
        [ -n "$_mdl_cand" ] || continue
        _metrics_is_checkout "$_mdl_cand" || continue
        mkdir -p "$_mdl_cand/.cache/metrics" 2>/dev/null || continue
        printf '%s/.cache/metrics/%s' "$_mdl_cand" "$_mdl_base"
        return 0
    done

    # ORDER 1268-m2ir. THE FALLBACK STAYS, AND BECOMES LOUD. It is legitimate —
    # a tool run genuinely outside a checkout still needs somewhere to write —
    # but it was SILENT, so three different causes (not a checkout, .git is a
    # file, mkdir refused) produced one indistinguishable symptom and the only
    # evidence that anything had happened was a release gate reddening hours
    # later on a split log. One line, the reason and the cwd, on stderr so it
    # never contaminates the path on stdout.
    case "$_mdl_base" in
        *timing*) _mdl_label="timing-log" ;;
        *flow*)   _mdl_label="flow-log" ;;
        *usage*)  _mdl_label="usage-log" ;;
        *)        _mdl_label="metrics-log" ;;
    esac
    printf '%s: fallback:/tmp:no-checkout-from:%s\n' "$_mdl_label" "$PWD" >&2
    printf '/tmp/%s' "$_mdl_base"
}
