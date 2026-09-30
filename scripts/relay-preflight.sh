#!/usr/bin/env bash
# relay-preflight.sh — ONE command relay preflight (order 1437-664a, T2 of
# plan/issues/efficiency-trims-design-2026-09-27.md).
# @trace order:1437-664a, spec:ci-release
#
# WHY THIS EXISTS. The relay lane hand-typed ~15 commands per pass: fetch,
# merge, cycle-preflight, ~10 deciders judged by exit code, cargo fmt --check,
# the touched fixtures and crates, and litmus-covering-specs.sh --run over
# every covering spec. The hand-typed set omitted
# check-issue-citation-convention.sh on 2026-09-21 and cost a 20-minute gate.
# This script is that sequence, once, with ONE stdout verdict line so the
# coordinator lands on a single answer rather than a transcript of ~15 runs.
#
# GATE-INTEGRITY SENSITIVE (packet notes): the coordinator lands on this
# verdict. A phase that silently skips lets a red tree land — every phase
# below either runs for real, or is stubbed LOUDLY (an `item:` line naming
# `skip:stub`) under TILLANDSIAS_RELAY_PREFLIGHT_STUB, never silently.
#
# USAGE
#   scripts/relay-preflight.sh <ref>... [--base <ref>] [--plan]
#                              [--all-covering] [--keep-going]
#
# GRAMMAR
#   stdout, exactly one line:
#     ok:relay-preflight:<sha>:refs=<n> deciders=<n> fmt=<ok|skip>
#         fixtures=<n> crates=<n> litmus=<run>/<deferred>
#     ok:relay-preflight:plan:refs=<n> deciders=<n> fixtures=<n> crates=<n>
#         litmus=<run>/<deferred>                          (--plan mode)
#     refused:relay-preflight:<phase>:<item>                on the first red
#   stderr: one line per item, `item: <name> <verdict> <ms>`, plus a
#   why:/remedy: affordance under every refusal (check-refusal-affordance-added).
#
#   Exit 0 on ok. Exit 2 on a merge conflict. Exit 1 on any other refusal.
#
# PHASES, fail-fast in this order (the first red phase refuses and no later
# phase runs, unless --keep-going):
#   1. dirty-worktree refusal (BEFORE any fetch) -> fetch -> merge each ref
#      --no-ff onto a scratch relay/<utc> branch cut from --base, in the
#      order given. A conflict aborts the merge and restores the original
#      branch before refusing.
#   2. IF the merged diff touches crates/tillandsias-plan: scripts/cycle-
#      preflight.sh, then scripts/check-plan-binary-current.sh — a stale
#      binary makes next-order and the plan lane refuse.
#   3. The deciders, judged by exit code only, diff-scoped ones against
#      --base through their existing env seams (never re-implemented):
#      check-bash-dialect, check-sigpipe-verdict-pipelines-added,
#      check-plan-binary-probe-usage, check-litmus-pin-claims,
#      check-script-exec-bits, check-added-fragments-parse,
#      check-scorable-obligation-added, check-gate-step-regimes,
#      check-added-test-is-referenced, check-refusal-affordance-added,
#      check-rust-source-pin-added, check-no-python-scripts,
#      check-jq-callsite-ratchet, preflight-fixtures-default-target,
#      check-issue-citation-convention, trace-coverage.sh --gate, plus
#      `tillandsias-plan check --strict-fragments` and `tillandsias-policy
#      plan-orders` when the diff adds plan/index.d fragments.
#   4. `cargo fmt --check` when the diff touches *.rs.
#   5. Touched fixtures: every scripts/test-*.sh in the diff, plus every
#      scripts/test-*.sh (excluding scripts/test-support/*) whose bytes name
#      a touched scripts/*.sh path — sorted, deduplicated, LISTED before any
#      of them runs.
#   6. Crate tests: `cargo test -p <crate>` for each crate with a touched
#      file (nearest Cargo.toml above the path), plus the tray,listen-vsock
#      serial pass when crates/tillandsias-headless/src/tray/ is touched.
#   7. Covering litmus: scripts/litmus-covering-specs.sh --relay-scope <base>
#      (--all-covering to lift the cap) for the run/deferred partition, then
#      scripts/run-litmus-test.sh <spec> --phase pre-build --size <size>
#      --compact per RUN spec.
#   8. One verdict line, via timing_emit relay-preflight relay <t0> <rc>.
#
# TILLANDSIAS_RELAY_PREFLIGHT_STUB=1 replaces the CARGO and LITMUS-EXECUTION
# sub-steps (cycle-preflight's rebuild, check-plan-binary-current, cargo fmt,
# cargo test -p, and each run-litmus-test.sh invocation) with an instant
# `skip:stub` verdict — never silently: the item line still prints. The
# SELECTION logic (which deciders/fixtures/crates/specs apply) always runs
# for real, stub or not, because that logic is exactly what the six-arm
# fixture pins.
#
# --plan prints phases 3-7's selected items without running them, and two
# --plan runs on the same inputs print byte-identical item lists.
#
# NEVER PUSHES. relay/<utc> is left checked out for scripts/land-on-platform-
# branch.sh (or the landing queue) to push. `.claude/worktrees/` is agent
# worktree scratch, out of scope for the dirty-worktree check and any scan.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 2

