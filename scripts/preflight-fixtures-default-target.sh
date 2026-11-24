#!/usr/bin/env bash
# @trace order:1401-x76w, spec:ci-release
#
# preflight-fixtures-default-target.sh — RUN every added fixture in the regime
# an ordinary checkout has, and refuse one that only passes where the plan
# binary is found some other way.
#
# THE CLASS. resolve_plan_binary (scripts/plan-binary-probe.sh) falls back to
# the cwd-RELATIVE ./target/release path. A script that resolves after a cd,
# or is run by its fixture from another cwd, then finds nothing. Every forge
# and the Linux builder toolbox export an absolute CARGO_TARGET_DIR, which the
# resolver tries first, so the author's run passes and the red appears only at
# relay or on a Mac gate. Three instances on 2026-09-26: 1380-u7sq, 1395-88tp,
# and 1375-2x4e's hardware-fingerprint.sh, which reddened every Mac --check
# until 84f37ff24.
#
# THE REGIME, measured by the coordinator on the row: unsetting
# CARGO_TARGET_DIR and TILLANDSIAS_PLAN_BIN is NOT enough on a host with an
# installed copy on PATH (~/.local/bin/tillandsias-plan answers `command -v`
# and masks the defect). So every PATH entry holding a tillandsias-plan (or
# tillandsias-plan.exe) is stripped too.
#
# WHY IT RUNS THE FIXTURE AND DOES NOT GREP. A grep for `cd` before a resolve
# is the mention trap: it cannot tell a cd that is absolutised afterwards from
# one that is not, and it misses a fixture that runs its subject from `/`.
#
# THE VERDICT IS DIFFERENTIAL. Each fixture runs twice from the same scratch
# cwd outside the checkout: once with the caller's environment, once stripped.
# It is refused only if the normal run passes and the stripped run fails, or
# prints a skip: line the normal run did not (a fixture that skips when it
# cannot find the binary is exactly as blind). A fixture red in BOTH regimes
# is not this class, but it is not nothing either (2262-5kk6): it is a NOTE only
# when a gate step or an inline build.sh step runs that fixture and so reports it,
# and the note names that step. A litmus binding is not enough: the suite is not in
# --check (748-tkjx). One nothing gates is REFUSED here, or it stays red unseen.
# One that is green from the checkout, where a gate runs it, is red only from this
# guard's scratch cwd: a note of its own (#1358's test-scorable-closure-quoting).
# Exit 3 with a could-not-run: line is a note: nothing was tested. Either way the
# fixture's own last verdict line is carried.
#
# POPULATION: scripts/test-*.sh and scripts/lua/test-*.lua added or changed
# against the base (default origin/linux-next, override
# TILLANDSIAS_DEFAULT_TARGET_BASE), plus untracked ones, or the fixtures named
# as arguments.
#
# LUA FIXTURES (2206-js5t). The fleet is porting fixtures from .sh to Lua, and
# this decider used to count none of them (`0 checked` on a three-port ref).
# A Lua fixture runs as the gate runs STEP_LUA: `<plan> script run <file>`
# with the checkout as cwd (the runtime's fs.* are repo-relative), so it is NOT
# run from the scratch cwd. The runner itself is resolved in each regime the
# way the gate resolves it. The masks that matter are a plan binary on PATH and
# the CARGO_TARGET_DIR (1593-1ny6), TILLANDSIAS_PLAN_BIN and
# TILLANDSIAS_SCRIPT_RUNNER_BIN the runtime passes to every child; the stripped
# regime removes all of them, as it does for a .sh fixture.
#
# THE GATE'S OWN VARIABLES (2305-zm8j). The runtime also passes every other
# TILLANDSIAS_* name, so a Lua fixture whose subject reads one is green on its
# author's host and red in a gate that exports it: #1488 and #1491 were evicted,
# #1490 landed with the hole. A Lua fixture green in both regimes above runs a
# third time with GATE_ENV set: a CARGO_TARGET_DIR that holds a (fake) product
# binary and the names a gate, a forge lane or a caller exports. Red there is
# refused. The runner is passed explicitly and a plan binary is in that target
# dir, so nothing here hides the tools. A deadline there is a note. MEASURED on
# lenovinha 2026-11-24 over 238 Lua fixtures (no podman, toolbox or cargo
# build): 226 green both ways, 1 red, 1 past the 60 s bound. A .sh is not run a third time.
#
# WINDOWS (MSYS). The stripped regime works the same: the resolver's
# ./target/release/tillandsias-plan.exe candidate is the default target there.
# What this arm does NOT reproduce on Windows is the Mac PATH (no
# ~/.local/bin copy is installed by the Windows installer), which the
# stripping makes irrelevant. It SKIPS, by name, when the checkout has no
# default-target plan binary at all (a WSL-only build leaves only the ELF in
# the distro's CARGO_TARGET_DIR): then the stripped regime cannot find a
# binary for ANY fixture and a refusal would say nothing about the fixture.
#
# Verdicts (last line):
#   ok:fixture-default-target:<n> checked
#   skip:fixture-default-target:<reason>
#   refused:fixture-default-target:<script>   (one per offender, exit 1)
#   refused:fixture-default-target:ungated-red:<script>   (2262-5kk6, exit 1)
#   refused:fixture-default-target:gate-env:<script>   (2305-zm8j, exit 1)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3
DEADLINE="${TILLANDSIAS_DEFAULT_TARGET_DEADLINE:-300}"

