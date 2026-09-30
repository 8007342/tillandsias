#!/usr/bin/env bash
# @trace order:815-yace, spec:ci-release
#
# test-spec-script-paths.sh — check-spec-script-paths.sh refuses a spec that
# names a script the tree does not have, and says so by name.
#   1 LIVE: the real specs against the real baseline -> ok
#   2 a seeded spec naming a missing script -> blocked, named
#   3 the same line marked `spec-path-absent: ok (<reason>)` -> ok, counted exempt
#   4 THE ROW'S OWN CRITERION: the PRE-FIX project-summarizers spec (pinned at
#     b6fe04b4f, before any correction) with an EMPTY baseline -> blocked,
#     naming all six summarizer paths
#   5 a baseline entry whose path now resolves -> ok, with a burndown note
#   6 no spec names any script -> unavailable (exit 2), never ok
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-spec-script-paths.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/spec-script-paths.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

# A scratch world: one spec dir, one resolution root, one baseline.
world() { # world <name>
    mkdir -p "$W/$1/specs/demo" "$W/$1/root/scripts"
    : > "$W/$1/baseline.txt"
}
run() { # run <name> -> stdout+stderr in $W/<name>.out, rc in $W/<name>.rc
    TILLANDSIAS_SPEC_PATHS_SPECS="$W/$1/specs" TILLANDSIAS_SPEC_PATHS_ROOT="$W/$1/root" \
        TILLANDSIAS_SPEC_PATHS_BASELINE="$W/$1/baseline.txt" bash "$CHECK" > "$W/$1.out" 2>&1
    echo $? > "$W/$1.rc"
}

out="$(bash "$CHECK" 2>&1)"; rc=$?
case "$out" in *ok:spec-script-paths:*) [ "$rc" = 0 ] && ok "1: LIVE tree is ok ($(tail -n 1 <<< "$out"))" || bad "1: rc=$rc" ;;
    *) bad "1: live tree answered [$(tail -n 1 <<< "$out")] rc=$rc" ;; esac

world a
printf 'The gate MUST run `scripts/present.sh` and `scripts/missing-thing.sh`.\n' > "$W/a/specs/demo/spec.md"
: > "$W/a/root/scripts/present.sh"
run a
if [ "$(cat "$W/a.rc")" = 1 ] && grep -q '^blocked:spec-script-paths:1-unresolved$' "$W/a.out" \
    && grep -q 'scripts/missing-thing.sh' "$W/a.out" && ! grep -q 'violation:.*present.sh' "$W/a.out"; then
    ok "2: a missing script is refused by name; the present one is not"
else
    bad "2: a missing script was not refused by name ($(tail -n 1 "$W/a.out"), rc=$(cat "$W/a.rc"))"
fi

world b
printf 'The tray MUST NOT invoke `scripts/missing-thing.sh`. <!-- spec-path-absent: ok (a negative requirement) -->\n' > "$W/b/specs/demo/spec.md"
run b
if [ "$(cat "$W/b.rc")" = 0 ] && grep -q '1-exempt$' "$W/b.out"; then
    ok "3: a marked negative requirement is exempt and counted"
else
    bad "3: a marked line was not exempt ($(tail -n 1 "$W/b.out"))"
fi

world c
mkdir -p "$W/c/specs/project-summarizers"
if git -C "$ROOT" show b6fe04b4f:openspec/specs/project-summarizers/spec.md > "$W/c/specs/project-summarizers/spec.md" 2>/dev/null; then
    rm -rf "$W/c/specs/demo" "$W/c/root"
    mkdir -p "$W/c/root"
    ln -s "$ROOT/scripts" "$W/c/root/scripts"
    run c
    n="$(grep -c '^violation:spec-script-paths:.*scripts/summarizers/summarize-' "$W/c.out")"
    if [ "$(cat "$W/c.rc")" = 1 ] && [ "$n" = 6 ]; then
        ok "4: the pre-fix project-summarizers spec is refused, all six summarizer paths named"
    else
        bad "4: the pre-fix project-summarizers spec answered rc=$(cat "$W/c.rc") with $n named ($(tail -n 1 "$W/c.out"))"
    fi
else
    bad "4: cannot read the pinned pre-fix spec at b6fe04b4f (shallow clone?)"
fi

world d
printf 'Run `scripts/now-here.sh`.\n' > "$W/d/specs/demo/spec.md"
: > "$W/d/root/scripts/now-here.sh"
printf '%s\t%s\t%s\n' "$W/d/specs/demo/spec.md" scripts/now-here.sh "was missing" > "$W/d/baseline.txt"
run d
if [ "$(cat "$W/d.rc")" = 0 ] && grep -q 'now RESOLVES' "$W/d.out"; then
    ok "5: a baselined path that now resolves prints the burndown note"
else
    bad "5: no burndown note for a resolved baseline entry ($(cat "$W/d.out" | tr '\n' ' '))"
fi

world e
printf 'No scripts here.\n' > "$W/e/specs/demo/spec.md"
run e
if [ "$(cat "$W/e.rc")" = 2 ] && grep -q '^unavailable:spec-script-paths:' "$W/e.out"; then
    ok "6: a spec set naming no script is unavailable, never ok"
else
    bad "6: an empty population answered rc=$(cat "$W/e.rc") ($(tail -n 1 "$W/e.out"))"
fi

if [ "$fail" -eq 0 ]; then echo "PASS: spec-script-paths $pass/$((pass + fail))"; exit 0; fi
echo "FAIL: spec-script-paths $pass/$((pass + fail))"; exit 1