# ── affordance + timing, best-effort, never disturb the wrapped rc ─────────
_afford() { printf '  why: %s\n  remedy: %s\n' "$1" "$2" >&2; }

. "$SELF_DIR/timing-log.sh" 2>/dev/null || true
command -v timing_emit >/dev/null 2>&1 || { timing_now_ms() { echo 0; }; timing_emit() { return 0; }; }
. "$SELF_DIR/plan-binary-probe.sh" 2>/dev/null || true

T0="$(timing_now_ms)"

_item() { # name verdict t0 — t0=0 (or absent) means "no instrument", print 0
    local _dur=0
    case "${3:-}" in '' | 0 | *[!0-9]*) ;; *) _dur=$(( $(timing_now_ms) - $3 )); [ "$_dur" -ge 0 ] 2>/dev/null || _dur=0 ;; esac
    echo "item: $1 $2 $_dur" >&2
}

# Run "$@", captured (stdout+stderr) into $_CAP_OUT, return its exit code.
# Command substitution, not a temp file: no /tmp path, no PID-reuse race,
# and nothing survives this process to clean up.
_cap() { _CAP_OUT="$("$@" 2>&1)"; return $?; }

STUB=0
[ "${TILLANDSIAS_RELAY_PREFLIGHT_STUB:-0}" = 1 ] && STUB=1

# ── args ─────────────────────────────────────────────────────────────────────
BASE="origin/linux-next"
PLAN_MODE=0
ALL_COVERING=0
KEEP_GOING=0
refs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="${2:-}"; shift 2 ;;
        --plan) PLAN_MODE=1; shift ;;
        --all-covering) ALL_COVERING=1; shift ;;
        --keep-going) KEEP_GOING=1; shift ;;
        --) shift; while [ $# -gt 0 ]; do refs+=("$1"); shift; done ;;
        -*)
            echo "refused:relay-preflight:usage:unknown-argument"
            _afford "relay-preflight.sh does not recognise '$1'" \
                "scripts/relay-preflight.sh <ref>... [--base <ref>] [--plan] [--all-covering] [--keep-going]"
            exit 2 ;;
        *) refs+=("$1"); shift ;;
    esac
done

