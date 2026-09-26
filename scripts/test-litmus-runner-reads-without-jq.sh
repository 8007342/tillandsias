#!/usr/bin/env bash
# test-litmus-runner-reads-without-jq.sh — order 1375-6pnd.
#
# The litmus runner is the release tier's own instrument, so the set of tests
# it SELECTS must not depend on which JSON/YAML tools the host happens to have.
# Its metadata reads (phase, size, host_kind, inputs, and the bindings query
# for a spec's tests) used to go `yaml-json | jq`, then yq, then a grep tier
# that cannot read a dotted path — so a host without jq and yq ran a
# DIFFERENT selection and still printed a verdict.
#
# The fixture runs the same spec twice on the same tree:
#   A  the host PATH (jq and yq as installed)
#   B  a leading PATH directory whose jq, yq AND toolbox are stubs that log
#      their calls and exit 127, and an EMPTY runtime dir (the runner otherwise
#      prepends a cached toolbox-extracted yq ahead of PATH, so the first cut of
#      this fixture shadowed only jq and passed pre-fix)
# and asserts the SELECTION is byte-identical: the ordered `Executing
# litmus:<name>` lines plus the `Total: N (executed: E, skipped: S)` line.
# The stubs must have been reached in B (a log with no calls means the shadow
# did not take, and the run proves nothing): blocked:stub-not-reached.
#
#   PASS: litmus-runner-reads-without-jq selection=<n> tests   (rc 0)
#   FAIL: ... selection differs (the diff is printed)          (rc 1)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="${LITMUS_SELECTION_SPEC:-git-mirror-service}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/litmus-nojq.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/stubs"
for t in jq yq toolbox; do
    cat > "$scratch/stubs/$t" <<'STUB'
#!/bin/sh
echo "$(basename "$0") $*" >> "${LITMUS_STUB_LOG:?}"
exit 127
STUB
    chmod +x "$scratch/stubs/$t"
done
export LITMUS_STUB_LOG="$scratch/calls.log"
: > "$LITMUS_STUB_LOG"

selection() {   # <log> -> the ordered selection, colour stripped
    sed 's/\x1b\[[0-9;]*m//g' "$1" \
        | grep -E '^ℹ Executing litmus:|^  Total: [0-9]+ \(executed: [0-9]+, skipped: [0-9]+\)' \
        | sed 's/^ℹ Executing //'
}

run() {   # <label> [PATH prefix]
    if [ -n "${2:-}" ]; then
        TILLANDSIAS_LITMUS_RUNTIME_DIR="$scratch/runtime-$1" PATH="$2:$PATH" timeout 900 bash "$ROOT/scripts/run-litmus-test.sh" "$SPEC" \
            --phase pre-build --size instant --compact > "$scratch/$1.log" 2>&1
    else
        timeout 900 bash "$ROOT/scripts/run-litmus-test.sh" "$SPEC" \
            --phase pre-build --size instant --compact > "$scratch/$1.log" 2>&1
    fi
    selection "$scratch/$1.log" > "$scratch/$1.sel"
}

run with-tools
run without-tools "$scratch/stubs"

# THE DISCRIMINATING ARM. On today's corpus every phase/size line is a bare
# `key: value`, which the awk fallback happens to read correctly, so the live
# arm above passed even BEFORE the fix (recorded as this row's first event).
# The divergence is latent: valid YAML that is not a bare literal. This scratch
# spec carries one of each: t-plain (selected either way), t-quoted
# (`phase: "pre-build"` and a trailing comment on size, selected by a real
# YAML reader, dropped by the awk tier), t-runtime (never selected).
ctl="$scratch/ctl"
mkdir -p "$ctl/tests"
for t in plain quoted runtime; do
    case "$t" in
        plain)   meta='phase: pre-build
size: instant' ;;
        quoted)  meta='phase: "pre-build"
