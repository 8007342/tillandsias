#!/usr/bin/env bash
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
