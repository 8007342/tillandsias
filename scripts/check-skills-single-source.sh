#!/usr/bin/env bash
# @trace spec:methodology-accountability
#
# Order 631-wpkd. Canonical `skills/` is the single source of truth; every
# runtime reaches a skill through a symlink into it.
#
# WHY THIS IS A CHECK AND NOT A CONVENTION
#
# The layout section already CLAIMED this, and on 2026-08-09 an audit found it
# false: thirteen skills existed only under `.claude/skills/`, including
# `build-macos-tray` — a macOS BUILD skill that agents launched under opencode,
# codex or gemini simply did not have. What a host can do must not depend on
# which harness started it, and a claim in prose could not notice that it had
# stopped being true.
#
# It drifts in BOTH directions, which is why both are checked:
#   * a real directory where a symlink belongs = a second source of truth;
#   * a canonical skill missing from a runtime = a skill that host cannot see.
# The second was still live on 2026-08-13: `multihost-orchestration` was linked
# from .gemini ONLY, and `hello-world` from two runtimes of five.
#
# THE INDEX, NOT THE FILESYSTEM. `git ls-files -s` reports mode 120000 for a
# symlink regardless of what the working tree materialized. A Windows checkout
# without symlink support turns them into real directories on disk, so a
# filesystem test would report every entry as a violation on exactly the host
# most likely to be running this. The committed shape is the shape that matters.
#
# Declared exceptions live in skills/HARNESS-SCOPED.txt with their reason.
#
# Grammar (exactly one line on stdout):
#   ok:skills-single-source:<runtimes>:<canonical>
#   violation:second-source:<runtime>/<skill>
#   violation:missing-from-runtime:<runtime>/<skill>
#   skip:not-a-git-repo
#
# Exit 0 on ok/skip, 1 on violation.

set -uo pipefail

ROOT="${SKILLS_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" 2>/dev/null || { echo "skip:not-a-git-repo"; exit 0; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "skip:not-a-git-repo"; exit 0; }

RUNTIMES="${SKILLS_CHECK_RUNTIMES:-.claude .opencode .codex .github .gemini}"
DECL="$ROOT/skills/HARNESS-SCOPED.txt"

is_declared() { # <skill>
    [ -f "$DECL" ] || return 1
    while IFS= read -r pattern; do
        case "$pattern" in ''|'#'*) continue ;; esac
        # shellcheck disable=SC2254 — the pattern is a glob on purpose.
        case "$1" in $pattern) return 0 ;; esac
    done < "$DECL"
    return 1
}

canonical="$(git ls-files skills/ | sed 's|^skills/||' | cut -d/ -f1 | sort -u | grep -v '^HARNESS-SCOPED.txt$')"
[ -n "$canonical" ] || { echo "skip:not-a-git-repo"; exit 0; }

runtime_count=0
for d in $RUNTIMES; do
    git ls-files "$d/skills" | head -1 | grep -q . || continue
    runtime_count=$((runtime_count + 1))

    # Direction 1: a real entry where a symlink belongs.
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        is_declared "$entry" && continue
        echo "violation:second-source:$d/skills/$entry"
        exit 1
    done <<EOF
$(git ls-files -s "$d/skills" | awk '$1!="120000"{print $4}' | sed "s|^$d/skills/||" | cut -d/ -f1 | sort -u)
EOF

    # Direction 2: a canonical skill this runtime cannot see.
    for s in $canonical; do
        git ls-files -s "$d/skills/$s" | grep -q '^120000' && continue
        is_declared "$s" && continue
        echo "violation:missing-from-runtime:$d/skills/$s"
        exit 1
    done
done

echo "ok:skills-single-source:$runtime_count:$(printf '%s\n' "$canonical" | grep -c .)"
exit 0
