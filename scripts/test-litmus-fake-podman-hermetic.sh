#!/usr/bin/env bash
# @trace spec:litmus-framework
# =============================================================================
# test-litmus-fake-podman-hermetic.sh — safety fixtures for order 611-kqpf.
#
# Proves the four exit criteria of litmus-fake-podman-direct-invocation-safety:
#   1. the exact DISPLAYED fake-mode command is safe and deterministic in a
#      plain shell (no runner shim on PATH, no runner env);
#   2. a real-Podman SPY records ZERO invocations in fake mode;
#   3. an injected mid-fixture failure leaves no containers/storage tree and
#      no user-namespace-owned residue (every new tmp entry is removable by
#      plain rm as the invoking user);
#   4. runner-style and direct/documented entrypoints return the same verdict.
#
# The displayed command under test is the one litmus:image-build-convergence-
# shape advertises verbatim:
#   LITMUS_PODMAN_MODE=fake scripts/test-image-build-convergence.sh proxy
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

suite_tmp="$(mktemp -d "${TMPDIR:-/tmp}/fake-podman-hermetic.XXXXXX")"
# Expand at trap-set time: suite_tmp is script-global here, but keep the
# with-tillandsias-builder lesson anyway.
# shellcheck disable=SC2064
trap "rm -rf '$suite_tmp'" EXIT INT TERM HUP

# ── sanitized PATH: what a plain shell would have ──────────────────────────
# Strip every litmus shim dir (the runner's and any guard-installed one) so
# the scenarios below genuinely model a copy-paste into a fresh terminal.
sanitized_path=""
IFS=: read -ra _parts <<<"$PATH"
for _d in "${_parts[@]}"; do
    case "$_d" in
        */target/litmus-runtime/bin | */litmus-fake-podman-bin) continue ;;
    esac
    sanitized_path="${sanitized_path:+$sanitized_path:}$_d"
done

# ── the real-podman spy ─────────────────────────────────────────────────────
# Shadows every real podman on the sanitized PATH. If ANYTHING reaches it in
# fake mode, that is the incident recurring: it records and fails loudly.
spy_dir="$suite_tmp/spy-bin"
spy_log="$suite_tmp/spy-calls.log"
mkdir -p "$spy_dir"
: >"$spy_log"
cat >"$spy_dir/podman" <<SPY
#!/usr/bin/env bash
{ printf 'REAL-PODMAN-REACHED:'; for a in "\$@"; do printf ' %q' "\$a"; done; printf '\n'; } >>"$spy_log"
echo "SPY: real podman reached in fake mode" >&2
exit 1
SPY
chmod 755 "$spy_dir/podman"

run_displayed_command() {
    # $1 = extra env assignments (string, may be empty), evaluated in the
    # sanitized subshell. Runs the EXACT documented command.
    local extra="$1" out_file="$2"
    (
        cd "$ROOT" || exit 97
        export PATH="$spy_dir:$sanitized_path"
        unset LITMUS_PODMAN_MODE LITMUS_PODMAN_CALLS_FILE LITMUS_PODMAN_STATE_DIR \
              LITMUS_FAKE_PODMAN_BIN_DIR LITMUS_STDLIB TILLANDSIAS_PODMAN_BIN \
              LITMUS_FAKE_PODMAN_FAIL_ON 2>/dev/null
        [ -n "$extra" ] && export $extra
        LITMUS_PODMAN_MODE=fake scripts/test-image-build-convergence.sh proxy
    ) >"$out_file" 2>&1
}

# ── scenario 1: real-mode no-op ─────────────────────────────────────────────
before="$(command -v podman || true)"
# shellcheck source=test-support/litmus-fake-podman-guard.sh
source "$ROOT/scripts/test-support/litmus-fake-podman-guard.sh"
after="$(command -v podman || true)"
if [ "$before" = "$after" ]; then
    echo "ok:fake-podman-fixture:real-mode-guard-is-a-noop"
else
    echo "FAIL: guard changed podman resolution in real mode ($before -> $after)"; fail=1
fi

# ── scenario 2: displayed command hermetic in a plain shell, spy at zero ────
tmp_marker="$suite_tmp/marker"
touch "$tmp_marker"
if run_displayed_command "" "$suite_tmp/direct.log" \
   && grep -q 'ok: image build convergence sequence' "$suite_tmp/direct.log" \
   && [ ! -s "$spy_log" ]; then
    echo "ok:fake-podman-fixture:displayed-command-hermetic-and-spy-zero"
else
    echo "FAIL: direct displayed command not hermetic (rc/verdict/spy)"; tail -5 "$suite_tmp/direct.log"; [ -s "$spy_log" ] && cat "$spy_log"; fail=1
fi