# Every run is BOUNDED, or none happens: an added fixture that hangs must not
# hang every gate. A stock macOS has no `timeout`; Homebrew coreutils installs
# `gtimeout`. With neither, skip by name rather than run unbounded.
# TILLANDSIAS_DEFAULT_TARGET_TIMEOUT_CMD overrides the lookup (fixture seam;
# "none" forces the skip).
TIMEOUT_CMD="${TILLANDSIAS_DEFAULT_TARGET_TIMEOUT_CMD:-$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)}"
if [ -z "$TIMEOUT_CMD" ] || [ "$TIMEOUT_CMD" = none ]; then
    echo "skip:fixture-default-target:no-timeout-command"
    exit 0
fi

if [ "$#" -gt 0 ]; then
    fixtures="$(printf '%s\n' "$@")"
else
    base_ref="${TILLANDSIAS_DEFAULT_TARGET_BASE:-${TILLANDSIAS_GATE_DIFF_BASE:-origin/linux-next}}"
    if ! git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null 2>&1; then
        echo "skip:fixture-default-target:base-ref-unavailable:$base_ref"
        exit 0
    fi
    fixtures="$({ git diff --name-only --diff-filter=AM "$base_ref" 2>/dev/null
                  git ls-files --others --exclude-standard 2>/dev/null; } | LC_ALL=C sort -u)"
fi

# PATH with every entry that holds a plan binary removed.
stripped_path=""
_ifs="$IFS"; IFS=:
for d in $PATH; do
    [ -n "$d" ] || continue
    if [ -e "$d/tillandsias-plan" ] || [ -e "$d/tillandsias-plan.exe" ]; then continue; fi
    stripped_path="${stripped_path:+$stripped_path:}$d"
done
IFS="$_ifs"

# The stripped regime must still find a binary from the checkout itself, or a
# refusal would say nothing about the fixture. Resolve it the way the
# fixtures do (plan-binary-probe.sh), in that regime, which also RUNS it.
if ! (cd "$ROOT" && env -u CARGO_TARGET_DIR -u TILLANDSIAS_PLAN_BIN PATH="$stripped_path" \
        bash -c '. scripts/plan-binary-probe.sh && resolve_plan_binary' >/dev/null 2>&1); then
    echo "skip:fixture-default-target:no-default-target-plan-binary"
    exit 0
fi

