#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$(dirname "$DIR")"

cd "$REPO_ROOT"

if [ "$1" == "--check" ]; then
    echo "Running in check mode..."
    # Copy plan/index.yaml to a temp file
    cp plan/index.yaml plan/index.yaml.bak
    ruby scripts/archive-plan-packets.rb
    # If the file changed, it was not fully archived or not idempotent
    if ! cmp -s plan/index.yaml plan/index.yaml.bak; then
        echo "Check failed: plan/index.yaml was modified."
        mv plan/index.yaml.bak plan/index.yaml
        exit 1
    fi
    mv plan/index.yaml.bak plan/index.yaml
    echo "Check passed: script is idempotent."
    exit 0
fi

ruby scripts/archive-plan-packets.rb
