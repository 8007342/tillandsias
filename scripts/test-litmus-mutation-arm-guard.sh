#!/usr/bin/env bash
# @trace order:1059-pb2j
#
# Fixture for check-litmus-mutation-arms-mutate.sh.
#
# ARM 1 IS THE REAL POSITIVE CONTROL: the actual pre-fix text of
# litmus-lww-channel-fields-alias.yaml, read out of git history at 5083b2649^,
# not a hand-written imitation of it. The packet asked for exactly that, and it
# is the difference between "the guard flags something shaped like the defect"
# and "the guard flags the defect".
#
# The negative controls matter as much. A guard that flags every arm named
# MUTATION is the same defect one level up — it would force renames of correct
# work, and a guard that flags correct work gets switched off. Three shapes must
# pass: the renamed SOURCE PIN, an arm that mutates inline, and an arm that
# DELEGATES its mutation to a fixture (which is how
# litmus-fragment-status-loss-attribution-shape.yaml is written today).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
GUARD="$ROOT/scripts/check-litmus-mutation-arms-mutate.sh"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/mutation-arm-guard.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

_verdict() { # dir -> exit code, output discarded
    bash "$GUARD" "$1" >/dev/null 2>&1
    echo $?
}

# ── 1. POSITIVE CONTROL: the genuine pre-fix arm from git history ───────────
mkdir -p "$W/prefix"
if git show '5083b2649^:openspec/litmus-tests/litmus-lww-channel-fields-alias.yaml' \
        > "$W/prefix/litmus-lww-channel-fields-alias.yaml" 2>/dev/null \
   && [ -s "$W/prefix/litmus-lww-channel-fields-alias.yaml" ]; then
    if [ "$(_verdict "$W/prefix")" = "1" ]; then
        ok "the REAL pre-fix arm (5083b2649^) is flagged"
    else
        bad "the pre-fix arm is NOT flagged — the guard has no teeth against the instance it was written for"
    fi
    # Non-vacuity: the fetched text must actually contain the arm, or arm 1
    # would pass on an empty file for the wrong reason.
    grep -q 'MUTATION' "$W/prefix/litmus-lww-channel-fields-alias.yaml" \
        && ok "the recovered pre-fix text really contains the MUTATION arm" \
        || bad "the recovered text has no MUTATION arm; arm 1 proves nothing"
else
    echo "skip: 5083b2649^ not reachable in this checkout; the real positive control cannot run" >&2
fi

# ── 2. NEGATIVE: the renamed SOURCE PIN form must pass ─────────────────────
mkdir -p "$W/renamed"
cat > "$W/renamed/litmus-x.yaml" <<'YAML'
steps:
  - step: "SOURCE PIN: the reader still reads both channels"
    command: "grep -q 'for channel in' crates/x/src/y.rs"
    timeout_ms: 10000
YAML
[ "$(_verdict "$W/renamed")" = "0" ] \
    && ok "a renamed SOURCE PIN over the same command passes" \
    || bad "the renamed form is still flagged — the remedy the guard names does not work"

# ── 3. NEGATIVE: an arm that mutates INLINE must pass ──────────────────────
mkdir -p "$W/inline"
cat > "$W/inline/litmus-y.yaml" <<'YAML'
steps:
  - step: "MUTATION: the guard still refuses after the field is removed"
    command: "t=$(mktemp -d); trap 'rm -rf \"$t\"' EXIT; sed -i 's/foo/bar/' \"$t/f\"; bash guard.sh"
    timeout_ms: 10000
YAML
[ "$(_verdict "$W/inline")" = "0" ] \
    && ok "an arm that mutates inline passes" \
    || bad "a real inline mutation arm was flagged"

# ── 4. NEGATIVE: DELEGATION to a fixture must pass ─────────────────────────
# This is the shape litmus-fragment-status-loss-attribution-shape.yaml uses:
# the command runs a fixture and the mutation happens inside it.
mkdir -p "$W/delegate"
cat > "$W/delegate/litmus-z.yaml" <<'YAML'
steps:
  - step: "MUTATION CONTROL: every status-loss class is still refused"
    command: "bash scripts/test-fragment-status-loss.sh >/tmp/out.log 2>&1"
    timeout_ms: 120000
YAML
[ "$(_verdict "$W/delegate")" = "0" ] \
    && ok "an arm delegating its mutation to a fixture passes" \
    || bad "a delegating arm was flagged — this would force a rename of correct work"

# ── 5. CRITERION 3: MENTIONING a verb must not satisfy the guard ───────────
# The 901-jtvi occurrences-not-callers shape. A comment naming sed -i is not a
# mutation, and a guard satisfied by prose is the defect it exists to catch.
mkdir -p "$W/mentions"
cat > "$W/mentions/litmus-w.yaml" <<'YAML'
steps:
  - step: "MUTATION: the alias removal must be observed"
    command: "grep -q 'alias' src/x.rs # this used to sed -i the reader and git checkout it back"
    timeout_ms: 10000
YAML
[ "$(_verdict "$W/mentions")" = "1" ] \
    && ok "a command that only MENTIONS a mutating verb in a comment is still flagged" \
    || bad "a comment naming sed -i satisfied the guard — it counts mentions, not actions"

# ── 6. Redirections alone are not mutations ────────────────────────────────
# >/dev/null and 2>&1 are the commonest tokens in this corpus; counting them
# made an early sizing report 0 candidates out of 3, precise and worthless.
mkdir -p "$W/redir"
cat > "$W/redir/litmus-v.yaml" <<'YAML'
steps:
  - step: "MUTATION: the reader must fail once the field is gone"
    command: "grep -q 'field' src/x.rs >/dev/null 2>&1 && echo ok"
    timeout_ms: 10000
YAML
[ "$(_verdict "$W/redir")" = "1" ] \
    && ok "redirections to /dev/null and fd 2 do not count as mutating" \
    || bad "a command whose only '>' is /dev/null was accepted as a mutation"

# ── 7. A QUOTED delegating command is still delegation (order 147) ────────
# A litmus command is a YAML scalar, so the character before the script path is
# usually a quote. With only whitespace in the boundary class the guard matched
# "bash scripts/x.sh" (via the space after bash) but NOT "scripts/x.sh", and it
# refused a correct delegating MUTATION arm on order 147. That is the guard
# pinning a QUOTING STYLE rather than the property, in the file whose subject is
# exactly that difference.
mkdir -p "$W/quoted"
cat > "$W/quoted/litmus-q.yaml" <<'YAML'
critical_path:
  - step: "MUTATION CONTROL: the guard catches a lost static and a retry loop"
    command: "scripts/test-tray-refresh-no-polling.sh"
    timeout_ms: 60000
YAML
[ "$(_verdict "$W/quoted")" = "0" ] \
    && ok "a delegating command written as a bare quoted path is accepted" \
    || bad "a quoted delegation was flagged — the guard is matching a quoting style, not the property"

echo "litmus-mutation-arm-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
