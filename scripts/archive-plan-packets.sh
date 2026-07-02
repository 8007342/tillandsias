#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$(dirname "$DIR")"

cd "$REPO_ROOT"

if [ "$1" == "--check" ]; then
    echo "Running in check mode..."
    rm -rf plan_tmp plan_tmp_bak
    cp -a plan/ plan_tmp/
    
    sed 's|plan/|plan_tmp/|g' scripts/archive-plan-packets.rb > scripts/archive-plan-packets-check.rb
    
    ruby scripts/archive-plan-packets-check.rb >/dev/null
    
    cp -a plan_tmp/ plan_tmp_bak/
    
    ruby scripts/archive-plan-packets-check.rb >/dev/null
    
    if ! diff -qr plan_tmp/ plan_tmp_bak/ > /dev/null; then
        echo "Check failed: second run modified files. Not idempotent."
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb
        exit 1
    fi
    rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb
    echo "Check passed: script is idempotent."
    exit 0
fi

ruby scripts/archive-plan-packets.rb
