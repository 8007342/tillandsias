#!/usr/bin/env bash
# @trace order:1395-n7qd
#
# test-centicolon-extract.sh — the CentiColon extractor is a CACHEABLE Lua
# predicate whose obligation list is a pure function of repo bytes.
#
# WHAT IT PINS (1395-n7qd's verifiable_closure):
#   H1  an active spec with two requirements and three scenarios yields exactly
#       three obligations, ids cc:<req-id>:<sha256(title)[:8]> computed here
#       independently with sha256sum; a `#### Scenario:` inside a code fence is
#       not an obligation; an obsolete spec yields zero and `excluded.obsolete`;
#       a spec directory absent from litmus-bindings.yaml is `unregistered`,
#       never silently skipped (and never counted)
#   H2  a `### Requirement:` heading with no req-id is REFUSED by name
#   H3  two scenarios with one title under one requirement are REFUSED
#   H4  zero population is `blocked:`, never ok:0
#   R1  the real gh-auth-script spec: 7 requirements, 19 scenario obligations
#       (the design doc's probe, reproduced through the `predicate` verb)
#   R2  the real corpus, three processes: byte-identical canonical JSON, and a
#       non-zero obligation count
# Pre-fix every arm FAILS: the predicate file does not exist and `predicate`
# exits 1 naming it.

set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
SCRIPT="$ROOT/scripts/lua/centicolon-extract.lua"

. "$ROOT/scripts/plan-binary-probe.sh"
if ! PLAN="$(resolve_plan_binary)"; then
    echo "skip:centicolon-extract:no-runnable-plan-binary"; exit 0
fi
if ! grep -qx 'predicate' <<<"$("$PLAN" capabilities 2>/dev/null)"; then
    echo "skip:centicolon-extract:plan-binary-lacks-predicate-verb:$PLAN"; exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip:centicolon-extract:no-jq"; exit 0; }

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccx.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# run <repo-root> <arg> — sets RC, ERR (stderr, prefix stripped) and JSON.
run() {
    RC=0
    ERR="$(TILLANDSIAS_REPO_ROOT="$1" "$PLAN" predicate "$SCRIPT" --class cacheable --arg "$2" 2>&1 >/dev/null)" || RC=$?
    ERR="$(sed 's/^\[lua-predicate\] //' <<<"$ERR")"
    JSON="$(sed -n 's/^centicolon-extract://p' <<<"$ERR")"
}
if command -v sha256sum >/dev/null 2>&1; then SHA=(sha256sum); else SHA=(shasum -a 256); fi
sha8() { printf '%s' "$1" | "${SHA[@]}" | cut -c1-8; }

registry() { # <root> <id:status>...
    local root="$1"; shift
    mkdir -p "$root/openspec/specs"
    { echo "version: '1.0'"; echo "specs:"
      for e in "$@"; do printf -- '- spec_id: %s\n  status: %s\n  litmus_tests: []\n' "${e%%:*}" "${e#*:}"; done
    } >"$root/openspec/litmus-bindings.yaml"
}

# ── H1: the hermetic corpus ──────────────────────────────────────────────────
H="$WORK/h1"; registry "$H" alpha:active beta:obsolete
mkdir -p "$H/openspec/specs/alpha" "$H/openspec/specs/beta" "$H/openspec/specs/gamma"
cat >"$H/openspec/specs/alpha/spec.md" <<'EOF'
# alpha

status: active

## Requirements

### Requirement: The door opens
<!-- req-id: aaaa0001 -->
The door MUST open.

#### Scenario: Opened by a key
- WHEN a key turns THEN it opens

#### Scenario: Opened by a code
- WHEN the code is right THEN it opens

```markdown
#### Scenario: Not a scenario, inside a fence
```

### Requirement: The door locks
<!-- req-id: aaaa0002 -->

#### Scenario: Locked at night
- WHEN night falls THEN it locks

### Requirement 3: The door chimes
<!-- req-id: aaaa0003 -->

#### Scenario: Chimes on open

### Requirement 4: The door has no id yet

#### Scenario: Not counted
EOF
cat >"$H/openspec/specs/beta/spec.md" <<'EOF'
# beta

## Status

obsolete

### Requirement: Gone
<!-- req-id: bbbb0001 -->

#### Scenario: Never counted
EOF
cat >"$H/openspec/specs/gamma/spec.md" <<'EOF'
# gamma

status: active

### Requirement: Unregistered
<!-- req-id: cccc0001 -->

#### Scenario: Not in the registry
EOF
run "$H" "alpha,beta,gamma"
if [ "$RC" -ne 0 ]; then
    bad "H1 predicate rc=$RC: $(head -3 <<<"$ERR")"
