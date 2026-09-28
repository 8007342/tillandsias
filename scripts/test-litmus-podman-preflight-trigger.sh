#!/usr/bin/env bash
# @trace order:1464-v3xq, spec:spec-traceability
#
# test-litmus-podman-preflight-trigger.sh — the litmus runner's podman
# preflight fires when a step INVOKES podman, not when a step's text mentions
# the word. Pre-fix, litmus:expert-groundtruth-harness (which grades the
# question "how do I run podman rootless" inside a quoted body) was ENV-FAILed
# whole before step 1 on every host whose `podman ps` fails.
#
# Under a fake `podman` that fails (first on PATH, so the runner's shim
# delegates to it — deterministic on every Linux host, podman or not):
#   1  a test whose only podman mentions are PROSE (a quoted grading question,
#      a grep pattern, an echo message, `command -v podman`) RUNS and PASSES
#   2  a test that invokes podman in command position still ENV-FAILs naming
#      podman; so does `bash -lc '... podman ...'`
#   3  the helper answers a table of shapes: command position, after ; && |
#      $( (, wrappers (timeout N, env, systemd-run --user -p X=y --setenv=Z,
#      sudo), VAR=value prefixes, absolute paths, require_podman, a quoted
#      `sh -c` script — yes; quoted prose, grep patterns, crate names, echo
#      text, `command -v`, `vm-exec -- podman` (the VM's podman) — no
# The preflight is Linux-only by design; on another OS arms 1-2 are a named
# skip and arm 3 still runs.
#
# Pre-fix: FAILS at arm 1 (the prose-only test is [ENV-FAIL]), and at arm 2 too:
# the substring rule needed a space, ; | & or ( before the word, so a quoted
# command STARTING with podman ("podman ps …", bash -lc 'podman …') never
# triggered — it was wrong in both directions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/podman-preflight-trigger.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
skipped=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }
skip() { echo "skip: $1"; skipped=$((skipped + 1)); }

# ── 3: the helper, over a table ─────────────────────────────────────────────
eval "$(sed -n '/^_lt_command_invokes_podman() {/,/^}/p' "$ROOT/scripts/run-litmus-test.sh")"
HAVE_HELPER=1
declare -F _lt_command_invokes_podman >/dev/null || { HAVE_HELPER=0; bad "arm 3: _lt_command_invokes_podman is not defined in run-litmus-test.sh"; }
t_yes=0
t_no=0
case_is() { # case_is yes|no <command value as it appears after `command: `>
    printf '    command: %s\n' "$2" >"$W/case.yaml"
    local got=no
    _lt_command_invokes_podman "$W/case.yaml" && got=yes
    if [ "$got" = "$1" ]; then
        [ "$1" = yes ] && t_yes=$((t_yes + 1)) || t_no=$((t_no + 1))
    else
        bad "arm 3: [$2] -> $got, want $1"
    fi
}
if [ "$HAVE_HELPER" = 1 ]; then
case_is yes '"podman ps"'
case_is yes '"set -e; podman info >/dev/null && echo ok"'
case_is yes '"x=$(podman images -q | head -1); test -n \"$x\""'
case_is yes '"true && /usr/bin/podman run --rm x"'
case_is yes '"timeout 5 podman ps"'
case_is yes '"DOCKER_HOST=unix:///x.sock podman info"'
case_is yes '"out=$(systemd-run --user --wait --pipe -p NoNewPrivileges=yes --setenv=CONTAINER_HOST=unix://x podman info --format x)"'
case_is yes "\"bash -lc 'FORGE_IMG=\$(podman images --format x | head -1) && podman run --rm \$FORGE_IMG true'\""  # sigpipe-ok: quoted test DATA fed to the trigger classifier, never executed
case_is yes "'b=\"\${XDG_RUNTIME_DIR}/x\"; podman rm -f \$(podman ps -a -q) 2>/dev/null || true'"
case_is yes "\"bash -c 'source scripts/common.sh && require_podman && echo ok'\""
case_is no "\"PB=x; printf '%s' 'query: how do I run podman rootless' > f; echo ok\""
case_is no "\"grep -F 'podman build' scripts/build-image.sh\""
case_is no '"grep -F \"exec podman run\" run-forge-standalone.sh"'
case_is no '"cargo test -p tillandsias-podman launch::tests::x"'
case_is no "\"if x; then echo 'FAIL: a GPU podman cannot deliver'; fi\""
case_is no "\"bash -c 'b=\$(command -v podman || true); test -n \\\"\$b\\\"'\""
case_is no "\"bash -lc 'cargo run --example vm-exec -- podman ps'\""
fi
if [ "$HAVE_HELPER" = 1 ] && [ "$fail" -eq 0 ]; then
    ok "arm 3: the helper answers $t_yes invocation shapes yes and $t_no prose shapes no"
