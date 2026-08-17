#!/usr/bin/env bash
# @trace spec:litmus-framework
# =============================================================================
# test-litmus-diff-scope.sh — fixtures for order 765-mza8.
#
# Proves the exit criteria of litmus-diff-scoped-selection. The selector REMOVES
# coverage, so the property under test is not "it skips tests" — any broken
# implementation does that. It is: EVERY uncertainty runs the full suite.
#
# Scenarios:
#   A. accessor parity   — yq path and awk fallback return identical globs for
#                          every annotated file (the fallback is what macOS and
#                          bare containers actually execute, so a divergence
#                          there is a silent coverage hole on those hosts).
#   B. glob semantics    — `crates/**` matches nested paths; a non-matching glob
#                          does not intersect; the empty-annotation case.
#   C. fail-closed       — not-a-git-repo / unresolvable base / no changes /
#                          no anchor / anchor older than 24h each leave
#                          DIFF_SCOPE_ACTIVE=0.
#   D. happy path        — a valid base with changes and a fresh anchor sets
#                          ACTIVE=1 and captures uncommitted AND untracked paths.
#   E. gate-stamp veto   — after a scoped run, build.sh's _write_gate_stamp
#                          refuses to write any stamp and consumes the sentinel.
#
# C and D drive the REAL functions, awk-extracted from run-litmus-test.sh, against
# throwaway git repos, so every branch is reachable deterministically regardless
# of what this worktree happens to contain.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/run-litmus-test.sh"
fail=0

suite_tmp="$(mktemp -d "${TMPDIR:-/tmp}/litmus-diff-scope.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -rf '$suite_tmp'" EXIT INT TERM HUP

ok()   { printf '  ok: %s\n' "$1"; }
bad()  { printf '  FAIL: %s\n' "$1"; fail=1; }

# ── harness: load the real functions under test ─────────────────────────────
# Extract by name from the runner rather than reimplementing, so this fixture
# cannot drift into testing a copy that no longer matches shipped behaviour.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\) \\{" { collecting=1 }
        collecting { print }
        collecting && /^\}/ { exit }
    ' "$RUNNER"
}

for fn in get_test_inputs litmus_inputs_intersect_diff litmus_resolve_diff_scope \
          litmus_record_full_anchor litmus_mark_scoped_run; do
    body="$(extract_fn "$fn")"
    if [[ -z "$body" ]] || ! grep -q "^${fn}() {" <<<"$body"; then
        printf 'FAIL: could not extract %s() from the runner — fixture is stale\n' "$fn"
        exit 1
    fi
    eval "$body"
done

# The extracted resolver logs through the runner's helpers and reads its globals.
LOG_LINES=""
log_warn() { LOG_LINES+="WARN:$*"$'\n'; }
log_info() { LOG_LINES+="INFO:$*"$'\n'; }
DIFF_SCOPE_ACTIVE=0
DIFF_SCOPE_BASE_SHA=""
DIFF_SCOPE_CHANGED=""

# ── A. accessor parity: yq path vs awk fallback ─────────────────────────────
printf '\nA. accessor parity (yq vs awk fallback)\n'

# The fallback branch is unreachable while yq is on PATH, so shadow it with a
# PATH that has no yq at all — this exercises the branch macOS actually runs.
nonyq_dir="$suite_tmp/nonyq-bin"
mkdir -p "$nonyq_dir"
sanitized_path=""
IFS=: read -ra _parts <<<"$PATH"
for _d in "${_parts[@]}"; do
    [[ -x "$_d/yq" ]] && continue
    sanitized_path="${sanitized_path:+$sanitized_path:}$_d"
done

annotated_count=0
parity_bad=0
for f in "$ROOT"/openspec/litmus-tests/litmus-*.yaml; do
    via_yq="$(get_test_inputs "$f")"
    via_awk="$(PATH="$sanitized_path" bash -c "$(extract_fn get_test_inputs); get_test_inputs \"\$1\"" _ "$f")"
    if [[ -n "$via_yq" ]]; then
        annotated_count=$((annotated_count + 1))
    fi
    if [[ "$via_yq" != "$via_awk" ]]; then
        bad "parity mismatch in $(basename "$f")"
        printf '    yq : %s\n' "$(tr '\n' ' ' <<<"$via_yq")"
        printf '    awk: %s\n' "$(tr '\n' ' ' <<<"$via_awk")"
        parity_bad=1
    fi
done
if command -v yq >/dev/null 2>&1; then
    [[ "$parity_bad" -eq 0 ]] && ok "yq and awk agree on all $(ls "$ROOT"/openspec/litmus-tests/litmus-*.yaml | wc -l | tr -d ' ') files"
else
    ok "yq absent on this host — fallback is the only path, parity vacuous"
fi
if [[ "$annotated_count" -gt 0 ]]; then
    ok "$annotated_count test(s) carry inputs: annotations"
else
    bad "no annotated tests found — the mechanism would be inert"
fi

# ── B. glob semantics ───────────────────────────────────────────────────────
printf '\nB. glob semantics\n'