if [ ${#refs[@]} -eq 0 ]; then
    echo "refused:relay-preflight:usage:no-refs"
    _afford "relay-preflight merges one or more refs onto a scratch branch and nothing was named" \
        "scripts/relay-preflight.sh <ref>... [--base origin/linux-next] [--plan]"
    exit 2
fi

# ── arm 6: dirty worktree, refused BEFORE any fetch ─────────────────────────
# .claude/worktrees/ is agent worktree scratch and out of scope: it is
# .gitignore'd already, but a defensive filter keeps this true even if that
# ever lapses (rule: the script must treat it as out of scope).
_dirty="$(git status --porcelain 2>/dev/null | grep -v '^?? \.claude/worktrees/' || true)"
if [ -n "$_dirty" ]; then
    echo "refused:relay-preflight:dirty-worktree"
    _afford "the working tree or index carries uncommitted changes, and a relay preflight merges and gates a committed tree only" \
        "commit, stash (scripts/salvage-dirty-worktree.sh for an ungated tree), or discard, then re-run"
    timing_emit relay-preflight relay "$T0" 1
    exit 1
fi

ORIG_REF="$(git symbolic-ref --short -q HEAD || true)"
[ -n "$ORIG_REF" ] || ORIG_REF="$(git rev-parse HEAD)"

# ── phase 1: fetch, cut relay/<utc> from --base, merge each ref in order ───
_t="$(timing_now_ms)"
if ! _cap git fetch -q origin; then
    _item fetch red "$_t"
    printf '%s\n' "$_CAP_OUT" | sed 's/^/  /' >&2
    echo "refused:relay-preflight:merge:fetch-failed"
    _afford "origin could not be fetched, so --base cannot be trusted current" \
        "check network/remote access (git fetch -q origin) and re-run"
    timing_emit relay-preflight relay "$T0" 1
    exit 1
fi
_item fetch ok "$_t"

if ! git rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1; then
    echo "refused:relay-preflight:merge:base-unresolved:$BASE"
    _afford "the named base '$BASE' does not resolve to a commit here" \
        "pass a base this checkout has (git rev-parse --verify $BASE), or fetch it first"
    timing_emit relay-preflight relay "$T0" 1
    exit 1
fi

UTC="$(date -u +%Y%m%dt%H%M%Sz)"
RELAY_BRANCH="relay/$UTC"
if ! git checkout -q -B "$RELAY_BRANCH" "$BASE" >/dev/null 2>&1; then
    echo "refused:relay-preflight:merge:scratch-branch-failed:$RELAY_BRANCH"
    _afford "git could not create the scratch branch $RELAY_BRANCH from $BASE" \
        "check for a ref name collision or a detached/locked HEAD, then re-run"
    timing_emit relay-preflight relay "$T0" 1
    exit 1
fi

_restore_clean() {
    git merge --abort >/dev/null 2>&1 || true
    git checkout -q "$ORIG_REF" >/dev/null 2>&1 || true
    git branch -D "$RELAY_BRANCH" >/dev/null 2>&1 || true
}

for ref in ${refs[@]+"${refs[@]}"}; do
    if ! git rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1; then
        _restore_clean
        echo "refused:relay-preflight:merge:ref-unresolved:$ref"
        _afford "the ref '$ref' does not resolve to a commit here" \
            "fetch or name a ref this checkout has, then re-run"
        timing_emit relay-preflight relay "$T0" 1
        exit 1
    fi
    _t="$(timing_now_ms)"
    if ! _cap git merge --no-ff --no-edit "$ref"; then
        _item "merge:$ref" red "$_t"
        printf '%s\n' "$_CAP_OUT" | sed 's/^/  /' >&2
        _restore_clean
        echo "refused:relay-preflight:merge:merge-conflict:$ref"
        _afford "merging $ref onto $RELAY_BRANCH (from $BASE) conflicted" \
            "resolve the conflict locally on a work ref, push, and let relay-preflight try again"
        timing_emit relay-preflight relay "$T0" 2
        exit 2
    fi
    _item "merge:$ref" ok "$_t"
done

MERGED_SHA="$(git rev-parse --short HEAD)"

# ── shared diff surfaces, computed ONCE ─────────────────────────────────────
DIFF_ALL="$(git diff --name-only "$BASE"...HEAD 2>/dev/null | LC_ALL=C sort -u)"
DIFF_SCRIPTS="$(printf '%s\n' "$DIFF_ALL" | grep -E '^scripts/.*\.sh$' || true)"
FRAGMENTS_ADDED=0
if grep -q '^plan/index\.d/' <<<"$DIFF_ALL"; then FRAGMENTS_ADDED=1; fi

# ── phase 2: plan-binary currency, only IF the surface moved ───────────────
if grep -q '^crates/tillandsias-plan/' <<<"$DIFF_ALL"; then
    if [ "$STUB" = 1 ]; then
        _item cycle-preflight skip:stub 0
        _item check-plan-binary-current skip:stub 0
    else
        _t="$(timing_now_ms)"
        _cap bash "$SELF_DIR/cycle-preflight.sh"; _cp_rc=$?
        if [ "$_cp_rc" -ne 0 ] || grep -q '^blocked:' <<<"$_CAP_OUT"; then
            _item cycle-preflight red "$_t"
            printf '%s\n' "$_CAP_OUT" | sed 's/^/  /' >&2
            echo "refused:relay-preflight:cycle-preflight:$(printf '%s' "$_CAP_OUT" | tail -1)"
            _afford "the plan binary must rebuild after a merge that touches crates/tillandsias-plan, and cycle-preflight refused" \
                "read the cycle-preflight output above, fix it, then re-run"
            _restore_clean
            timing_emit relay-preflight relay "$T0" 1
            exit 1
        fi
        _item cycle-preflight ok "$_t"
        _t="$(timing_now_ms)"
        if ! _cap bash "$SELF_DIR/check-plan-binary-current.sh"; then
            _item check-plan-binary-current red "$_t"
            printf '%s\n' "$_CAP_OUT" | sed 's/^/  /' >&2
            echo "refused:relay-preflight:check-plan-binary-current"
            _afford "the rebuilt plan binary does not carry the semantics check-plan-binary-current.sh expects" \
                "read scripts/test-expire-claims-write-is-opt-in.sh's output above, fix it, then re-run"
            _restore_clean
            timing_emit relay-preflight relay "$T0" 1
            exit 1
        fi
        _item check-plan-binary-current ok "$_t"
    fi
fi

# ── phase 3: deciders, judged by rc only ────────────────────────────────────
DECIDER_NAMES="check-bash-dialect check-sigpipe-verdict-pipelines-added check-plan-binary-probe-usage check-litmus-pin-claims check-script-exec-bits check-added-fragments-parse check-scorable-obligation-added check-gate-step-regimes check-added-test-is-referenced check-refusal-affordance-added check-rust-source-pin-added check-no-python-scripts check-jq-callsite-ratchet preflight-fixtures-default-target check-issue-citation-convention trace-coverage"

PLAN_BIN=""
POLICY_BIN=""
if [ "$FRAGMENTS_ADDED" = 1 ] && [ "$STUB" != 1 ]; then
    command -v resolve_plan_binary >/dev/null 2>&1 && PLAN_BIN="$(resolve_plan_binary 2>/dev/null || true)"
    if command -v resolve_target_binary >/dev/null 2>&1; then
        POLICY_BIN="$(resolve_target_binary tillandsias-policy release "$ROOT" 2>/dev/null || true)"
        [ -n "$POLICY_BIN" ] || POLICY_BIN="$(resolve_target_binary tillandsias-policy debug "$ROOT" 2>/dev/null || true)"
    fi
    [ -n "$PLAN_BIN" ] && DECIDER_NAMES="$DECIDER_NAMES plan-strict-fragments"
    [ -n "$POLICY_BIN" ] && DECIDER_NAMES="$DECIDER_NAMES policy-plan-orders"
fi

_run_decider() { # name -> sets DEC_OUT, returns rc
    local name="$1"
    case "$name" in
        # 1384-ddua: a Lua decider through the one runner. No runner is a
        # loud could-not-run (rc 3), which this phase refuses like any rc.
        check-bash-dialect)
            local _lb=""
            command -v resolve_plan_binary >/dev/null 2>&1 && _lb="$(resolve_plan_binary 2>/dev/null || true)"
            if [ -z "$_lb" ] || ! grep -qx script <<<"$("$_lb" capabilities 2>/dev/null)"; then
                DEC_OUT="could-not-run:check-bash-dialect:no-script-runner — no tillandsias-plan with \`script run\` resolves; rebuild it (cargo build --release -p tillandsias-plan)"
                return 3
            fi
            _cap "$_lb" script run "$SELF_DIR/lua/check-bash-dialect.lua" ;;
        check-sigpipe-verdict-pipelines-added) DEC_OUT="$(TILLANDSIAS_SIGPIPE_BASE="$BASE" bash "$SELF_DIR/check-sigpipe-verdict-pipelines-added.sh" 2>&1)"; return $? ;;
        check-plan-binary-probe-usage) _cap bash "$SELF_DIR/check-plan-binary-probe-usage.sh" ;;
        check-litmus-pin-claims) _cap bash "$SELF_DIR/check-litmus-pin-claims.sh" ;;
        check-script-exec-bits) _cap bash "$SELF_DIR/check-script-exec-bits.sh" ;;
        check-added-fragments-parse) DEC_OUT="$(TILLANDSIAS_FRAGMENT_PARSE_BASE="$BASE" bash "$SELF_DIR/check-added-fragments-parse.sh" 2>&1)"; return $? ;;
        check-scorable-obligation-added) _cap bash "$SELF_DIR/check-scorable-obligation-added.sh" "$BASE" ;;
        check-gate-step-regimes) _cap bash "$SELF_DIR/check-gate-step-regimes.sh" ;;
        check-added-test-is-referenced) DEC_OUT="$(TILLANDSIAS_ADDED_TEST_BASE="$BASE" bash "$SELF_DIR/check-added-test-is-referenced.sh" 2>&1)"; return $? ;;
        check-refusal-affordance-added) DEC_OUT="$(TILLANDSIAS_AFFORDANCE_BASE="$BASE" bash "$SELF_DIR/check-refusal-affordance-added.sh" 2>&1)"; return $? ;;
        check-rust-source-pin-added) DEC_OUT="$(TILLANDSIAS_RUST_PIN_BASE="$BASE" bash "$SELF_DIR/check-rust-source-pin-added.sh" 2>&1)"; return $? ;;
        check-no-python-scripts) _cap bash "$SELF_DIR/check-no-python-scripts.sh" ;;
        check-jq-callsite-ratchet) _cap bash "$SELF_DIR/check-jq-callsite-ratchet.sh" ;;
        preflight-fixtures-default-target) DEC_OUT="$(TILLANDSIAS_DEFAULT_TARGET_BASE="$BASE" bash "$SELF_DIR/preflight-fixtures-default-target.sh" 2>&1)"; return $? ;;
        check-issue-citation-convention) DEC_OUT="$(TILLANDSIAS_ISSUE_CITATION_BASE="$BASE" bash "$SELF_DIR/check-issue-citation-convention.sh" 2>&1)"; return $? ;;
        trace-coverage) _cap bash "$SELF_DIR/trace-coverage.sh" --gate ;;
        plan-strict-fragments) DEC_OUT="$("$PLAN_BIN" check --strict-fragments 2>&1)"; return $? ;;
        policy-plan-orders) DEC_OUT="$("$POLICY_BIN" plan-orders --index plan/index.yaml 2>&1)"; return $? ;;
        *) DEC_OUT="unknown decider $name"; return 3 ;;
    esac
    local _rc=$?
    DEC_OUT="$_CAP_OUT"
    return "$_rc"
}