fi

# ── 1 and 2: through the runner ─────────────────────────────────────────────
if [ "$(uname -s)" != Linux ]; then
    skip "arms 1-2: the podman preflight is Linux-only by design (run-litmus-test.sh)"
else
    mkdir -p "$W/bin" "$W/lt"
    printf '#!/bin/sh\necho "fake podman: storage is broken" >&2\nexit 1\n' >"$W/bin/podman"
    chmod +x "$W/bin/podman"
    LIT="litmus"
    cat >"$W/bindings.yaml" <<YAML
version: '1.0'
description: fixture for 1464-v3xq
specs:
- spec_id: spec-traceability
  status: active
  ${LIT}_tests:
  - ${LIT}:v3xq-probe
  coverage_ratio: 100
  last_verified: '2026-09-28'
YAML
    probe() { # probe <command> -> the runner's cleaned output
        cat >"$W/lt/${LIT}-v3xq-probe.yaml" <<YAML
name: ${LIT}:v3xq-probe
spec: spec-traceability
phase: pre-build
severity: high
size: instant
description: >
  probe for 1464-v3xq
critical_path:
  - step: "probe"
    command: "$1"
    timeout_ms: 20000
    expected_behavior: "probe-done"
YAML
        (cd "$ROOT" && PATH="$W/bin:$PATH" TILLANDSIAS_REAL_PODMAN="$W/bin/podman" \
            TILLANDSIAS_LITMUS_BINDINGS="$W/bindings.yaml" TILLANDSIAS_LITMUS_TESTS_DIR="$W/lt" \
            timeout 120 bash scripts/run-litmus-test.sh spec-traceability --phase pre-build --size instant 2>&1 |
            sed 's/\x1b\[[0-9;]*m//g')
    }
    out="$(probe "printf '%s\\\\n' 'query: how do I run podman rootless' > /dev/null; command -v podman >/dev/null || true; echo 'grep pattern: exec podman run' >/dev/null; echo probe-done")"
    if grep -qE 'Status: \[PASS\]' <<<"$out" && ! grep -q 'ENV-FAIL' <<<"$out"; then
        ok "arm 1: a test that only MENTIONS podman (a quoted question, command -v, an echoed pattern) runs and passes"
    else
        bad "arm 1: [$(grep -E 'ENV-FAIL|Status|FAIL' <<<"$out" | head -3)]"
    fi
    out="$(probe "podman ps >/dev/null 2>&1; echo probe-done")"
    if grep -q "\[ENV-FAIL\].*podman ps" <<<"$out"; then
        ok "arm 2: a test that invokes podman in command position still ENV-FAILs naming podman"
    else
        bad "arm 2 direct: [$(grep -E 'ENV-FAIL|Status' <<<"$out" | head -3)]"
    fi
    out="$(probe "bash -lc 'podman images -q >/dev/null'; echo probe-done")"
    if grep -q "\[ENV-FAIL\].*podman ps" <<<"$out"; then
        ok "arm 2: podman inside a quoted bash -lc script still ENV-FAILs"
    else
        bad "arm 2 bash -lc: [$(grep -E 'ENV-FAIL|Status' <<<"$out" | head -3)]"
    fi
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: litmus-podman-preflight-trigger $pass/$total skipped=$skipped (1464-v3xq)"
    exit 0
fi
echo "FAIL: litmus-podman-preflight-trigger $pass/$total skipped=$skipped (1464-v3xq)"
exit 1