else
    got="$(jq -r '.obligations[].id' <<<"$JSON" | tr -d '\r' | sort)"
    want="$(printf '%s\n' "cc:aaaa0001:$(sha8 'Opened by a key')" "cc:aaaa0001:$(sha8 'Opened by a code')" "cc:aaaa0002:$(sha8 'Locked at night')" "cc:aaaa0003:$(sha8 'Chimes on open')" | sort)"
    if [ "$got" = "$want" ]; then ok "H1 active spec: 4 obligations (one under a numbered, req-id'd heading), ids match sha256(title)[:8] computed independently (fenced scenario ignored)"
    else bad "H1 obligation ids: got [$(tr '\n' ' ' <<<"$got")] want [$(tr '\n' ' ' <<<"$want")]"; fi
    if [ "$(jq -r '.requirements' <<<"$JSON")" = 3 ]; then ok "H1 requirements=3"; else bad "H1 requirements=$(jq -r '.requirements' <<<"$JSON")"; fi
    if [ "$(jq -r '.unkeyed|join(",")' <<<"$JSON" | tr -d '\r')" = "alpha:The door has no id yet" ]; then ok "H1 numbered heading with no req-id -> unkeyed, not counted"
    else bad "H1 unkeyed: $(jq -c '.unkeyed' <<<"$JSON")"; fi
    if [ "$(jq -r '.excluded.obsolete // 0' <<<"$JSON")" = 1 ] && ! grep -q 'bbbb0001' <<<"$JSON"; then ok "H1 obsolete spec: zero obligations, excluded.obsolete=1"
    else bad "H1 obsolete spec not excluded: $(jq -c '.excluded' <<<"$JSON")"; fi
    if [ "$(jq -r '.unregistered|join(",")' <<<"$JSON")" = gamma ] && ! grep -q 'cccc0001' <<<"$JSON"; then ok "H1 unregistered spec dir named, not counted"
    else bad "H1 unregistered: $(jq -c '.unregistered' <<<"$JSON")"; fi
    if grep -q '^ok:centicolon-extract:obligations=4 ' <<<"$ERR"; then ok "H1 verdict line ok:…obligations=4"
    else bad "H1 verdict: $(grep -E '^(ok|refused|blocked):' <<<"$ERR")"; fi
fi

# ── H2: a requirement with no req-id is refused by name ──────────────────────
H="$WORK/h2"; registry "$H" alpha:active; mkdir -p "$H/openspec/specs/alpha"
cat >"$H/openspec/specs/alpha/spec.md" <<'EOF'
status: active

### Requirement: Has an id
<!-- req-id: aaaa0001 -->

#### Scenario: Fine

### Requirement: Lost its id

#### Scenario: Orphaned
EOF
run "$H" "alpha"
if [ "$RC" -ne 0 ] && grep -qx 'refused:centicolon-extract:requirement-without-req-id:alpha:Lost its id' <<<"$ERR" && ! grep -q '^ok:' <<<"$ERR"; then
    ok "H2 requirement without req-id refused by name, never counted"
else bad "H2 rc=$RC: $(grep -E '^(ok|refused|blocked):' <<<"$ERR" | head -2)"; fi

# ── H3: duplicate identity under one requirement ─────────────────────────────
H="$WORK/h3"; registry "$H" alpha:active; mkdir -p "$H/openspec/specs/alpha"
printf 'status: active\n\n### Requirement: Twice\n<!-- req-id: aaaa0001 -->\n\n#### Scenario: Same\n\n#### Scenario: Same\n' >"$H/openspec/specs/alpha/spec.md"
run "$H" "alpha"
if [ "$RC" -ne 0 ] && grep -q "^refused:centicolon-extract:duplicate-obligation-id:alpha:cc:aaaa0001:$(sha8 Same)\$" <<<"$ERR"; then
    ok "H3 duplicate obligation identity refused by name"
else bad "H3 rc=$RC: $(grep -E '^(ok|refused|blocked):' <<<"$ERR" | head -2)"; fi

# ── H4: zero population is blocked, never ok:0 ───────────────────────────────
H="$WORK/h4"; registry "$H" beta:obsolete; mkdir -p "$H/openspec/specs/beta"
printf '## Status\n\nobsolete\n' >"$H/openspec/specs/beta/spec.md"
run "$H" "beta"
if [ "$RC" -ne 0 ] && grep -qx 'blocked:centicolon-extract:zero-population' <<<"$ERR"; then ok "H4 zero population -> blocked, never ok:0"
else bad "H4 rc=$RC: $(grep -E '^(ok|refused|blocked):' <<<"$ERR" | head -2)"; fi

# ── R1: the real gh-auth-script spec ─────────────────────────────────────────
run "$ROOT" "gh-auth-script"
r="$(jq -r '"\(.requirements) \(.obligation_count)"' <<<"$JSON" 2>/dev/null)"
if [ "$RC" -eq 0 ] && [ "$r" = "7 19" ]; then ok "R1 gh-auth-script: 7 requirements, 19 scenario obligations"
else bad "R1 gh-auth-script rc=$RC: requirements/obligations=$r (want 7 19)"; fi

# ── R2: the real corpus, three processes, one canonical output ───────────────
DIRS="$(cd "$ROOT/openspec/specs" && for d in */; do printf '%s,' "${d%/}"; done)"
digests=""; counts=""
for i in 1 2 3; do
    run "$ROOT" "$DIRS"
    digests="$digests $(printf '%s' "$JSON" | "${SHA[@]}" | cut -c1-16)"
    counts="$counts $(jq -r '.obligation_count' <<<"$JSON" 2>/dev/null)"
done
read -r d1 d2 d3 <<<"$digests"; read -r c1 _ <<<"$counts"
if [ -n "$d1" ] && [ "$d1" = "$d2" ] && [ "$d2" = "$d3" ] && [ "${c1:-0}" -gt 0 ] 2>/dev/null; then
    ok "R2 real corpus: 3 processes, byte-identical JSON ($d1), obligations=$c1"
else bad "R2 determinism: digests [$digests] counts [$counts]"; fi

if [ "$fail" -eq 0 ]; then echo "ok:centicolon-extract:$pass"; exit 0; fi
echo "fail:centicolon-extract:$fail failed, $pass passed"; exit 1