decider_n=0
FIRST_FAIL_TOKEN=""
FIRST_FAIL_RC=0
for name in $DECIDER_NAMES; do
    if [ "$PLAN_MODE" = 1 ]; then
        echo "plan:decider:$name"
        decider_n=$((decider_n + 1))
        continue
    fi
    # check-no-python-scripts.sh is unlike its siblings: it unconditionally
    # `cargo build`s tillandsias-policy before it can even ask its question
    # (its own header names this — "preflight: serial — cargo-builds ...").
    # That is a CARGO phase by the packet's own definition, so it is stubbed
    # loudly rather than silently, same as cycle-preflight/fmt/crate tests.
    if [ "$name" = "check-no-python-scripts" ] && [ "$STUB" = 1 ]; then
        _item "$name" skip:stub 0
        decider_n=$((decider_n + 1))
        continue
    fi
    _t="$(timing_now_ms)"
    if _run_decider "$name"; then
        _item "$name" ok "$_t"
        decider_n=$((decider_n + 1))
    else
        _item "$name" red "$_t"
        printf '%s\n' "$DEC_OUT" | sed 's/^/  /' >&2
        decider_n=$((decider_n + 1))
        if [ "$KEEP_GOING" != 1 ]; then
            echo "refused:relay-preflight:deciders:$name"
            _afford "$name refused on the merged tree (its own output is above)" \
                "fix what $name named, commit onto the ref that carries it, and re-run relay-preflight"
            _restore_clean
            timing_emit relay-preflight relay "$T0" 1
            exit 1
        fi
        [ -n "$FIRST_FAIL_TOKEN" ] || { FIRST_FAIL_TOKEN="deciders:$name"; FIRST_FAIL_RC=1; }
    fi