# The Lua runner in each regime, absolute (a .lua fixture is run by it).
_abs_runner() {
    local r
    r="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary)" || return 1
    case "$r" in /*) ;; *) r="$ROOT/${r#./}" ;; esac
    printf '%s\n' "$r"
}
runner_n="$(_abs_runner 2>/dev/null)" || runner_n=""
runner_s="$(env -u CARGO_TARGET_DIR -u TILLANDSIAS_PLAN_BIN -u TILLANDSIAS_SCRIPT_RUNNER_BIN PATH="$stripped_path" \
    bash -c "$(declare -f _abs_runner); ROOT='$ROOT'; _abs_runner" 2>/dev/null)" || runner_s=""

scratch="$(mktemp -d)" || exit 3
trap 'rm -rf "$scratch"' EXIT

GATE_ENV=()
_gate_env() { # sets GATE_ENV, once: what a gate exports, with a fake product binary
    [ "${#GATE_ENV[@]}" -eq 0 ] || return 0
    local g="$scratch/gate-target"
    mkdir -p "$g/debug" "$g/release" && cp "$runner_n" "$g/release/${runner_n##*/}" || return 1
    printf '#!/bin/sh\necho gate-env\n' > "$g/debug/tillandsias" && chmod +x "$g/debug/tillandsias" || return 1
    GATE_ENV=(CARGO_TARGET_DIR="$g" TILLANDSIAS_SURFACE_ROOT="$ROOT" TILLANDSIAS_BIN="$g/debug/tillandsias"
        TILLANDSIAS_HOST_KIND=forge TILLANDSIAS_FORGE_SEED_BRANCH=gate-env
        TILLANDSIAS_EMBED_ENDPOINT=http://gate-env.invalid/v1 TILLANDSIAS_TIMING_RUN_ID=gate-env)
}
_bounded() { # run "$@" under the deadline
    "$TIMEOUT_CMD" "$DEADLINE" "$@"
}

# 2262-5kk6: the gate step that runs fixture $1 and fails on it, or nothing.
_gated_by() {
    local st
    for st in scripts/gate-steps.d/*.step; do
        [ -f "$st" ] || continue
        if grep -qxF -e "STEP_SCRIPT=\"$1\"" -e "STEP_LUA=\"$1\"" "$st"; then
            printf 'step %s' "${st##*/}"; return 0
        fi
    done
    # An inline call that fails the build: not a comment, not `|| true`.
    if awk -v f="$1" '/^[[:space:]]*#/ || /\|\|[[:space:]]*(true|:)/ { next }
            index($0, "_run bash \"$SCRIPT_DIR/" f "\"") || index($0, "_run_lua_decider \"" f "\"") { hit = 1; exit }
            END { exit !hit }' build.sh 2>/dev/null; then
        printf 'build.sh inline step'; return 0
    fi
    return 1
}
# The fixture's own words: its last verdict or FAIL line, else its last line.
_last_word() {
    awk 'NF { last = $0 } /^(FAIL|fail|violation|refused|blocked|could-not-run|red)[: ]/ { v = $0 }
         END { print substr(v != "" ? v : last, 1, 200) }' <<<"$1"
}

