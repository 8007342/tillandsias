#!/usr/bin/env bash
# @trace spec:podman-orchestration, spec:dev-build, plan 797-r6tc
#
# test-gate-podman-mode-configuration.sh — prove the gate does not GUESS which
# podman it is testing.
#
# WHY THIS EXISTS. build.sh used to export TILLANDSIAS_PODMAN_REMOTE_URL
# whenever ${XDG_RUNTIME_DIR}/podman/podman.sock existed. A socket file
# existing is the ordinary state of any host with podman.socket enabled, so the
# inference fired unconditionally, and only inside the gate. Sourcing
# scripts/common.sh with that variable set takes its remote branch, which pins
# an exported TILLANDSIAS_PODMAN_BIN at a generated wrapper; that pin beats
# PATH in resolve_podman_bin() and it is inherited by every litmus child, so
# `backend: fake` tests that inject their podman by PATH silently ran against
# real podman. Measured on macuahuitl 2026-08-17 at one commit: 302/302 from a
# bare litmus run, 295/302 through ./build.sh --ci-full.
#
# THE PROPERTY, not the literal: with a REAL AF_UNIX socket sitting exactly
# where the old inference looked for it, build.sh must still hand common.sh an
# UNSET remote URL — and must still pass through a URL the caller set itself.
# Scenario 1 is the discriminating one: restore the inference and it goes red.
# A grep for absent source text could not do that job, because the explanation
# of what was removed necessarily names what was removed.
#
# Pinned by litmus:gate-podman-mode-is-configuration-not-inference.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FAILED=0
_fail() { echo "FAIL: $*"; FAILED=1; }
_ok() { echo "  ok: $*"; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tillandsias-gate-podman-mode.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixture: a build.sh sandbox whose XDG_RUNTIME_DIR holds a genuine listening
# unix socket at podman/podman.sock, and whose scripts/common.sh is a stub that
# reports what build.sh handed it and then stops the script.
# ---------------------------------------------------------------------------
mkdir -p "$SANDBOX/scripts" "$SANDBOX/run/podman"
cp "$ROOT/build.sh" "$SANDBOX/build.sh"
: > "$SANDBOX/scripts/with-tillandsias-builder.sh"
: > "$SANDBOX/scripts/with-wsl2-builder.sh"
# 3d56d69b6 added a third sourced wrapper to build.sh; stub it like its siblings.
: > "$SANDBOX/scripts/with-nix-builder.sh"
cat > "$SANDBOX/scripts/common.sh" <<'STUB'
echo "handed-remote-url=[${TILLANDSIAS_PODMAN_REMOTE_URL:-<unset>}]"
echo "handed-container-host=[${CONTAINER_HOST:-<unset>}]"
exit 0
STUB

if ! python3 - "$SANDBOX/run/podman/podman.sock" <<'PY'
import socket
import sys

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(1)
PY
then
    echo "FAIL: could not create the AF_UNIX fixture socket (python3 required)"
    exit 1
fi

if [[ ! -S "$SANDBOX/run/podman/podman.sock" ]]; then
    # Without a real socket the fixture cannot discriminate: the old inference
    # tested -S, so a missing socket would make scenario 1 pass for the wrong
    # reason. Refuse rather than report a green that proves nothing.
    echo "FAIL: fixture socket is not a socket — the scenario would be vacuous"
    exit 1
fi

# ---------------------------------------------------------------------------
# Scenario 1 — THE REGRESSION. Socket present, caller silent: the gate must
# still be in local-podman mode.
# ---------------------------------------------------------------------------
out1="$(
    env -u TILLANDSIAS_PODMAN_REMOTE_URL -u CONTAINER_HOST \
        XDG_RUNTIME_DIR="$SANDBOX/run" \
        bash "$SANDBOX/build.sh" --check 2>&1
)"
if grep -Fq 'handed-remote-url=[<unset>]' <<<"$out1"; then
    _ok "socket present + caller silent => no inferred remote mode"
else
    _fail "build.sh inferred remote podman mode from a socket file: $out1"
fi

# ---------------------------------------------------------------------------
# Scenario 2 — CONFIGURATION IS STILL HONOURED. The one real consumer of remote
# mode (packaging/systemd/user/tillandsias.service, ExecStart=tillandsias
# --headless) sets the variable itself; a caller that does so must reach
# common.sh with its own value intact, not a rewritten one.
# ---------------------------------------------------------------------------
out2="$(
    env -u CONTAINER_HOST \
        TILLANDSIAS_PODMAN_REMOTE_URL="unix:///caller/chosen/podman.sock" \
        XDG_RUNTIME_DIR="$SANDBOX/run" \
        bash "$SANDBOX/build.sh" --check 2>&1
)"
if grep -Fq 'handed-remote-url=[unix:///caller/chosen/podman.sock]' <<<"$out2"; then
    _ok "explicit remote URL survives build.sh unmodified"
else
    _fail "build.sh did not pass the caller's remote URL through: $out2"
fi

# ---------------------------------------------------------------------------
# Scenario 3 — THE CONSEQUENCE THAT ACTUALLY BROKE THE GATE. Against the REAL
# scripts/common.sh: local mode must leave TILLANDSIAS_PODMAN_BIN unset, which
# is what lets a `backend: fake` litmus inject its podman by PATH.
# ---------------------------------------------------------------------------
out3="$(
    env -u TILLANDSIAS_PODMAN_REMOTE_URL -u CONTAINER_HOST \
        -u TILLANDSIAS_PODMAN_GRAPHROOT -u TILLANDSIAS_PODMAN_RUNROOT \
        -u TILLANDSIAS_PODMAN_STORAGE_CONF -u LITMUS_PODMAN_CALLS_FILE \
        -u TILLANDSIAS_PODMAN_BIN \
        bash -c 'source "'"$ROOT"'/scripts/common.sh"; echo "pinned-bin=[${TILLANDSIAS_PODMAN_BIN:-<unset>}]"' 2>&1
)"
if grep -Fq 'pinned-bin=[<unset>]' <<<"$out3"; then
    _ok "local mode leaves TILLANDSIAS_PODMAN_BIN unset (PATH injection works)"
else
    _fail "local mode pinned a podman binary, which overrides fake-podman PATH injection: $out3"
fi

# ---------------------------------------------------------------------------
# Scenario 4 — POSITIVE CONTROL for scenario 3. An explicit remote URL must
# still produce the pinned wrapper; scenario 3 must be proving a mode, not
# proving the pin was deleted everywhere.
# ---------------------------------------------------------------------------
wrapper_dir="$SANDBOX/wrapper"
out4="$(
    env -u CONTAINER_HOST -u LITMUS_PODMAN_CALLS_FILE -u TILLANDSIAS_PODMAN_BIN \
        TILLANDSIAS_PODMAN_REMOTE_URL="unix://$SANDBOX/run/podman/podman.sock" \
        TILLANDSIAS_PODMAN_WRAPPER_DIR="$wrapper_dir" \
        bash -c 'source "'"$ROOT"'/scripts/common.sh"; echo "pinned-bin=[${TILLANDSIAS_PODMAN_BIN:-<unset>}]"' 2>&1
)"
if grep -Fq "pinned-bin=[$wrapper_dir/podman]" <<<"$out4"; then
    _ok "explicit remote mode still pins the generated wrapper"
else
    _fail "explicit remote mode no longer reaches the wrapper branch: $out4"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "FAIL: gate podman mode is not configuration-only"
    exit 1
fi

echo "PASS: gate podman mode is configuration, not inference (797-r6tc)"