done

# ── phase 4: cargo fmt --check, when *.rs moved ─────────────────────────────
fmt_state="skip"
if grep -qE '\.rs$' <<<"$DIFF_ALL"; then
    if [ "$PLAN_MODE" = 1 ]; then
        fmt_state="plan"
    elif [ "$STUB" = 1 ]; then
        _item cargo-fmt skip:stub 0
        fmt_state="skip"
    else
        _t="$(timing_now_ms)"
        if _cap cargo fmt --check; then
            _item cargo-fmt ok "$_t"
            fmt_state="ok"
        else
            _item cargo-fmt red "$_t"
            printf '%s\n' "$_CAP_OUT" | sed 's/^/  /' >&2
            if [ "$KEEP_GOING" != 1 ]; then
                echo "refused:relay-preflight:fmt:cargo-fmt"
                _afford "cargo fmt --check found unformatted Rust in the merged tree" \
                    "run cargo fmt, commit, and re-run"
                _restore_clean
                timing_emit relay-preflight relay "$T0" 1
                exit 1
            fi
            [ -n "$FIRST_FAIL_TOKEN" ] || { FIRST_FAIL_TOKEN="fmt:cargo-fmt"; FIRST_FAIL_RC=1; }
            fmt_state="red"
        fi
    fi
fi
if [ "$PLAN_MODE" = 1 ]; then
    echo "plan:fmt:$([ "$fmt_state" = plan ] && echo ok || echo skip)"