changed_sample=$'crates/tillandsias-plan/src/main.rs\nplan/index.d/x.yaml'

if litmus_inputs_intersect_diff 'crates/**' "$changed_sample"; then
    ok "crates/** matches a nested path (bash [[ == ]], * crosses /)"
else
    bad "crates/** failed to match crates/tillandsias-plan/src/main.rs"
fi

if litmus_inputs_intersect_diff $'images/git/**\nscripts/build-image.sh' "$changed_sample"; then
    bad "unrelated globs matched — would skip a test that should run"
else
    ok "unrelated globs do not intersect"
fi

if litmus_inputs_intersect_diff '' "$changed_sample"; then
    bad "an empty annotation intersected — unannotated tests must never be skipped"
else
    ok "empty annotation never intersects (unannotated ⇒ always runs)"
fi

if litmus_inputs_intersect_diff 'plan/index.d/**' "$changed_sample"; then
    ok "exact-subtree glob matches"
else
    bad "plan/index.d/** failed to match plan/index.d/x.yaml"
fi

# ── C+D. resolver behaviour in throwaway repos ──────────────────────────────
printf '\nC. fail-closed refusals\n'

new_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email t@example.com
    git -C "$d" config user.name t
    printf 'seed\n' > "$d/seed.txt"
    git -C "$d" add -A
    git -C "$d" -c commit.gpgsign=false commit -qm seed
}

# refusal helper: run the resolver and assert it disabled scoping
assert_refuses() {
    local label="$1" want="$2"
    if [[ "$DIFF_SCOPE_ACTIVE" -eq 0 ]] && grep -qF "$want" <<<"$LOG_LINES"; then
        ok "$label"
    else
        bad "$label (ACTIVE=$DIFF_SCOPE_ACTIVE, log: $(tr '\n' '|' <<<"$LOG_LINES"))"
    fi
}

# C1. not a git repository
PROJECT_ROOT="$suite_tmp/not-a-repo"; mkdir -p "$PROJECT_ROOT"
LOG_LINES=""; litmus_resolve_diff_scope HEAD
assert_refuses "not a git repository ⇒ FULL" "not a git repository"

# C2. base ref does not resolve
PROJECT_ROOT="$suite_tmp/repo-c2"; new_repo "$PROJECT_ROOT"
LOG_LINES=""; litmus_resolve_diff_scope no-such-ref-xyz
assert_refuses "unresolvable base ref ⇒ FULL" "does not resolve"

# C3. no changes at all
PROJECT_ROOT="$suite_tmp/repo-c3"; new_repo "$PROJECT_ROOT"
LOG_LINES=""; litmus_resolve_diff_scope HEAD
assert_refuses "clean tree (no changes) ⇒ FULL" "no changes against"

# C4. changes present but no anchor recorded yet
PROJECT_ROOT="$suite_tmp/repo-c4"; new_repo "$PROJECT_ROOT"
printf 'edit\n' >> "$PROJECT_ROOT/seed.txt"
LOG_LINES=""; litmus_resolve_diff_scope HEAD
assert_refuses "no full-run anchor ⇒ FULL" "no full-run anchor"

# C5. anchor present but older than 24h
PROJECT_ROOT="$suite_tmp/repo-c5"; new_repo "$PROJECT_ROOT"
printf 'edit\n' >> "$PROJECT_ROOT/seed.txt"
gd="$(git -C "$PROJECT_ROOT" rev-parse --absolute-git-dir)"
printf '%s\n' "$(( $(date -u +%s) - 90000 ))" > "$gd/tillandsias-litmus-full-anchor"
LOG_LINES=""; litmus_resolve_diff_scope HEAD
assert_refuses "anchor older than 24h ⇒ FULL (ratchet)" "older than 24h"

# C6. a garbage (non-numeric) anchor must not be read as "fresh"
PROJECT_ROOT="$suite_tmp/repo-c6"; new_repo "$PROJECT_ROOT"
printf 'edit\n' >> "$PROJECT_ROOT/seed.txt"
gd="$(git -C "$PROJECT_ROOT" rev-parse --absolute-git-dir)"
printf 'not-a-timestamp\n' > "$gd/tillandsias-litmus-full-anchor"
LOG_LINES=""; litmus_resolve_diff_scope HEAD
assert_refuses "corrupt anchor ⇒ FULL (treated as epoch 0)" "older than 24h"

printf '\nD. happy path\n'

PROJECT_ROOT="$suite_tmp/repo-d"; new_repo "$PROJECT_ROOT"
mkdir -p "$PROJECT_ROOT/crates/foo/src"
printf 'edit\n' >> "$PROJECT_ROOT/seed.txt"                 # tracked, uncommitted
printf 'fn main(){}\n' > "$PROJECT_ROOT/crates/foo/src/main.rs"  # untracked
gd="$(git -C "$PROJECT_ROOT" rev-parse --absolute-git-dir)"
date -u +%s > "$gd/tillandsias-litmus-full-anchor"
LOG_LINES=""; litmus_resolve_diff_scope HEAD

if [[ "$DIFF_SCOPE_ACTIVE" -eq 1 ]]; then
    ok "valid base + changes + fresh anchor ⇒ ACTIVE"
