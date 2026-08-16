#!/usr/bin/env bash
# @trace spec:litmus-framework
# =============================================================================
# litmus-fake-podman-guard.sh — hermetic fake-Podman for DIRECT fixture runs
# (order 611-kqpf). Source this AFTER exporting LITMUS_PODMAN_MODE.
#
# Contract: under LITMUS_PODMAN_MODE=fake, the `podman` a fixture resolves on
# PATH must be a litmus shim that can never reach the real binary. The runner
# (scripts/run-litmus-test.sh) installs one; a documented fixture command
# copied into a PLAIN shell had none, so `podman` silently resolved to the
# host's real rootless podman — the 2026-08-06 incident: zero fake build calls
# recorded, plus a user-namespace-owned overlay tree under /tmp that ordinary
# `rm` could not delete (it took `podman unshare`).
#
# Sourcing this guard makes the documented command self-contained:
#   - real mode (LITMUS_PODMAN_MODE unset or != fake): strict no-op;
#   - fake mode with a recognized shim already on PATH (the runner's
#     target/litmus-runtime/bin or a previously-installed guard shim):
#     no-op — the runner's contract wins;
#   - fake mode WITHOUT a shim: install a fixture-owned one that logs the
#     call to LITMUS_PODMAN_CALLS_FILE and execs the canonical mock
#     (scripts/test-support/podman-mock.sh). The shim never falls through to
#     the real binary, so fake mode cannot create containers, images, volumes
#     or a real containers/storage tree, by construction.
#
# Placement: set LITMUS_FAKE_PODMAN_BIN_DIR to a directory inside the
# fixture's own tmp (cleaned by its trap) — the plain-shell fallback is a
# mktemp dir whose residue is two tiny text files, plain-rm removable, never
# userns-owned.
#
# Failure-injection seam (for the safety fixture ONLY):
# LITMUS_FAKE_PODMAN_FAIL_ON=<subcommand> makes the shim exit 1 on that
# subcommand after logging, proving an injected mid-fixture failure leaves no
# residue behind.
# =============================================================================

if [[ "${LITMUS_PODMAN_MODE:-real}" == "fake" ]]; then
    _lfpg_current="$(command -v podman 2>/dev/null || true)"
    case "$_lfpg_current" in
        */target/litmus-runtime/bin/podman | */litmus-fake-podman-bin/podman)
            : # a recognized shim already owns `podman`; nothing to do
            ;;
        *)
            _lfpg_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
            _lfpg_bin="${LITMUS_FAKE_PODMAN_BIN_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/litmus-fake-podman.XXXXXX")/bin}"
            # The directory NAME is the recognition token for re-sourcing.
            _lfpg_bin="${_lfpg_bin%/}/litmus-fake-podman-bin"
            mkdir -p "$_lfpg_bin"
            cat >"$_lfpg_bin/podman" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
calls_file="\${LITMUS_PODMAN_CALLS_FILE:-$_lfpg_bin/calls.log}"
mkdir -p "\$(dirname "\$calls_file")"
{
    printf '%s\tpodman' "\$(date -u +%FT%TZ)"
    for _a in "\$@"; do printf ' %q' "\$_a"; done
    printf '\n'
} >>"\$calls_file"
if [[ -n "\${LITMUS_FAKE_PODMAN_FAIL_ON:-}" && "\${1:-}" == "\$LITMUS_FAKE_PODMAN_FAIL_ON" ]]; then
    echo "litmus-fake-podman-guard: injected failure on '\${1:-}'" >&2
    exit 1
fi
exec "$_lfpg_root/scripts/test-support/podman-mock.sh" "\$@"
SHIM
            chmod 755 "$_lfpg_bin/podman"
            export PATH="$_lfpg_bin:$PATH"
            unset _lfpg_bin _lfpg_root
            ;;
    esac
    unset _lfpg_current
fi