fi

# ── phase 5: touched fixtures, LISTED before any of them run ────────────────
_all_fixtures="$(git ls-files 'scripts/test-*.sh' 2>/dev/null | grep -v '^scripts/test-support/' | LC_ALL=C sort -u)"
_set_a="$(printf '%s\n' "$DIFF_SCRIPTS" | grep -E '^scripts/test-[^/]+\.sh$' | grep -v '^scripts/test-support/' || true)"
_set_b=""
if [ -n "$DIFF_SCRIPTS" ]; then
    while IFS= read -r _fx; do
        [ -n "$_fx" ] || continue
        [ -f "$_fx" ] || continue
        _hit=0
        while IFS= read -r _sp; do
            [ -n "$_sp" ] || continue
            grep -qF -- "$_sp" "$_fx" 2>/dev/null && { _hit=1; break; }
        done <<DIFFEOF
$DIFF_SCRIPTS
DIFFEOF
        [ "$_hit" = 1 ] && _set_b="${_set_b}${_fx}
"
    done <<ALLEOF
$_all_fixtures
ALLEOF
fi
fixtures="$(printf '%s\n%s\n' "$_set_a" "$_set_b" | grep . | LC_ALL=C sort -u)"
fixture_n=0
if [ -n "$fixtures" ]; then
    fixture_n="$(printf '%s\n' "$fixtures" | grep -c .)"
fi
while IFS= read -r _fx; do
    [ -n "$_fx" ] || continue
    if [ "$PLAN_MODE" = 1 ]; then
        echo "plan:fixture:$(basename "$_fx" .sh)"
    else
        echo "item: fixture:$(basename "$_fx" .sh) selected 0" >&2
    fi
done <<FXEOF
$fixtures
FXEOF

