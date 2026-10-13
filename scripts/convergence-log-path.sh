#!/usr/bin/env bash
# @trace spec:ci-release, spec:meta-orchestration
# @trace order:888-vgs8, order:890-t9pu
#
# convergence-log-path.sh — one answer to "where does the convergence check
# log live", shared by every script that writes or reads it.
#
# WHY IT MOVED OUT OF target/ (order 888-vgs8). The index that
# skills/meta-orchestration/SKILL.md orders a reader to open FIRST when a gate
# fails lived at target/convergence/check-logs.jsonl, and the same skill's
# Finalization 9c orders `cargo clean` whenever check-build-cache-sweep.sh
# answers due — above 40 GiB or every 14 days. `cargo clean` removes target/
# WHOLESALE (measured in a throwaway crate for scripts/metrics-log-path.sh,
# 2026-08-26: target/metrics 1 -> 0 across a clean, .cache/metrics 1 -> 1), so
# the mandated sweep destroyed the mandated failure history, and nothing said
# so: the sweep's verdict named bytes and a marker date, never the file.
#
# The fix is the one the row's notes prefer and metrics-log-path.sh already
# took for the metrics series: MOVE the record out of target/, where everything
# is disposable by convention, rather than teach the sweep one exception — a
# second exception is a second thing to forget. The home is
# <checkout>/.cache/convergence/check-logs.jsonl: gitignored (`.cache/`),
# host-local, outside target/, and the same durable dir the metrics log uses.
#
# WHAT THIS PRINTS. One absolute path on stdout, exit 0, nothing else:
#
#   TILLANDSIAS_CHECK_LOG_INDEX   set    -> that value, verbatim, UNTOUCHED
#                                 unset  -> <checkout>/.cache/convergence/check-logs.jsonl
#
# The override is the contract every fixture relies on (1174-6r4k: a diagnostic
# run names its own scratch index so it never pollutes the host's record), so an
# explicit value is never second-guessed and never migrated into.
#
# ADOPTION, ONCE. Resolving the DEFAULT also carries the host's legacy history
# forward: when the new index is absent and target/convergence/check-logs.jsonl
# exists, the legacy file is COPIED into place and one line goes to stderr —
# `note:check-log-index:adopted-legacy:<records>`. Copied, never moved: the
# legacy file is deleted by the next `cargo clean`, which is exactly the fate
# this script exists to spare the record. A present new index is never touched,
# so the adoption happens on the first resolve after this change and never
# again — a legacy file that keeps growing (an older local-ci.sh still writing
# there) is NOT merged, because two writers racing into one JSONL is the
# defect metrics-log-path.sh was written to end.
#
# Readers resolve through here too, not only writers: a host that has legacy
# history but has not written since this change would otherwise answer
# `never:release-tier` from check-release-tier-freshness.sh about a tier it
# has exercised — a wrong answer about the very record this row protects.
set -u

if [ -n "${TILLANDSIAS_CHECK_LOG_INDEX:-}" ]; then
    printf '%s\n' "$TILLANDSIAS_CHECK_LOG_INDEX"
    exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || {
    echo "could-not-run:check-log-index:checkout root unreachable" >&2
    exit 3
}

INDEX="$ROOT/.cache/convergence/check-logs.jsonl"
LEGACY="$ROOT/target/convergence/check-logs.jsonl"

if [ ! -e "$INDEX" ] && [ -f "$LEGACY" ]; then
    if mkdir -p "$ROOT/.cache/convergence" 2>/dev/null && cp "$LEGACY" "$INDEX" 2>/dev/null; then
        _n="$(wc -l < "$INDEX" 2>/dev/null | tr -d ' ')"
        echo "note:check-log-index:adopted-legacy:${_n:-0}" >&2
    else
        # Say so rather than answer a path that silently lacks the history;
        # the path is still the right one, and the next writer creates it.
        rm -f "$INDEX" 2>/dev/null
        echo "warn:check-log-index:adopt-failed:$LEGACY -> $INDEX" >&2
    fi
fi

printf '%s\n' "$INDEX"
exit 0
