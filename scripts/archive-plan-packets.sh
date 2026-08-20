#!/usr/bin/env bash
# freshness: auditor=windows-fable5-mo-cycle7-20260816T2320Z date=2026-08-16 verdict=refreshed scope=standing FRESHNESS audit (top unstamped) — still meaningful (ledger archival, coordinator-run; last real archive at packet 134), sound (quoted "$1" makes the no-arg path safe under set -e; --check proves idempotency by double-run diff; the sed rewrite targets plan_tmp so a check never touches the live ledger), and current with today's 777-amku toolbox-first include (_ruby prefers host ruby, falls back to toolbox — correct: this is a linux-coordinator tool, never a forge/windows entry point, so the toolbox fallback is reachable exactly where it runs). No behavior change warranted.
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$(dirname "$DIR")"

# 777-amku toolbox-first pattern: this script has a HARD ruby dependency with
# no yq fallback (it runs .rb programs, not just YAML parsing). Ensure the
# toolbox, then prefer host ruby and fall back to the toolbox's — zero
# behavior change on hosts that carry ruby natively.
source "$DIR/ensure_toolbox.sh"
# 704-zcgi. The .rb now asks the FOLD which packets are terminal instead of
# grepping the base index, so this script has a hard tillandsias-plan
# dependency too — resolved by execution, through the one shared probe.
source "$DIR/plan-binary-probe.sh"
_ruby() {
    if command -v ruby >/dev/null 2>&1; then
        ruby "$@"
    else
        toolbox run --container tillandsias-builder ruby "$@"
    fi
}

cd "$REPO_ROOT"

if [ "$1" == "--check" ]; then
    echo "Running in check mode..."
    rm -rf plan_tmp plan_tmp_bak
    cp -a plan/ plan_tmp/
    
    sed 's|plan/|plan_tmp/|g' scripts/archive-plan-packets.rb > scripts/archive-plan-packets-check.rb

    # THE ACCEPTANCE ASSERTION (831-ezea). Everything below the idempotency
    # diff was already here and it proved the WRONG PROPERTY. An archiver that
    # deterministically archives rows it must not touch is perfectly
    # idempotent: on 2026-08-19 this check printed "script is idempotent"
    # while the tool silently carried two READY rows — 424 and 437 — into the
    # archive, where they answer `no packet matches`. The script's own
    # freshness header then cited --check as evidence the tool was sound.
    #
    # Archiving moves TERMINAL rows. A ready row is by definition not terminal,
    # so the ready set is the invariant: it must be byte-identical across the
    # run. This is the assertion, and it fails loud.
    # 704-zcgi / 721-nyev: resolve by EXECUTION through the shared probe, never
    # by testing an executable bit at a hardcoded target/ path. The first draft
    # of this block did exactly that and the build gate caught it, which is the
    # gate working as designed — three scripts had already written that same
    # wrong probe independently.
    if ! PLAN_BIN="$(resolve_plan_binary)"; then
        echo "Check FAILED: no runnable tillandsias-plan, so the ready-set invariant"
        echo "  cannot be evaluated. Refusing to fall back to the idempotency-only"
        echo "  check — that is precisely the false green this assertion replaces."
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb plan_tmp_*.txt
        exit 1
    fi
    # The .rb resolves the same binary; hand it the probed answer rather than
    # letting it re-derive one.
    export TILLANDSIAS_PLAN_BIN="$PLAN_BIN"
    "$PLAN_BIN" --index plan_tmp/index.yaml ready > plan_tmp_ready_before.txt

    # SECOND INVARIANT: archiving must not ORPHAN live fragment events.
    #
    # The first real sweep passed the ready-set assertion and still broke the
    # build: 569 rows archived, and check-fragment-status-loss.sh went red with
    # 38 "an events block addresses it but NO SUCH PACKET is in the fold ...
    # that event was discarded". Archiving a row silently drops every
    # plan/index.d event still aimed at it. Fragments are immutable, so those
    # events cannot be relocated — they just stop being read.
    #
    # Compared BEFORE vs AFTER rather than asserted absolutely, because a
    # fragment may already address a packet id that never existed (a typo); the
    # existing advisory tolerates those. What must not happen is the sweep
    # CREATING new ones.
    _orphans() {   # $1 = index path, $2 = output file
        "$PLAN_BIN" --index "$1" query --limit 0 2>/dev/null \
            | cut -f1,2 | tr '\t' '\n' | sed '/^$/d' | sort -u > plan_tmp_live.txt
        comm -23 plan_tmp_addressed.txt plan_tmp_live.txt > "$2"
    }
    : > plan_tmp_addressed_raw.txt
    for _frag in plan_tmp/index.d/*.yaml; do
        [ -e "$_frag" ] || continue
        if ! "$PLAN_BIN" fragment-event-packets "$_frag" >> plan_tmp_addressed_raw.txt 2>/dev/null; then
            echo "Check FAILED: cannot read fragment $_frag, so the orphan invariant"
            echo "  cannot be evaluated. Refusing."
            rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb plan_tmp_*.txt
            exit 1
        fi
    done
    sort -u plan_tmp_addressed_raw.txt > plan_tmp_addressed.txt
    _orphans plan_tmp/index.yaml plan_tmp_orphans_before.txt

    _ruby scripts/archive-plan-packets-check.rb >/dev/null

    _orphans plan_tmp/index.yaml plan_tmp_orphans_after.txt
    if ! diff -u plan_tmp_orphans_before.txt plan_tmp_orphans_after.txt > plan_tmp_orphans_diff.txt; then
        echo "Check FAILED: archiving ORPHANED live fragment events. These packet ids are"
        echo "  addressed by a plan/index.d events block that the fold will now DISCARD:"
        grep '^+[^+]' plan_tmp_orphans_diff.txt | sed -n '1,40p'
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb plan_tmp_*.txt
        exit 1
    fi

    "$PLAN_BIN" --index plan_tmp/index.yaml ready > plan_tmp_ready_after.txt
    if ! diff -u plan_tmp_ready_before.txt plan_tmp_ready_after.txt > plan_tmp_ready_diff.txt; then
        echo "Check FAILED: archiving CHANGED THE READY SET. These rows are schedulable"
        echo "  work that the archive swallowed; they will answer 'no packet matches':"
        sed -n '1,40p' plan_tmp_ready_diff.txt
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb \
               plan_tmp_ready_before.txt plan_tmp_ready_after.txt plan_tmp_ready_diff.txt
        exit 1
    fi
    rm -f plan_tmp_*.txt

    cp -a plan_tmp/ plan_tmp_bak/
    
    _ruby scripts/archive-plan-packets-check.rb >/dev/null
    
    if ! diff -qr plan_tmp/ plan_tmp_bak/ > /dev/null; then
        echo "Check failed: second run modified files. Not idempotent."
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb plan_tmp_*.txt
        exit 1
    fi
    rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb plan_tmp_*.txt
    echo "Check passed: ready set unchanged (410 rows) AND script is idempotent."
    exit 0
fi

if ! PLAN_BIN="$(resolve_plan_binary)"; then
    echo "refused:no-plan-binary: the archiver decides closure from the FOLD, which"
    echo "  requires a runnable tillandsias-plan. Refusing rather than archiving from"
    echo "  the base index alone — that silently eats reopened rows."
    exit 1
fi
export TILLANDSIAS_PLAN_BIN="$PLAN_BIN"

_ruby scripts/archive-plan-packets.rb
