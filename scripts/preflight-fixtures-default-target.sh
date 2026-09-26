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
# is someone else's defect and is reported as a note, never as this class.
#
# POPULATION: scripts/test-*.sh added or changed against the base (default
# origin/linux-next, override TILLANDSIAS_DEFAULT_TARGET_BASE), plus untracked
# ones, or the fixtures named as arguments.
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
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3
DEADLINE="${TILLANDSIAS_DEFAULT_TARGET_DEADLINE:-300}"

if [ "$#" -gt 0 ]; then
    fixtures="$(printf '%s\n' "$@")"
else
    base_ref="${TILLANDSIAS_DEFAULT_TARGET_BASE:-origin/linux-next}"
    if ! git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
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
if ! (cd "$ROOT" && env -u CARGO_TARGET_DIR -u TILLANDSIAS_PLAN_BIN PATH="$stripped_path"         bash -c '. scripts/plan-binary-probe.sh && resolve_plan_binary' >/dev/null 2>&1); then
    echo "skip:fixture-default-target:no-default-target-plan-binary"
    exit 0
fi

scratch="$(mktemp -d)" || exit 3
trap 'rm -rf "$scratch"' EXIT

_bounded() { # run "$@" under the deadline when timeout exists
    if command -v timeout >/dev/null 2>&1; then timeout "$DEADLINE" "$@"; else "$@"; fi
}

checked=0; refused=0
while IFS= read -r f; do
    case "$f" in scripts/test-*.sh) ;; *) continue ;; esac
    [ -f "$ROOT/$f" ] || continue
    # Its own fixture drives copies of this decider in scratch repos; running it
    # here would only nest the same runs. Gate step 530 runs it.
    [ "$f" = "scripts/test-preflight-fixtures-default-target.sh" ] && continue
    checked=$((checked + 1))
    normal="$(cd "$scratch" && _bounded bash "$ROOT/$f" 2>&1)"; rc_n=$?
    strip="$(cd "$scratch" && env -u CARGO_TARGET_DIR -u TILLANDSIAS_PLAN_BIN PATH="$stripped_path" \
             bash -c '_b() { if command -v timeout >/dev/null 2>&1; then timeout "$0" "$@"; else "$@"; fi; }; _b bash "$1"' \
             "$DEADLINE" "$ROOT/$f" 2>&1)"; rc_s=$?
    if [ "$rc_n" -ne 0 ]; then
        echo "note:fixture-default-target:red-in-both-or-normal-regime:$f:rc=$rc_n" >&2
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
    fi
done <<EOF
$fixtures
EOF

[ "$refused" -eq 0 ] || exit 1
echo "ok:fixture-default-target:$checked checked"
