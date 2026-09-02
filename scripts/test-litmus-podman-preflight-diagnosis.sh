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
        bash scripts/run-litmus-test.sh "${2:-$TARGET_SPEC}" \
            --phase pre-build --size instant --compact 2>&1
}

# ---------------------------------------------------------------------------
# Fixture A — instant non-zero exit.
# ---------------------------------------------------------------------------
out_a="$(_run_runner "$SANDBOX/instant-fail")"

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

    # DELIBERATELY NOT ASSERTED HERE: a wall-clock bound on "the probe failed
    # fast". A first draft timed this whole child invocation and refused it
    # above five seconds. That is not the probe's duration — the child runs the
    # spec's entire instant bucket, five tests, of which exactly one reaches the
    # preflight. It went red at 10s on a host whose load average had gone to 12
    # under an unrelated llama-server, while the preflight itself was answering
    # correctly. An assertion that reports how busy the machine was, wearing the
    # name of a property, is the same defect this packet exists to remove
    # (793-a62g chose a storage backend with a stopwatch; the message this
    # fixture pins invented a five-second stall it never measured). The
    # falsifiable property is the WORDING, and the four checks above plus
    # fixture B's mirror below carry all of it: a probe that had waited out its
    # deadline would report 124 and say "within 5s", and it says neither.
    if grep -Fq 'within 5s' <<<"$out_a"; then
        _fail "fixture A: an instant failure was reported with the timeout wording"
    else
        _ok "instant failure is not reported with the timeout wording"
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


# ---------------------------------------------------------------------------
# Fixture C — THE SCOPE CONTROL (order 618-i4s6).
#
# Fixtures A and B both pin how the preflight DESCRIBES a broken podman. Neither
# says anything about WHEN it should fire at all, so both stay green if the
# trigger is re-broadened to every litmus — which is exactly the 2026-07-15
# regression: an un-gated preflight blanket-ENV-FAILed 35 source-shape checks
# (darwin instant suite 96% -> 72%), and on Windows a podman shim that
# exists-but-fails turned every grep-shape litmus into a false ENV-FAIL.
#
# The trigger was then narrowed twice, by two lanes fixing one half each: macOS
# added the Linux-only platform gate, Windows tightened a whole-file `podman`
# grep down to command lines that actually INVOKE it. Nothing pinned either
# narrowing, so a future edit can undo both and the suite stays green while
# every source-shape check on the fleet turns red for an environment they never
# touch.
#
# THE CONTROL MUST MENTION PODMAN WITHOUT INVOKING IT. That is the whole
# discrimination. A spec whose files never say "podman" at all stays green even
# under a whole-file grep, so it proves nothing — measured while writing this:
# methodology-accountability was the first choice, the re-broadening mutation
# was applied and VERIFIED to land, and the arm still passed. It was green for
# the wrong reason.
#
# AND THE RUNNER MUST ACTUALLY SELECT IT. cross-platform-compilation was the
# second choice and also failed, differently and more quietly: the runner
# selects by bound spec_id, that name is bound under another spec, and the run
# printed "no litmus tests matched filter" — so the arm was asserting the
# absence of ENV-FAIL over an EMPTY selection. A green from nothing.
#
# enclave-network is selectable, has 3 litmuses in the instant pre-build
# bucket, one of which mentions podman, and invokes it on zero command lines.
# ---------------------------------------------------------------------------
UNGATED_SPEC="enclave-network"

# Guard the fixture's own premise. If that spec ever gains a podman-invoking
# litmus, this arm would start asserting the opposite of what it means and would
# read as a regression in the runner rather than drift in the corpus.
_ungated_podman_carriers=0
_ungated_mentions=0
for _f in openspec/litmus-tests/*.yaml; do
    [ "$(grep -m1 '^spec:' "$_f" | sed 's/spec: *//')" = "$UNGATED_SPEC" ] || continue
    [ "$(grep -m1 '^phase:' "$_f" | sed 's/phase: *//')" = "pre-build" ] || continue
    [ "$(grep -m1 '^size:' "$_f" | sed 's/size: *//')" = "instant" ] || continue
    grep -qE '^[[:space:]]*command:.*(^|[ ;|&(])podman[[:space:]]' "$_f" \
        && _ungated_podman_carriers=$((_ungated_podman_carriers + 1))
    grep -q 'podman' "$_f" && _ungated_mentions=$((_ungated_mentions + 1))
done

if [ "$_ungated_mentions" -eq 0 ]; then
    _fail "fixture C is toothless: $UNGATED_SPEC no longer MENTIONS podman anywhere in its instant pre-build bucket, so a re-broadened whole-file trigger would not fire on it either and this arm would pass for the wrong reason. Pick a spec that mentions podman without invoking it."
elif [ "$_ungated_podman_carriers" -ne 0 ]; then
    _fail "fixture C's premise has drifted: $UNGATED_SPEC now has $_ungated_podman_carriers podman-invoking litmus(es) in the instant pre-build bucket, so it can no longer serve as the ungated control. Pick another podman-free spec rather than deleting this arm."
else
    out_c="$(_run_runner "$SANDBOX/instant-fail" "$UNGATED_SPEC")"
    if grep -Fq 'no litmus tests matched' <<<"$out_c"; then
        _fail "fixture C selected NOTHING ($UNGATED_SPEC is not a selectable bound spec_id), so its green would assert the absence of ENV-FAIL over an empty run. Output: $out_c"
    elif grep -Fq '[ENV-FAIL]' <<<"$out_c"; then
        _fail "fixture C: a spec whose commands never invoke podman was ENV-FAILed by a broken podman on PATH — the preflight trigger has been re-broadened (this is the 2026-07-15 regression: 35 source-shape checks blanket-failed). Output: $out_c"
    else
        _ok "a litmus that never invokes podman is NOT gated on podman being healthy"
    fi

    # POSITIVE HALF of the same control: prove the fixture podman really was
    # broken and first on PATH for this run. Without it, arm C also passes when
    # the stub was never reachable, which would make it decoration.
    if PATH="$SANDBOX/instant-fail:$PATH" podman ps >/dev/null 2>&1; then
        _fail "fixture C: the stub podman answered successfully, so the arm above proves nothing about scoping"
    else
        _ok "the stub podman really is broken and first on PATH (so C's green is scoping, not luck)"
    fi
fi
if [[ "$FAILED" -ne 0 ]]; then
    echo "FAIL: the podman preflight cannot tell a timeout from a failed exec"
    exit 1
fi

echo "PASS: podman preflight distinguishes timeout from immediate failure (797-5kqe)"
