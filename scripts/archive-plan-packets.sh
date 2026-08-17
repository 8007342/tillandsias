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
    
    _ruby scripts/archive-plan-packets-check.rb >/dev/null
    
    cp -a plan_tmp/ plan_tmp_bak/
    
    _ruby scripts/archive-plan-packets-check.rb >/dev/null
    
    if ! diff -qr plan_tmp/ plan_tmp_bak/ > /dev/null; then
        echo "Check failed: second run modified files. Not idempotent."
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb
        exit 1
    fi
    rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb
    echo "Check passed: script is idempotent."
    exit 0
fi

_ruby scripts/archive-plan-packets.rb
