#!/usr/bin/env bash
# @trace spec:litmus-framework, plan 797-5kqe
#
# test-litmus-podman-preflight-diagnosis.sh — two fixtures, and they are the
# whole specification.
#
# The litmus runner's podman preflight was `! timeout 5 podman ps`, and it
# announced EVERY non-zero exit as "podman unresponsive (>5s): stalled storage
# lock or dead runtime — environmental, not a code regression". `timeout`
# returns 124 only on an actual timeout; otherwise it returns the command's own
# status. So a podman that failed instantly — exit 127 from a generated wrapper
# whose exec target had been deleted — was described as one that stalled for
# more than five seconds, with a confident named cause and a citation.
# It cost this cycle roughly four hours and three wrong root causes while
# podman answered `info` in 0.07s throughout.
#
# So:
#   fixture A — a podman that exits non-zero INSTANTLY must NOT be described
#               as ">5s", must not be classified as environmental, and must
#               quote podman's own stderr.
#   fixture B — a podman that sleeps past the deadline MUST be described as a
#               timeout.
#
# Both fixtures drive the REAL runner as a child process against a REAL bound
# litmus test, so they measure the shipped code path rather than a copy of it.
#
# Pinned by litmus:litmus-podman-preflight-diagnosis-shape.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# The runner selects by SPEC, not by test name (a test-name filter fails loud
# by design — order 300). podman-orchestration's instant/pre-build bucket
# contains litmus:podman-path-availability, whose critical_path command line
# actually invokes podman and which is not `backend: fake` — i.e. one the
# preflight gates.
TARGET_SPEC="podman-orchestration"

FAILED=0
_fail() { echo "FAIL: $*"; FAILED=1; }
_ok() { echo "  ok: $*"; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tillandsias-preflight-diagnosis.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

mkdir -p "$SANDBOX/instant-fail" "$SANDBOX/slow"

cat > "$SANDBOX/instant-fail/podman" <<'EOF'
#!/usr/bin/env bash
echo "fixture: exec target vanished (this is the 127 class)" >&2
exit 127
EOF

cat > "$SANDBOX/slow/podman" <<'EOF'
#!/usr/bin/env bash
sleep 10
exit 0
EOF

chmod +x "$SANDBOX/instant-fail/podman" "$SANDBOX/slow/podman"

_run_runner() {
    # The fixture podman must win PATH lookup for BOTH `command -v podman` and
    # the probe itself. LITMUS_* are cleared so the run cannot slide into the
    # fake-backend branch and skip the preflight entirely.
    env -u LITMUS_PODMAN_MODE -u LITMUS_PODMAN_CALLS_FILE -u LITMUS_PODMAN_STATE_DIR \
        -u TILLANDSIAS_PODMAN_BIN -u TILLANDSIAS_PODMAN_REMOTE_URL -u CONTAINER_HOST \
        NO_COLOR=1 PATH="$1:$PATH" \
        bash scripts/run-litmus-test.sh "$TARGET_SPEC" \
            --phase pre-build --size instant --compact 2>&1
}

# ---------------------------------------------------------------------------
# Fixture A — instant non-zero exit.
# ---------------------------------------------------------------------------
a_start="$(date +%s)"
out_a="$(_run_runner "$SANDBOX/instant-fail")"
a_end="$(date +%s)"
a_elapsed=$(( a_end - a_start ))

if ! grep -Fq '[ENV-FAIL]' <<<"$out_a"; then
    _fail "fixture A did not reach the podman preflight at all — the fixture is not exercising the gate. Output: $out_a"
else
    if grep -Fq '>5s' <<<"$out_a"; then
        _fail "fixture A: a podman that exited instantly was described as '>5s'"
    else
        _ok "instant failure is not described as '>5s'"
    fi

    if grep -Fq 'environmental, not a code regression' <<<"$out_a"; then
        _fail "fixture A: the preflight still classifies an undiagnosed failure as environmental"
    else
        _ok "instant failure is not classified as environmental"
    fi

    # Report the status the probe ACTUALLY observed. Which number that is
    # depends on what sits between the runner and the fixture — the runner
    # prepends its own recording wrapper at target/litmus-runtime/bin, so the
    # immediate status is that wrapper's, with the fixture's 127 carried in the
    # quoted stderr. Pinning a specific number here would pin the harness's
    # layering, not the property. The property is: a number is reported, and it
    # is not timeout(1)'s 124.
    a_status="$(grep -oE 'FAILED IMMEDIATELY with exit [0-9]+' <<<"$out_a" | head -1)"
    if [ -z "$a_status" ]; then
        _fail "fixture A: no observed exit status in the message: $out_a"
    elif [ "$a_status" = "FAILED IMMEDIATELY with exit 124" ]; then
        _fail "fixture A: an instant failure was reported with timeout(1)'s 124"
    else
        _ok "the observed exit status is reported ('$a_status')"
    fi

    if grep -Fq 'fixture: exec target vanished' <<<"$out_a"; then
        _ok "podman's own stderr is quoted"
    else
        _fail "fixture A: podman's own stderr is not quoted: $out_a"
    fi

    # An instant failure must also be reported instantly. Five seconds of
    # elapsed time would mean the probe waited out its deadline anyway.
    if [ "$a_elapsed" -lt 5 ]; then
        _ok "fixture A returned in ${a_elapsed}s (no deadline was waited out)"
    else
        _fail "fixture A took ${a_elapsed}s — the probe is not failing fast"
    fi
fi

# ---------------------------------------------------------------------------
# Fixture B — the genuine timeout. This is the case the original message
# described, and it must keep describing it.
# ---------------------------------------------------------------------------
out_b="$(_run_runner "$SANDBOX/slow")"

if ! grep -Fq '[ENV-FAIL]' <<<"$out_b"; then
    _fail "fixture B did not reach the podman preflight at all. Output: $out_b"
else
    if grep -Fq 'within 5s' <<<"$out_b"; then
        _ok "a real stall is reported as a timeout"
    else
        _fail "fixture B: a podman that never answered was not reported as a timeout: $out_b"
    fi

    if grep -Fq 'exit 124' <<<"$out_b"; then
        _ok "the timeout is identified by timeout(1)'s own 124, not by inference"
    else
        _fail "fixture B: exit 124 is not reported: $out_b"
    fi

    if grep -Fq 'FAILED IMMEDIATELY' <<<"$out_b"; then
        _fail "fixture B: a genuine timeout was reported as an immediate failure"
    else
        _ok "a real stall is not reported as an immediate failure"
    fi
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "FAIL: the podman preflight cannot tell a timeout from a failed exec"
    exit 1
fi

echo "PASS: podman preflight distinguishes timeout from immediate failure (797-5kqe)"
