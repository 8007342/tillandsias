#!/usr/bin/env bash
# @trace order:1443-w79y, spec:branch-discipline
#
# Fixture for the branch-discipline seed and `tillandsias-plan discipline`
# (order 1443-w79y). One arm per exit criterion:
#
#   1. `discipline target --platform macos|forge` answers osx-next|linux-next
#      from THIS repository's seed, with source=seed level=2.
#   2. `check-ref` on this seed: main is refused (enforced) with why: and the
#      seed's substituted message as remedy:; a work ref is ok; feature-x is
#      warn (the grammar rule is at warn here) — and refused against a
#      fixture seed holding that rule at enforced.
#   3. FLOOR: a scratch project with NO seed answers
#      ok:discipline:default-branch:level=0 for main and refuses nothing.
#   4. `show --json` carries digest == `hash sha256` of the seed.
#   5. a seed whose integration branch equals the default at level >= 1, whose
#      work_ref regex does not compile, or whose level is below a published
#      level, is refused:discipline-seed:<reason> and the answer comes from
#      the built-in default (source=default level=0).
#   6. the forge-plan MCP server lists discipline_show, and tools/call returns
#      the same JSON as the verb.
#
# PRE-FIX RESULT: FAILS at arm 1 — there was no `discipline` verb.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; total=6
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