# ── scenario 3: injected failure leaves no residue ──────────────────────────
: >"$spy_log"
if run_displayed_command "LITMUS_FAKE_PODMAN_FAIL_ON=build" "$suite_tmp/inject.log"; then
    echo "FAIL: injected build failure did not fail the fixture"; fail=1
else
    residue_bad=0
    while IFS= read -r entry; do
        [ -e "$entry" ] || continue
        case "$entry" in "$suite_tmp"*) continue ;; esac
        if rm -rf "$entry" 2>/dev/null; then
            echo "note: removed plain-rm-able leftover $entry"
        else
            echo "FAIL: residue not removable as invoking user: $entry"; residue_bad=1
        fi
    done < <(find "${TMPDIR:-/tmp}" -mindepth 1 -maxdepth 1 -newer "$tmp_marker" \( -name 'tmp.*' -o -name 'litmus-fake-podman*' -o -name 'containers*' -o -name 'podman*' \) 2>/dev/null)
    if [ "$residue_bad" -eq 0 ] && [ ! -s "$spy_log" ]; then
        echo "ok:fake-podman-fixture:injected-failure-no-residue-and-spy-zero"
    else
        fail=1
    fi
fi

# ── scenario 4: verdict parity, runner-style vs direct ─────────────────────
# Provision a runner-equivalent shim exactly the way run-litmus-test.sh's fake
# branch behaves (log + exec podman-mock.sh), on a path the guard recognizes
# as the runner's, and compare verdicts with the direct (guard-installed) run.
runner_bin="$suite_tmp/target/litmus-runtime/bin"
mkdir -p "$runner_bin"
cat >"$runner_bin/podman" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
calls_file="\${LITMUS_PODMAN_CALLS_FILE:-$suite_tmp/runner-calls.log}"
mkdir -p "\$(dirname "\$calls_file")"
{ printf '%s\tpodman' "\$(date -u +%FT%TZ)"; for a in "\$@"; do printf ' %q' "\$a"; done; printf '\n'; } >>"\$calls_file"
exec "$ROOT/scripts/test-support/podman-mock.sh" "\$@"
SHIM
chmod 755 "$runner_bin/podman"
: >"$spy_log"
(
    cd "$ROOT" || exit 97
    export PATH="$runner_bin:$spy_dir:$sanitized_path"
    unset LITMUS_PODMAN_CALLS_FILE LITMUS_PODMAN_STATE_DIR LITMUS_FAKE_PODMAN_BIN_DIR LITMUS_FAKE_PODMAN_FAIL_ON 2>/dev/null
    LITMUS_PODMAN_MODE=fake scripts/test-image-build-convergence.sh proxy
) >"$suite_tmp/runner-style.log" 2>&1
runner_rc=$?
grep -q 'ok: image build convergence sequence' "$suite_tmp/runner-style.log"; runner_verdict=$?
grep -q 'ok: image build convergence sequence' "$suite_tmp/direct.log"; direct_verdict=$?
if [ "$runner_rc" -eq 0 ] && [ "$runner_verdict" -eq 0 ] && [ "$direct_verdict" -eq 0 ] && [ ! -s "$spy_log" ]; then
    echo "ok:fake-podman-fixture:runner-and-direct-verdicts-agree"
else
    echo "FAIL: verdict parity (runner rc=$runner_rc verdict=$runner_verdict direct=$direct_verdict spy=$(wc -c <"$spy_log"))"; tail -5 "$suite_tmp/runner-style.log"; fail=1
fi

# ── 797-p2xa: the mock must fail CLOSED on anything it does not understand ──
# The negative control this packet asked for by name. The mock used to end in a
# bare `exit 0`, so an unrecognized invocation was answered with success and no
# output and every test built on it could pass while exercising nothing.
mock_out="$(scripts/test-support/podman-mock.sh definitely-not-a-subcommand --weird 2>&1)"; mock_rc=$?
if [ "$mock_rc" -eq 0 ]; then
    echo "FAIL: podman-mock accepted an absurd subcommand with exit 0 (fails OPEN)"; fail=1
elif ! grep -q 'definitely-not-a-subcommand' <<<"$mock_out"; then
    # A refusal that does not NAME the thing it refused sends the reader back
    # to the same search that made this class expensive.
    echo "FAIL: podman-mock refused (rc=$mock_rc) without naming the subcommand: $mock_out"; fail=1
else
    echo "ok:fake-podman-fixture:unrecognized-subcommand-refused-loudly"
fi

# CONTROL FOR THE CONTROL: a subcommand the mock DOES handle must still work,
# or the check above would pass on a mock that refuses everything.
if scripts/test-support/podman-mock.sh version >/dev/null 2>&1; then
    echo "ok:fake-podman-fixture:known-subcommand-still-handled"
else
    echo "FAIL: podman-mock refused a subcommand it implements (version)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "ok: all fake-podman-hermetic scenarios passed"
    exit 0
fi
echo "fail: fake-podman-hermetic scenarios failed"
exit 1