else
    bad "happy path did not activate (log: $(tr '\n' '|' <<<"$LOG_LINES"))"
fi
if grep -qxF 'seed.txt' <<<"$DIFF_SCOPE_CHANGED"; then
    ok "uncommitted tracked edit is in the change set"
else
    bad "uncommitted tracked edit missing — would skip the test covering it"
fi
if grep -qxF 'crates/foo/src/main.rs' <<<"$DIFF_SCOPE_CHANGED"; then
    ok "untracked new file is in the change set"
else
    bad "untracked file missing — would skip the test covering brand-new code"
fi

# the scoped-run sentinel is written where build.sh looks for it
DIFF_SCOPE_BASE_SHA="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
litmus_mark_scoped_run 7
if [[ -f "$gd/tillandsias-litmus-diff-scoped" ]] \
    && grep -q 'skips=7' "$gd/tillandsias-litmus-diff-scoped"; then
    ok "scoped run leaves the sentinel build.sh vetoes on"
else
    bad "scoped-run sentinel not written"
fi

# ── E. gate-stamp veto ──────────────────────────────────────────────────────
printf '\nE. gate-stamp veto after a scoped run\n'

# _write_gate_stamp must (a) refuse, and (b) consume the sentinel, so the NEXT
# unscoped run is allowed to stamp. Extract it the same way.
stamp_fn="$(awk '
    /^_write_gate_stamp\(\) \{/ { collecting=1 }
    collecting { print }
    collecting && /^\}/ { exit }
' "$ROOT/build.sh")"
if [[ -z "$stamp_fn" ]]; then
    bad "could not extract _write_gate_stamp from build.sh"
else
    veto_out="$(
        cd "$PROJECT_ROOT" || exit 1
        _warn() { printf 'WARN:%s\n' "$*"; }
        eval "$stamp_fn"
        _write_gate_stamp 2>&1
    )"
    if grep -q 'NOT writing a gate stamp' <<<"$veto_out"; then
        ok "scoped sentinel vetoes the gate stamp"
    else
        bad "gate stamp was NOT vetoed after a scoped run (out: $veto_out)"
    fi
    if [[ ! -f "$gd/tillandsias-litmus-diff-scoped" ]]; then
        ok "sentinel consumed — a later full run can stamp again"
    else
        bad "sentinel survived; every later run would be vetoed forever"
    fi
fi

# ── F. dead-glob guard: negative control ───────────────────────────────────
# 634-39ik: a guard that has never been seen to fail is not known to work. This
# builds a throwaway repo where one glob is deliberately dead and proves
# check-litmus-dead-inputs.sh refuses it — and that it passes on the live case.
printf '\nF. dead-glob guard (negative control)\n'

ctl="$suite_tmp/deadglob"
mkdir -p "$ctl/openspec/litmus-tests" "$ctl/scripts" "$ctl/crates/real/src"
cp "$ROOT/scripts/check-litmus-dead-inputs.sh" "$ctl/scripts/"
printf 'fn main(){}\n' > "$ctl/crates/real/src/main.rs"
git -C "$ctl" init -q
git -C "$ctl" config user.email t@example.com
git -C "$ctl" config user.name t

# The synthetic test names are composed at runtime, never written literally.
# check-litmus-pin-claims.sh (721-77yu) greps .sh files for `litmus:<name>` and
# reads every hit as a CLAIM that such a test exists — so spelling these out
# would make this fixture refuse the whole gate for tests it invents on purpose.
NS="litmus"
cat > "$ctl/openspec/litmus-tests/litmus-live.yaml" <<YAML
name: ${NS}:live
size: instant
inputs:
  - crates/**
phase: pre-build
YAML
git -C "$ctl" add -A
git -C "$ctl" -c commit.gpgsign=false commit -qm seed

if out="$(bash "$ctl/scripts/check-litmus-dead-inputs.sh" 2>&1)"; then
    ok "passes when every glob resolves (${out##*:})"
else
    bad "guard refused a healthy annotation: $out"
fi

# now the control: a glob that cannot match anything tracked
cat > "$ctl/openspec/litmus-tests/litmus-dead.yaml" <<YAML
name: ${NS}:dead
size: instant
inputs:
  - crate/**
phase: pre-build
YAML
git -C "$ctl" add -A
git -C "$ctl" -c commit.gpgsign=false commit -qm dead

if out="$(bash "$ctl/scripts/check-litmus-dead-inputs.sh" 2>&1)"; then
    bad "guard PASSED a dead glob 'crate/**' — it cannot detect the class it exists for"
else
    if grep -q "violation:litmus-dead-inputs:1" <<<"$out" && grep -q "crate/\*\*" <<<"$out"; then
        ok "refuses a dead glob and names it"
    else
        bad "guard failed but not for the right reason: $out"
    fi
fi

printf '\n'
if [[ "$fail" -eq 0 ]]; then
    printf 'ok: litmus diff-scope fixtures green\n'
else
    printf 'FAIL: litmus diff-scope fixtures red\n'
fi
exit "$fail"
