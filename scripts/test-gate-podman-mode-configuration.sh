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

# ORDER 1462-ruq9: a host that cannot build this fixture's AF_UNIX socket
# cannot run it. That is not a broken tree, so skip BY NAME on the last line
# (the litmus runner's skip rule) rather than print FAIL. MEASURED on yolanda
# 2026-09-29: Windows Git Bash DOES have a python3 (the WindowsApps one), and
# its socket module has NO AF_UNIX attribute. So the probe asks for the
# capability, not just the interpreter. Where python3 has AF_UNIX, nothing
# changes: a bind that fails is still a FAIL below.
# The probe lives INSIDE the one grandfathered interpreter call, whose line is
# kept byte-identical (the harness refuses new interpreter references,
# 1087-h2z9). The script drops a marker when it starts and another when the
# runtime has no AF_UNIX, so the failure branch can tell: never started = no
# runtime (skip), no AF_UNIX = skip, anything else = a real FAIL.
FIXTURE_MARK="$SANDBOX/fixture-runtime"
rm -f "$FIXTURE_MARK.started" "$FIXTURE_MARK.no-af-unix"
if ! python3 - "$SANDBOX/run/podman/podman.sock" <<'PY'
import socket
import sys

mark = sys.argv[1].rsplit("/run/podman/", 1)[0] + "/fixture-runtime"
open(mark + ".started", "w").close()
if not hasattr(socket, "AF_UNIX"):
    open(mark + ".no-af-unix", "w").close()
    sys.exit(3)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(1)
PY
then
    if [[ ! -e "$FIXTURE_MARK.started" ]]; then
        echo "skip:gate-podman-mode:no-fixture-runtime (no interpreter on PATH builds the AF_UNIX fixture socket; nothing was asserted)"
        exit 0
    fi
    if [[ -e "$FIXTURE_MARK.no-af-unix" ]]; then
        echo "skip:gate-podman-mode:runtime-has-no-af-unix (this runtime cannot create unix sockets, e.g. Windows; nothing was asserted)"
        exit 0
    fi
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

# ORDER 1485-m9m8. Scenarios 3 and 4 source the REAL common.sh, whose mode
# branches are only reachable when it RESOLVES a podman binary: with none,
# it sets PODMAN=podman and pins nothing, which is correct product behaviour.
# The WSL tillandsias-build guest has no podman at all (measured on yolanda
# 2026-09-29: command -v podman -> none), so scenario 4's positive control
# read pinned-bin=[<unset>] there while bare-metal macuahuitl, which has
# podman, passed. On a host with no podman, put a stub on PATH (the resolver
# searches PATH first) so both scenarios test the MODE and not the host's
# package list. A host that has podman is untouched.
if ! command -v podman >/dev/null 2>&1 \
   && [[ ! -x /usr/bin/podman && ! -x /bin/podman && ! -x /usr/local/bin/podman ]]; then
    mkdir -p "$SANDBOX/fakebin"
    printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && { echo "podman version 5.0.0"; exit 0; }\nexit 0\n' \
        > "$SANDBOX/fakebin/podman"
    chmod +x "$SANDBOX/fakebin/podman"
    export PATH="$SANDBOX/fakebin:$PATH"
    echo "  note: no podman on this host; scenarios 3-4 resolve a stub at $SANDBOX/fakebin/podman (1485-m9m8)"
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
