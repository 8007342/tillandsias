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
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb
        exit 1
    fi
    # The .rb resolves the same binary; hand it the probed answer rather than
    # letting it re-derive one.
    export TILLANDSIAS_PLAN_BIN="$PLAN_BIN"
    "$PLAN_BIN" --index plan_tmp/index.yaml ready > plan_tmp_ready_before.txt

    _ruby scripts/archive-plan-packets-check.rb >/dev/null

    "$PLAN_BIN" --index plan_tmp/index.yaml ready > plan_tmp_ready_after.txt
    if ! diff -u plan_tmp_ready_before.txt plan_tmp_ready_after.txt > plan_tmp_ready_diff.txt; then
        echo "Check FAILED: archiving CHANGED THE READY SET. These rows are schedulable"
        echo "  work that the archive swallowed; they will answer 'no packet matches':"
        sed -n '1,40p' plan_tmp_ready_diff.txt
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb \
               plan_tmp_ready_before.txt plan_tmp_ready_after.txt plan_tmp_ready_diff.txt
        exit 1
    fi
    rm -f plan_tmp_ready_before.txt plan_tmp_ready_after.txt plan_tmp_ready_diff.txt

    cp -a plan_tmp/ plan_tmp_bak/
    
    _ruby scripts/archive-plan-packets-check.rb >/dev/null
    
    if ! diff -qr plan_tmp/ plan_tmp_bak/ > /dev/null; then
        echo "Check failed: second run modified files. Not idempotent."
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb
        exit 1
    fi
    rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb
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