_validator="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _validator=""
case "$_validator" in ./*) _validator="$ROOT/${_validator#./}" ;; esac
if [ -z "$_validator" ]; then
    echo "skip:branch-discipline-verb:no-validator — build one: cargo build --release -p tillandsias-plan"
    exit 0
fi
PLAN="$_validator"
# Reads go through the plan binary's `json get`, not jq (1375-tsfu ratchet).
# jq is still needed by the forge-plan MCP server that arm 6 drives.
command -v jq >/dev/null 2>&1 || { echo "skip:branch-discipline-verb:no-jq-for-the-mcp-server"; exit 0; }
jget() { "$PLAN" json get "$@"; }
command -v git >/dev/null 2>&1 || { echo "skip:branch-discipline-verb:no-git"; exit 0; }

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/branch-discipline.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

dis() { "$PLAN" discipline "$@"; }
SEED="$ROOT/.tillandsias/branch-discipline.yaml"

# 1 — targets from this repository's seed.
mac="$(dis target --platform macos --root "$ROOT" 2>&1)"
forge="$(dis target --platform forge --root "$ROOT" 2>&1)"
if [ "$mac" = "osx-next source=seed level=2 enforcement=-" ] \
   && [ "$forge" = "linux-next source=seed level=2 enforcement=-" ]; then
    ok "arm 1: target macos=osx-next forge=linux-next, source=seed level=2"
else
    bad "arm 1: got macos='$mac' forge='$forge'"
fi

# 2 — check-ref at each rule's enforcement.
main_out="$(dis check-ref refs/heads/main --root "$ROOT" 2>&1)"; main_rc=$?
work_out="$(dis check-ref refs/heads/work/1443-w79y --root "$ROOT" 2>&1)"; work_rc=$?
feat_out="$(dis check-ref refs/heads/feature-x --root "$ROOT" 2>&1)"; feat_rc=$?
sed 's/ref_grammar: warn/ref_grammar: enforced/' "$SEED" > "$W/strict.yaml"
strict_out="$(dis check-ref refs/heads/feature-x --root "$ROOT" --seed "$W/strict.yaml" 2>&1)"; strict_rc=$?
arm2=1
[ "$main_rc" -eq 1 ] && [ "$(printf '%s\n' "$main_out" | sed -n 1p)" = "refused:discipline:default-branch-protected:enforced" ] || arm2=0
printf '%s\n' "$main_out" | grep -q '^why: ' || arm2=0
printf '%s\n' "$main_out" | grep -q '^remedy: push to main denied: this project uses branch linux-next|osx-next|windows-next for integration and work/' || arm2=0
[ "$work_rc" -eq 0 ] && [ "$(printf '%s\n' "$work_out" | sed -n 1p)" = "ok:discipline:work-ref" ] || arm2=0
[ "$feat_rc" -eq 0 ] && [ "$(printf '%s\n' "$feat_out" | sed -n 1p)" = "warn:discipline:ref-outside-grammar" ] || arm2=0
[ "$strict_rc" -eq 1 ] && [ "$(printf '%s\n' "$strict_out" | sed -n 1p)" = "refused:discipline:ref-outside-grammar:enforced" ] || arm2=0
if [ "$arm2" = 1 ]; then
    ok "arm 2: main refused (enforced, seeded remedy), work ref ok, feature-x warn here and refused under an enforced seed"
else
    bad "arm 2: main rc=$main_rc [$main_out] | work rc=$work_rc [$work_out] | feature rc=$feat_rc [$feat_out] | strict rc=$strict_rc [$strict_out]"
fi

# 3 — the floor: a bare project with no seed is never refused.
BARE="$W/bare"; mkdir -p "$BARE"
git -C "$BARE" -c init.defaultBranch=main init -q
bare_main="$(dis check-ref refs/heads/main --root "$BARE" 2>&1)"; bare_rc=$?
bare_other="$(dis check-ref refs/heads/anything-at-all --root "$BARE" 2>&1)"; other_rc=$?
if [ "$bare_rc" -eq 0 ] && [ "$(printf '%s\n' "$bare_main" | sed -n 1p)" = "ok:discipline:default-branch:level=0" ] \
   && printf '%s\n' "$bare_main" | grep -q '^source=default level=0 enforcement=advised$' \
   && [ "$other_rc" -eq 0 ]; then
    ok "arm 3: no seed -> ok:discipline:default-branch:level=0, source=default level=0 enforcement=advised, nothing refused"
else
    bad "arm 3: main rc=$bare_rc [$bare_main] | other rc=$other_rc [$bare_other]"
fi

# 4 — the published digest is the seed's sha256.
digest="$(dis show --json --root "$ROOT" 2>/dev/null | jget -r '.digest')"
want="$("$PLAN" hash sha256 "$SEED" 2>/dev/null)"
if [ -n "$want" ] && [ "$digest" = "$want" ]; then
    ok "arm 4: show --json digest equals hash sha256 of the seed"
else
    bad "arm 4: digest='$digest' want='$want'"
fi

# 5 — bad seeds are refused at load and answered from the floor.
sed 's/macos: osx-next/macos: main/' "$SEED" > "$W/eq.yaml"
sed 's/work\/\[0-9\]{3,4}-\[a-z0-9\]{4}/work\/[0-9/' "$SEED" > "$W/re.yaml"
sed 's/^level: 2$/level: 1/' "$SEED" > "$W/low.yaml"
REG="$W/regressed"; mkdir -p "$REG"
git -C "$REG" -c init.defaultBranch=main init -q
git -C "$REG" -c user.name=f -c user.email=f@f commit -q --allow-empty -m seed
git -C "$REG" update-ref refs/tillandsias/discipline/2/enforced/0000/1 HEAD
arm5=1; detail=""
for case_ in "eq.yaml|$ROOT|integration-equals-default:macos" \
             "re.yaml|$ROOT|work-ref-regex" \
             "low.yaml|$REG|level-regressed:1<2"; do
    f="${case_%%|*}"; rest="${case_#*|}"; root="${rest%%|*}"; reason="${rest#*|}"
    err="$(dis show --json --root "$root" --seed "$W/$f" 2>&1 >/dev/null)"
    json="$(dis show --json --root "$root" --seed "$W/$f" 2>/dev/null)"
    src="$(printf '%s' "$json" | jget -c '[.source, .level]')"
    case "$err" in *"refused:discipline-seed:$reason"*) : ;; *) arm5=0 ;; esac
    [ "$src" = '["default",0]' ] || arm5=0
    detail="$detail [$f: $src / $err]"
done
if [ "$arm5" = 1 ]; then
    ok "arm 5: integration==default, bad regex and a regressed level are refused at load; answers come from source=default level=0"
else
    bad "arm 5:$detail"
fi

# 6 — the MCP tool returns the verb's JSON.
MCP="$ROOT/images/default/config-overlay/mcp/forge-plan.sh"
mcp_out="$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"discipline_show","arguments":{}}}' \
    | TILLANDSIAS_PLAN_BIN="$PLAN" TILLANDSIAS_PLAN_INDEX="$ROOT/plan/index.yaml" bash "$MCP" 2>/dev/null)"
listed=false
printf '%s\n' "$mcp_out" | jget -r 'select(.id == 2) | .result.tools[].name' 2>/dev/null \
    | grep -qx 'discipline_show' && listed=true
# Both sides come from the same serializer, so the bytes are compared as-is.
via_mcp="$(printf '%s\n' "$mcp_out" | jget -r 'select(.id == 3) | .result.content[0].text' 2>/dev/null)"
via_verb="$(dis show --json --root "$ROOT" 2>/dev/null)"
if [ "$listed" = "true" ] && [ -n "$via_verb" ] && [ "$via_mcp" = "$via_verb" ]; then
    ok "arm 6: forge-plan lists discipline_show and tools/call returns the verb's JSON"
else
    bad "arm 6: listed=$listed mcp=[$via_mcp] verb=[$via_verb]"
fi

if [ "$pass" -eq "$total" ]; then
    echo "ok:branch-discipline-verb:$pass/$total"
    exit 0
fi
echo "fail:branch-discipline-verb:$pass/$total"
exit 1
