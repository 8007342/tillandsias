#!/usr/bin/env bash
# centicolon-backfill.sh — score completed work ONLY where the ledger already
# pins the obligation state, and say UNSCORED everywhere else.
# @trace order:977-3dee, order:976-kk6x
#
# THE RULING THIS IMPLEMENTS (coordinator, 2026-09-03 at 7f5fbeac1), on an
# objection raised before the rung was built: a score computed retroactively
# over work whose obligations were never tracked would be derived from the
# ledger's RECORD of the work rather than the work's actual obligation states —
# measuring HOW WELL PAST ROWS WERE WRITTEN UP while being read as how well the
# work discharged its obligations.
#
# So: backfill only rows whose evidence already PINS a state, mark every other
# row explicitly UNSCORED (a first-class value, exactly as `unsupported` is for
# the experts), and TAG every backfilled value with its derivation so a consumer
# can tell a measured score from an inferred one without reading this file.
#
# ── WHAT CAN HONESTLY BE PINNED, AND IT IS LESS THAN IT LOOKS ────────────────
#
# MEASURED on the folded ledger, 2026-09-03: 563 packets, 125 with
# `evidence_refs`, 112 with a `verifiable_closure`. But evidence_refs are FREE
# TEXT — "plan/issues/network-architecture-audit-2026-07-09.md (DRAFT v1
# section)" — and reading a state out of prose is precisely the inference the
# ruling forbids. Only ~10 carry a machine-shaped token at all.
#
# `verifiable_closure` is the one structured source: 25 of the 112 name a
# `litmus:<test>`, over 22 distinct tests.
#
# AND NAMING A TEST IS NOT PASSING IT. This is the distinction that decides the
# whole rung. A closure that names a RESOLVABLE litmus test establishes that a
# verification path exists and resolves — that is `traced`. It does NOT
# establish `positively_tested`, because the ledger does not carry the test's
# RESULT, and treating a declared closure as a passing one would score the
# DECLARATION while presenting it as evidence. That is the same error one layer
# down from the one the ruling already rejected.
#
# So the honest retroactive ceiling is `traced`, and the coverage figure is
# small. Both are findings, not shortfalls: the ledger can currently evidence
# only the tracing rung retroactively, and a coverage number that starts low and
# rises is a measurement, where a dense inferred one is not.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

. scripts/plan-binary-probe.sh
PLAN="$(resolve_plan_binary)" || { echo "blocked:backfill:no-plan-binary" >&2; exit 2; }

INDEX="${1:-plan/index.yaml}"

# Every litmus test name that actually exists, so a closure naming a phantom
# test is NOT counted as traced — `declared-closures` reports 4 such rows today
# and scoring them would credit a path that does not resolve.
known_tests="$(grep -rhoE '^[[:space:]]*(- )?name:[[:space:]]*litmus:[a-z0-9-]+' \
    openspec/litmus-tests/ 2>/dev/null | grep -oE 'litmus:[a-z0-9-]+' | sort -u)"

scored=0
unscored=0
unresolvable=0
rows_out="$(mktemp)"
scored_rows="$(mktemp)"
trap 'rm -f "$rows_out" "$scored_rows"' EXIT