if [ "$PLAN_MODE" != 1 ]; then
    while IFS= read -r _fx; do
        [ -n "$_fx" ] || continue
        _name="fixture:$(basename "$_fx" .sh)"
        _t="$(timing_now_ms)"
        if _cap bash "$_fx"; then
            _item "$_name" ok "$_t"
        else
            _item "$_name" red "$_t"
            printf '%s\n' "$_CAP_OUT" | sed 's/^/  /' >&2
            if [ "$KEEP_GOING" != 1 ]; then
                echo "refused:relay-preflight:fixtures:$(basename "$_fx" .sh)"
                _afford "$_fx failed on the merged tree" \
                    "run it directly for the full output, fix it, commit, and re-run"
                _restore_clean
                timing_emit relay-preflight relay "$T0" 1
                exit 1
            fi
            [ -n "$FIRST_FAIL_TOKEN" ] || { FIRST_FAIL_TOKEN="fixtures:$(basename "$_fx" .sh)"; FIRST_FAIL_RC=1; }
        fi
    done <<FXEOF2
$fixtures
FXEOF2
fi

# ── phase 6: crate tests for touched crates ─────────────────────────────────
crate_dirs="$(printf '%s\n' "$DIFF_ALL" | awk -F/ '$1=="crates" && NF>=2 {print $1"/"$2}' | LC_ALL=C sort -u)"
crate_n=0
crate_names=""
if [ -n "$crate_dirs" ]; then
    while IFS= read -r _cd; do
        [ -n "$_cd" ] || continue
        [ -f "$_cd/Cargo.toml" ] || continue
        _cn="$(awk -F'"' '/^name[[:space:]]*=/{print $2; exit}' "$_cd/Cargo.toml" 2>/dev/null)"
        [ -n "$_cn" ] || _cn="$(basename "$_cd")"
        crate_names="${crate_names}${_cn}
"
        crate_n=$((crate_n + 1))
    done <<CDEOF
$crate_dirs
CDEOF
fi
_tray_touched=0
grep -q '^crates/tillandsias-headless/src/tray/' <<<"$DIFF_ALL" && _tray_touched=1

if [ "$PLAN_MODE" = 1 ]; then
    while IFS= read -r _cn; do
        [ -n "$_cn" ] || continue
        echo "plan:crate:$_cn"
    done <<CNEOF
$crate_names
CNEOF
    [ "$_tray_touched" = 1 ] && echo "plan:crate:tillandsias-headless+tray,listen-vsock"
else
    while IFS= read -r _cn; do
        [ -n "$_cn" ] || continue
        if [ "$STUB" = 1 ]; then
            _item "cargo-test:$_cn" skip:stub 0
            continue
        fi
        _t="$(timing_now_ms)"
        if _cap cargo test -p "$_cn"; then
            _item "cargo-test:$_cn" ok "$_t"
        else
            _item "cargo-test:$_cn" red "$_t"
            printf '%s\n' "$_CAP_OUT" | sed 's/^/  /' >&2
            if [ "$KEEP_GOING" != 1 ]; then
                echo "refused:relay-preflight:crates:$_cn"
                _afford "cargo test -p $_cn failed on the merged tree" \
                    "reproduce locally (cargo test -p $_cn), fix, commit, and re-run"
                _restore_clean
                timing_emit relay-preflight relay "$T0" 1
                exit 1
            fi
            [ -n "$FIRST_FAIL_TOKEN" ] || { FIRST_FAIL_TOKEN="crates:$_cn"; FIRST_FAIL_RC=1; }
        fi
    done <<CNEOF2
$crate_names
CNEOF2
    if [ "$_tray_touched" = 1 ]; then
        if [ "$STUB" = 1 ]; then
            _item "cargo-test:tillandsias-headless+tray" skip:stub 0
        else
            _t="$(timing_now_ms)"
            if _cap cargo test -p tillandsias-headless --features tray,listen-vsock -- --test-threads=1; then
                _item "cargo-test:tillandsias-headless+tray" ok "$_t"
            else
                _item "cargo-test:tillandsias-headless+tray" red "$_t"
                printf '%s\n' "$_CAP_OUT" | sed 's/^/  /' >&2
                if [ "$KEEP_GOING" != 1 ]; then
                    echo "refused:relay-preflight:crates:tillandsias-headless+tray"
                    _afford "the tray,listen-vsock serial pass failed on the merged tree" \
                        "reproduce locally, fix, commit, and re-run"
                    _restore_clean
                    timing_emit relay-preflight relay "$T0" 1
                    exit 1
                fi
                [ -n "$FIRST_FAIL_TOKEN" ] || { FIRST_FAIL_TOKEN="crates:tillandsias-headless+tray"; FIRST_FAIL_RC=1; }
            fi
        fi
    fi