size: instant  # a comment is valid YAML'"'"'s business, not part of the value' ;;
        runtime) meta='phase: runtime
size: instant' ;;
    esac
    cat > "$ctl/tests/litmus-fx6pnd-$t.yaml" <<EOF
name: litmus:fx6pnd-$t
spec: fx6pnd
$meta
description: 1375-6pnd selection fixture ($t)
critical_path:
  - step: "a step that asks no hard question"
    command: "echo ok"
    expected_behavior: "ok"
    timeout_ms: 5000
EOF
done
cat > "$ctl/bindings.yaml" <<'EOF'
specs:
- spec_id: fx6pnd
  status: active
  litmus_tests:
  - litmus:fx6pnd-plain
  - litmus:fx6pnd-quoted
  - litmus:fx6pnd-runtime
EOF
ctl_run() {   # <label> [PATH prefix]
    local p="${2:+$2:}$PATH"
    [ -n "${2:-}" ] && export TILLANDSIAS_LITMUS_RUNTIME_DIR="$scratch/runtime-$1"
    PATH="$p" TILLANDSIAS_LITMUS_TESTS_DIR="$ctl/tests" TILLANDSIAS_LITMUS_BINDINGS="$ctl/bindings.yaml" \
        timeout 300 bash "$ROOT/scripts/run-litmus-test.sh" fx6pnd \
        --phase pre-build --size instant --compact > "$scratch/$1.log" 2>&1
    selection "$scratch/$1.log" > "$scratch/$1.sel"
}
ctl_run ctl-with-tools
ctl_run ctl-without-tools "$scratch/stubs"
unset TILLANDSIAS_LITMUS_RUNTIME_DIR
want="$(printf 'litmus:fx6pnd-plain...\nlitmus:fx6pnd-quoted...\n')"
got_with="$(grep '^litmus:' "$scratch/ctl-with-tools.sel")"
got_without="$(grep '^litmus:' "$scratch/ctl-without-tools.sel")"
if [ "$got_with" != "$want" ]; then
    echo "blocked:control-arm-misread — with jq/yq present the runner did not select exactly plain+quoted:"
    printf '  %s\n' "$got_with"
    exit 1
fi
if ! cmp -s "$scratch/ctl-with-tools.sel" "$scratch/ctl-without-tools.sel"; then
    echo "FAIL: control arm — without jq/yq the runner selected a DIFFERENT set for valid YAML (1375-6pnd):"
    diff "$scratch/ctl-with-tools.sel" "$scratch/ctl-without-tools.sel" | sed 's/^/  /'
    exit 1
fi
echo "ok:   control arm: a quoted/commented phase is selected identically with and without jq/yq (plain+quoted, runtime excluded)"

if [ ! -s "$LITMUS_STUB_LOG" ]; then
    echo "blocked:stub-not-reached — the PATH shadow did not take, so run B proves nothing"
    exit 1
fi
n="$(grep -c '^litmus:' "$scratch/with-tools.sel" || true)"
if [ "${n:-0}" -eq 0 ]; then
    echo "blocked:empty-selection — run A selected no tests, so equality would be vacuous"
    sed -n '1,20p' "$scratch/with-tools.log" | sed 's/\x1b\[[0-9;]*m//g'
    exit 1
fi
if cmp -s "$scratch/with-tools.sel" "$scratch/without-tools.sel"; then
    printf 'ok:   stub calls in run B: %s (jq/yq shadowed, reached)\n' "$(wc -l < "$LITMUS_STUB_LOG" | tr -d ' ')"
    printf 'PASS: litmus-runner-reads-without-jq selection=%s tests, byte-identical with and without jq/yq (1375-6pnd)\n' "$n"
    exit 0
fi
echo "FAIL: the runner selected a DIFFERENT test set without jq/yq (1375-6pnd):"
diff "$scratch/with-tools.sel" "$scratch/without-tools.sel" | sed 's/^/  /' | head -40
exit 1