checked=0; refused=0
while IFS= read -r f; do
    # A case `*` matches `/`, so scripts/test-support/podman-mock.sh, a helper that
    # exits 97 when run bare, read as a red fixture (2297-vrsa). Only files directly
    # in the two directories are fixtures.
    case "$f" in scripts/test-*/*|scripts/lua/test-*/*) continue ;; esac
    case "$f" in scripts/test-*.sh) kind=sh ;; scripts/lua/test-*.lua) kind=lua ;; *) continue ;; esac
    [ -f "$ROOT/$f" ] || continue
    # Its own fixture drives copies of this decider in scratch repos; running it
    # here would only nest the same runs. Gate step 530 runs it.
    [ "$f" = "scripts/test-preflight-fixtures-default-target.sh" ] && continue
    # ORDER 2207-v7x2: a fixture that drives LIVE host state (a running
    # container) declares `# @live-fixture <OPT-IN-VAR>` (`-- @live-fixture`
    # in a Lua fixture) and is never run from here: a land gate that ran
    # test-vault-shutdown-forwards-sigterm.sh as a "changed fixture" stopped
    # yoga's live vault (2026-11-21).
    if grep -qE '^(#|--) @live-fixture ' "$ROOT/$f" 2>/dev/null; then
        echo "skip:fixture-default-target:live-fixture:$f" >&2
        continue
    fi
    if [ "$kind" = lua ] && [ -z "$runner_n" ]; then
        echo "note:fixture-default-target:no-lua-runner-in-caller-regime:$f" >&2
        continue
    fi
    checked=$((checked + 1))
    if [ "$kind" = sh ]; then
        normal="$(cd "$scratch" && _bounded bash "$ROOT/$f" 2>&1)"; rc_n=$?
        strip="$(cd "$scratch" && env -u CARGO_TARGET_DIR -u TILLANDSIAS_PLAN_BIN PATH="$stripped_path" \
                 "$TIMEOUT_CMD" "$DEADLINE" bash "$ROOT/$f" 2>&1)"; rc_s=$?
    else
        normal="$(cd "$ROOT" && _bounded env TILLANDSIAS_SCRIPT_RUNNER_BIN="$runner_n" "$runner_n" script run "$ROOT/$f" 2>&1)"; rc_n=$?
        if [ -n "$runner_s" ]; then
            strip="$(cd "$ROOT" && env -u CARGO_TARGET_DIR -u TILLANDSIAS_PLAN_BIN PATH="$stripped_path" \
                     TILLANDSIAS_SCRIPT_RUNNER_BIN="$runner_s" \
                     "$TIMEOUT_CMD" "$DEADLINE" "$runner_s" script run "$ROOT/$f" 2>&1)"; rc_s=$?
        else
            strip="no default-target Lua runner"; rc_s=3
        fi
    fi
    if [ "$rc_n" -ne 0 ]; then
        said="$(_last_word "$normal")"
        [ "$rc_n" -ne 124 ] || said="no answer within ${DEADLINE}s; last line: $said"
        if [ "$rc_n" -eq 3 ] && grep -q '^could-not-run:' <<<"$normal"; then
            echo "note:fixture-default-target:could-not-run:$f — $said" >&2
        elif [ "$kind" = sh ] && [ "$rc_n" -ne 124 ] && (cd "$ROOT" && _bounded bash "$ROOT/$f" >/dev/null 2>&1); then
            # Red only because this guard starts it outside the checkout (a bare
            # `git` finds no repository there); a gate runs it from the root.
            echo "note:fixture-default-target:red-only-from-scratch-cwd:$f:rc=$rc_n — $said" >&2
        elif gate="$(_gated_by "$f")"; then
            echo "note:fixture-default-target:red-in-both-or-normal-regime:$f:rc=$rc_n gated-by: $gate — $said" >&2
        else
            echo "note:fixture-default-target:red-in-both-or-normal-regime:$f:rc=$rc_n ungated — $said" >&2
            echo "  why: $f fails in the caller's own regime and no gate step or inline build.sh step runs it, so nothing else would report it" >&2
            echo "  remedy: make it green (it failed from the checkout too), or wire it to a gate step" >&2
            echo "refused:fixture-default-target:ungated-red:$f"
            refused=$((refused + 1))
        fi
        continue
    fi
    skip_n=0; skip_s=0
    case "$normal" in *skip:*) skip_n=1 ;; esac
    case "$strip" in *skip:*) skip_s=1 ;; esac
    if [ "$rc_s" -ne 0 ] || { [ "$skip_s" -eq 1 ] && [ "$skip_n" -eq 0 ]; }; then
        echo "  $f passes with the caller's plan-binary regime and fails without it (rc=$rc_s):" >&2
        printf '%s\n' "$strip" | tail -5 | sed 's/^/    | /' >&2
        echo "  remedy: resolve the plan binary inside the checkout and absolutise it before any cd (see 84f37ff24)" >&2
        echo "refused:fixture-default-target:$f"
        refused=$((refused + 1))
        continue
    fi
    if [ "$kind" = lua ]; then
        _gate_env || { echo "note:fixture-default-target:no-gate-env-dir:$f" >&2; continue; }
        under="$(cd "$ROOT" && _bounded env "${GATE_ENV[@]}" TILLANDSIAS_SCRIPT_RUNNER_BIN="$runner_n" "$runner_n" script run "$ROOT/$f" 2>&1)"; rc_g=$?
        if [ "$rc_g" -eq 124 ]; then
            echo "note:fixture-default-target:gate-env-no-answer:$f — past ${DEADLINE}s" >&2
        elif [ "$rc_g" -ne 0 ]; then
            echo "  $f is green here and red under a gate's own variables (rc=$rc_g): $(_last_word "$under")" >&2
            echo "  why: the runtime passes TILLANDSIAS_* and CARGO_TARGET_DIR to the fixture's subject" >&2
            echo "  remedy: drop them on that call: env_unset = { \"TILLANDSIAS_*\", \"CARGO_TARGET_DIR\" }" >&2
            echo "refused:fixture-default-target:gate-env:$f"
            refused=$((refused + 1))
        fi
    fi
done <<EOF
$fixtures
EOF

[ "$refused" -eq 0 ] || exit 1
echo "ok:fixture-default-target:$checked checked"