fi

# ── phase 7: covering litmus, scoped (T4, 1437-yfuh) ────────────────────────
litmus_run=0
litmus_deferred=0
if [ "$ALL_COVERING" = 1 ]; then
    _lcs_out="$(bash "$SELF_DIR/litmus-covering-specs.sh" --relay-scope --all-covering "$BASE" 2>/dev/null || true)"
else
    _lcs_out="$(bash "$SELF_DIR/litmus-covering-specs.sh" --relay-scope "$BASE" 2>/dev/null || true)"
fi
case "$_lcs_out" in
    unavailable:*) ;;
    *)
        litmus_run="$(printf '%s\n' "$_lcs_out" | grep -c '^run:' || true)"
        litmus_deferred="$(printf '%s\n' "$_lcs_out" | grep -c '^deferred:' || true)"
        ;;
esac
[ -n "${litmus_run:-}" ] || litmus_run=0
[ -n "${litmus_deferred:-}" ] || litmus_deferred=0

if [ "$PLAN_MODE" = 1 ]; then
    printf '%s\n' "$_lcs_out" | awk -F'\t' '$1 ~ /^(run|deferred):/ { split($1,a,":"); print "plan:litmus:" a[1] ":" a[2] }'
else
    _run_specs="$(printf '%s\n' "$_lcs_out" | awk -F'\t' '$1 ~ /^run:/ { split($1,a,":"); print a[3]"\t"$3 }')"
    if [ -n "$_run_specs" ]; then
        while IFS="$(printf '\t')" read -r _spec _size; do
            [ -n "$_spec" ] || continue
            if [ "$STUB" = 1 ]; then
                _item "litmus:$_spec" skip:stub 0
                continue
            fi
            _t="$(timing_now_ms)"
            if _cap bash "$SELF_DIR/run-litmus-test.sh" "$_spec" --phase pre-build --size "${_size:-instant}" --compact; then
                _item "litmus:$_spec" ok "$_t"
            else
                _item "litmus:$_spec" red "$_t"
                printf '%s\n' "$_CAP_OUT" | sed 's/^/  /' >&2
                if [ "$KEEP_GOING" != 1 ]; then
                    echo "refused:relay-preflight:litmus:$_spec"
                    _afford "litmus spec $_spec failed on the merged tree" \
                        "scripts/run-litmus-test.sh $_spec --phase pre-build --compact, fix, commit, and re-run"
                    _restore_clean
                    timing_emit relay-preflight relay "$T0" 1
                    exit 1
                fi
                [ -n "$FIRST_FAIL_TOKEN" ] || { FIRST_FAIL_TOKEN="litmus:$_spec"; FIRST_FAIL_RC=1; }
            fi
        done <<LTEOF
$_run_specs
LTEOF
    fi
fi

# ── phase 8: one verdict line ────────────────────────────────────────────────
if [ -n "$FIRST_FAIL_TOKEN" ]; then
    echo "refused:relay-preflight:$FIRST_FAIL_TOKEN"
    _afford "the first red phase under --keep-going was $FIRST_FAIL_TOKEN (every item ran; see the item: lines above)" \
        "fix what $FIRST_FAIL_TOKEN named, commit, and re-run"
    _restore_clean
    timing_emit relay-preflight relay "$T0" "$FIRST_FAIL_RC"
    exit "$FIRST_FAIL_RC"
fi

if [ "$PLAN_MODE" = 1 ]; then
    echo "ok:relay-preflight:plan:refs=${#refs[@]} deciders=$decider_n fixtures=$fixture_n crates=$crate_n litmus=${litmus_run}/${litmus_deferred}"
    timing_emit relay-preflight relay "$T0" 0
    exit 0
fi

echo "ok:relay-preflight:${MERGED_SHA}:refs=${#refs[@]} deciders=$decider_n fmt=${fmt_state} fixtures=$fixture_n crates=$crate_n litmus=${litmus_run}/${litmus_deferred}"
timing_emit relay-preflight relay "$T0" 0
exit 0