# One pass over the folded ledger. Awk emits `<packet_id>\t<closure-text>` so
# the shell never re-parses YAML.
"$PLAN" --index "$INDEX" yaml-json "$INDEX" 2>/dev/null \
  | "${JQ:-jq}" -r '
      (.releases // {}) as $r
      | [ .. | objects | select(has("packet_id")) ]
      | .[]
      | [ .packet_id,
          ((.verifiable_closure // "") | gsub("\n"; " ")) ] | @tsv' 2>/dev/null \
  > "$rows_out" || { echo "blocked:backfill:ledger-unreadable" >&2; exit 2; }

while IFS=$'\t' read -r pid closure; do
    [ -n "$pid" ] || continue
    test_name="$(printf '%s' "$closure" | grep -oE 'litmus:[a-z0-9-]+' | head -1)"
    if [ -z "$test_name" ]; then
        unscored=$((unscored + 1))
        continue
    fi
    # ORDER 795-imz3: NOT `if ! printf … | grep -q …`. `grep -q` exits on its
    # first match, the SIGPIPE reaches printf, and under `set -o pipefail` the
    # pipeline's status can become the signal's — inverting the guard, so an
    # unknown test would read as known. Match against the newline-delimited list
    # with a case glob instead: no pipeline, no signal, no inversion.
    case "
$known_tests
" in
        *"
$test_name
"*) : ;;
        *)
            # Named a test that does not exist. NOT scored — crediting it would
            # credit a verification path that cannot run.
            unresolvable=$((unresolvable + 1))
            unscored=$((unscored + 1))
            continue
            ;;
    esac

    scored=$((scored + 1))
    printf '%s\t%s\n' "$pid" "$test_name" >> "$scored_rows"
done < "$rows_out"

total=$((scored + unscored))
[ "$total" -gt 0 ] || { echo "blocked:backfill:no-rows" >&2; exit 2; }
pct=$((scored * 1000 / total))

# ── --emit-fragment: write the scores as DATA, tagged with their derivation ──
#
# CRDT-style, per the operator: one NEW fragment file keyed by packet_id, never
# a read-modify-write of a shared file. Two concurrent backfills write two
# fragments and the fold takes both.
#
# EVERY ROW CARRIES `derivation` AND `state`, so a consumer reading only the
# data can tell a backfilled value from a measured one WITHOUT reading the
# packet — which is exactly what the ruling rejected the name-the-field-
# approximate option for. And the ceiling is stated per row rather than
# globally, because a later source that can pin `positively_tested` must not
# silently inherit this one's meaning.
if [ "${EMIT:-0}" = "1" ]; then
    out="plan/index.d/$(date -u +%Y%m%dt%H%M%Sz)-centicolon-backfill-$(hostname -s | tr 'A-Z' 'a-z').yaml"
    {
        echo "# Ledger fragment — append-only, IMMUTABLE once written."
        echo "# ORDER 977-3dee: retroactive centicolon backfill."
        echo "#"
        echo "# Rows appear here ONLY when the ledger already pinned their state."
        echo "# Every other row is UNSCORED and is deliberately ABSENT rather than"
        echo "# present with a zero — a default would be indistinguishable from a"
        echo "# measured nothing, which is the whole objection this rung answers."
        echo "events:"
        while IFS=$'\t' read -r pid test_name; do
            [ -n "$pid" ] || continue
            echo "  - packet_id: $pid"
            echo "    event:"
            echo "      type: note"
            echo "      ts: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
            echo "      host: $(hostname -s | tr 'A-Z' 'a-z')"
            echo "      summary: >"
            echo "        centicolon-backfill (977-3dee): obligation state TRACED."
            echo "        derivation=verifiable_closure-names-a-resolvable-litmus-test"
            echo "        evidence=$test_name ceiling=traced"
            echo "        NOT positively_tested — the ledger carries the closure's NAME,"
            echo "        not the test's RESULT, and crediting a declared closure as a"
            echo "        passing one would score the declaration while presenting it as"
            echo "        evidence."
        done < "$scored_rows"
    } > "$out"
    echo "emitted: $out"
fi

# COVERAGE IS REPORTED AS A FIGURE, so sparseness is visible rather than
# implied. A consumer reading only this line can tell how much of the ledger the
# score speaks for.
printf 'ok:centicolon-backfill scored=%d unscored=%d total=%d coverage=%d.%d%% ceiling=traced unresolvable-closures=%d derivation=verifiable_closure-names-a-resolvable-litmus-test\n' \
    "$scored" "$unscored" "$total" "$((pct / 10))" "$((pct % 10))" "$unresolvable"
