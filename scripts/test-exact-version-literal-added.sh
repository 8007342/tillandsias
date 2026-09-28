#!/usr/bin/env bash
# @trace order:968-uhzg, spec:methodology-accountability
#
# Fixture for scripts/check-exact-version-literal-added.sh (order 968-uhzg),
# over a scratch repo whose origin/linux-next is its first commit:
#
#   1. an ADDED `.schema_version == 2` (jq) is REFUSED, naming file:line;
#   2. an added `[ "$version" -eq 3 ]` (shell) and `self.version != 1` (Rust)
#      are refused too — the class, not one spelling;
#   3. the same exact literal WITH an `exact-version: <reason>` marker just
#      above is admitted: an exact pin is allowed when it says why;
#   4. a comparison against a NAMED constant, and a floor (>=), are admitted;
#   5. NEGATIVE CONTROL: a pre-existing exact literal (in the base) is not
#      re-litigated — the guard is diff-scoped;
#   6. the fixed validator: host-capability-probe.sh's own validation filter
#      admits a BUMPED schema (4) and still refuses a schema below its floor (1).
#
# PRE-FIX RESULT: FAILS — the guard did not exist, and an exact pin made the
# first bump of the capability row unpublishable (lenovinha, 2026-09-02).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-exact-version-literal-added.sh"
pass=0; total=6
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

[ -f "$GUARD" ] || { echo "fail:exact-version-literal-added-fixture:0/$total (guard missing)"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "skip:exact-version-literal-added-fixture:no-git"; exit 0; }
_plan="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/exact-version.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# repo <name> <base content of scripts/v.sh> -> a scratch repo whose base holds it
repo() {
    local r="$W/$1"
    mkdir -p "$r/scripts" "$r/crates/c/src"
    cp "$GUARD" "$r/scripts/"
    printf '%s\n' "$2" > "$r/scripts/v.sh"
    git -C "$r" init -q && git -C "$r" -c user.email=f@x -c user.name=f add -A \
        && git -C "$r" -c user.email=f@x -c user.name=f commit -qm base
    git -C "$r" update-ref refs/remotes/origin/linux-next HEAD
    echo "$r"
}
run() { OUT="$(cd "$1" && bash scripts/check-exact-version-literal-added.sh 2>&1)"; RC=$?; }

# 1 — an added jq exact pin is refused, by file:line.
R="$(repo one '#!/bin/bash')"
printf '#!/bin/bash\njq -e ".schema_version == 2" doc.json\n' > "$R/scripts/v.sh"
run "$R"
if [ "$RC" -eq 1 ] && grep -q '^violation:exact-version-literal-added:1$' <<<"$OUT" && grep -q 'scripts/v.sh:2' <<<"$OUT"; then
    ok "arm 1: an added .schema_version == 2 is refused, naming scripts/v.sh:2"
else
    bad "arm 1: rc=$RC [$OUT]"
fi

# 2 — the class, not one spelling: shell -eq and Rust != literal.
R="$(repo two '#!/bin/bash')"
printf '#!/bin/bash\n[ "$version" -eq 3 ] || exit 1\n' > "$R/scripts/v.sh"
printf 'fn f(t: &T) -> bool {\n    if t.version != 1 {\n        return false;\n    }\n    true\n}\n' > "$R/crates/c/src/lib.rs"
run "$R"
if [ "$RC" -eq 1 ] && grep -q '^violation:exact-version-literal-added:2$' <<<"$OUT"; then
    ok "arm 2: shell -eq 3 and Rust != 1 are both refused (2 sites)"
else
    bad "arm 2: rc=$RC [$OUT]"
fi

# 3 — an exact literal that states its reason is admitted.
R="$(repo three '#!/bin/bash')"
printf '#!/bin/bash\n# exact-version: the v2 on-disk header is the only layout this reader parses\n[ "$version" -eq 2 ] || exit 1\n' > "$R/scripts/v.sh"
run "$R"
[ "$RC" -eq 0 ] && grep -q '^ok:exact-version-literal-added:' <<<"$OUT" \
    && ok "arm 3: an exact literal with an exact-version: reason is admitted" \
    || bad "arm 3: rc=$RC [$OUT]"

# 4 — a named constant and a floor are admitted.
R="$(repo four '#!/bin/bash')"
printf '#!/bin/bash\njq -e ".schema_version >= 2" doc.json\n' > "$R/scripts/v.sh"
printf 'fn f(t: &T) -> bool {\n    t.version == SCHEMA_VERSION\n}\n' > "$R/crates/c/src/lib.rs"
run "$R"
[ "$RC" -eq 0 ] && ok "arm 4: a floor (>=) and a named-constant comparison are admitted" \
    || bad "arm 4: rc=$RC [$OUT]"

# 5 — NEGATIVE CONTROL: a pin already in the base is not re-litigated.
R="$(repo five "$(printf '#!/bin/bash\njq -e ".schema_version == 2" doc.json')")"
printf '#!/bin/bash\njq -e ".schema_version == 2" doc.json\necho unrelated addition\n' > "$R/scripts/v.sh"
run "$R"
[ "$RC" -eq 0 ] && ok "arm 5: a pre-existing exact pin is not re-litigated (diff-scoped)" \
    || bad "arm 5: rc=$RC [$OUT]"

# 6 — the fixed validator admits a bumped schema and refuses one below its floor.
if [ -z "$_plan" ]; then
    bad "arm 6: no plan binary to evaluate the probe's validation filter"
else
    # The probe's own validation filter, cut from its source (first match).
    probe_src="$(grep -oE "'[.]schema_version >= [0-9]+[^']*'" "$ROOT/scripts/host-capability-probe.sh")"
    filter="${probe_src%%$'\n'*}"; filter="${filter#\'}"; filter="${filter%\'}"
    doc_v='{"schema_version":%s,"host":{"host_id":"h"}}'
    bumped="$(printf "$doc_v" 4 | "$_plan" json get -e "$filter" 2>/dev/null)"; rb=$?
    below="$(printf "$doc_v" 1 | "$_plan" json get -e "$filter" 2>/dev/null)"; rl=$?
    if [ -n "$filter" ] && [ "$rb" -eq 0 ] && [ "$bumped" = true ] && [ "$rl" -ne 0 ]; then
        ok "arm 6: the capability probe's validator admits schema_version 4 and refuses 1 (filter: $filter)"
    else
        bad "arm 6: filter=[$filter] bumped=[$bumped] rc=$rb below rc=$rl"
    fi
fi

if [ "$pass" -eq "$total" ]; then
    echo "ok:exact-version-literal-added-fixture:$pass/$total"
    exit 0
fi
echo "fail:exact-version-literal-added-fixture:$pass/$total"
exit 1
