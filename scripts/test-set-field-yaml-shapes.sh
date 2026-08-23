#!/usr/bin/env bash
# Fixture for `tillandsias-plan set-field`: the fragment it writes must be
# valid YAML for every shape of value, and the value must round-trip exactly.
#
# WHY THIS EXISTS, and it is the same bug twice.
#
#   832-698m (2026-08-22): `format!("    value: {value}\n")` interpolated the
#   value raw. A next_action beginning "Wave 2: (1) seed …" turned the scalar
#   into a nested mapping and the fragment became unparseable. Fixed by routing
#   through serde_yaml. NO REGRESSION TEST WAS ADDED.
#
#   2026-08-23: serde_yaml renders a MULTI-LINE string as a block scalar whose
#   continuation lines are indented two spaces from the DOCUMENT ROOT, while
#   the key sits at column 4. YAML requires block-scalar content to be indented
#   deeper than its key, so the fragment died with "did not find expected '-'
#   indicator at line 11 column 3".
#
# Both times `set-field` printed `ok:` and the PRE-PUSH GATE is what caught it.
# A writer that reports success while emitting an unparseable ledger fragment
# is the worst shape available: the ledger is append-only, so the damage is a
# file nothing can read sitting in a directory everything must read.
#
# HERMETIC: builds its own tiny ledger under mktemp; never touches plan/.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

. "$ROOT/scripts/plan-binary-probe.sh"
if ! PLAN="$(resolve_plan_binary)"; then
    echo "fail:set-field-yaml-shapes:no-runnable-plan-binary"
    exit 2
fi

pass=0
fail=0
ck() { # ck <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
        pass=$((pass + 1))
    else
        printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/set-field-shapes.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/index.d"

cat >"$TMPD/index.yaml" <<'YAML'
plan_index:
  steps:
    - packet_id: fixture/alpha
      order: 900-aaaa
      title: "A fixture packet"
      status: ready
      kind: fix
      events:
        - type: note
          ts: "2025-12-31T00:00:00Z"
          agent_id: seed
          host: fixture
          summary: |
            A pre-existing event so the events list is block-style.
YAML

# Each case: a value shape that has broken this emitter, or plausibly could.
# The apostrophe and the leading-dash cases are not regressions yet — they are
# the shapes a single-quoted or bare emitter would break on next, and they cost
# nothing to pin now.
run_case() { # run_case <label> <value>
    local label="$1" value="$2" frag parsed got
    rm -f "$TMPD"/index.d/*.yaml
    "$PLAN" --index "$TMPD/index.yaml" set-field 900-aaaa next_action "$value" \
        --host fixture >/dev/null 2>&1
    frag="$(ls -t "$TMPD"/index.d/*.yaml 2>/dev/null | head -1)"
    if [ -z "$frag" ]; then
        ck "$label: a fragment was written" "written" "missing"
        return
    fi
    parsed="$(ruby -ryaml -e 'YAML.load_file(ARGV[0]); puts "valid"' "$frag" 2>/dev/null || echo invalid)"
    ck "$label: fragment is valid YAML" "valid" "$parsed"
    [ "$parsed" = valid ] || return
    got="$(ruby -ryaml -e '
      d = YAML.load_file(ARGV[0])
      print(((d["status"] || [])[0] || {})["value"].to_s)
    ' "$frag" 2>/dev/null)"
    ck "$label: value round-trips exactly" "$value" "$got"
}

# 832-698m: colon-space in prose opened a nested mapping.
run_case "colon-space" "Wave 2: (1) seed the corpus, then measure"

# 2026-08-23: multi-line became an under-indented block scalar.
run_case "multi-line" "CAMPAIGN STATE.
Second line, with a colon: here.
(1) a numbered clause"

# A multi-line value whose continuation is itself list-shaped — the exact
# characters the failing parse complained about ("expected '-' indicator").
run_case "multi-line-with-dashes" "Header line
- a dash-led line
- another"

# Shapes that would break a naive quoted emitter.
run_case "apostrophe" "the host's own claimed work"
run_case "leading-dash" "- starts with a dash"
run_case "trailing-colon" "see also:"
run_case "blank-line" "First paragraph.

Second paragraph after a blank line."

printf 'set-field-yaml-shapes: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "ok:set-field-yaml-shapes:$pass"
