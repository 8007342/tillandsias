#!/usr/bin/env bash
# @trace spec:meta-orchestration
# Regression pin for order 442: the destructive e2e gate's eligibility probe
# must REFUSE (skip:live-runtime-present) when a live Tillandsias forge /
# shared stack is running that this smoke run did not launch. Otherwise the
# gate's first step (`podman system reset --force`) would wipe a live operator
# or agent forge and any in-flight cycles inside it.
#
# Runs OFFLINE by injecting a fake `podman` onto PATH so no real containers or
# Podman binary are required.
#
# Run: scripts/test-e2e-preflight-live-runtime.sh   (exit 0 = pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="$ROOT/scripts/e2e-preflight.sh"
FAKE_BIN="$(mktemp -d)"
# Writable runtime dir so the smoke-lock probe (which writes under
# XDG_RUNTIME_DIR) does not trip on the immutable forge host's /run/user.
export XDG_RUNTIME_DIR="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN" "$XDG_RUNTIME_DIR"' EXIT

# Fake `podman` that prints a container list based on $FAKE_PODMAN_PS.
make_fake_podman() {
    cat >"$FAKE_BIN/podman" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "ps" ]; then
  printf '%s\n' "${FAKE_PODMAN_PS:-}"
  exit 0
fi
# Anything else (e.g. `podman info`) succeeds.
exit 0
EOF
    chmod +x "$FAKE_BIN/podman"
}

# --- Case 1: a live forge is running -> must refuse -------------------------
export FAKE_PODMAN_PS=$'tillandsias-tillandsias-forge\ncontainer-other'
make_fake_podman
verdict="$(PATH="$FAKE_BIN:$PATH" bash "$PREFLIGHT" eligibility)"
if [ "$verdict" != "skip:live-runtime-present" ]; then
    echo "FAIL: live forge present but verdict was '$verdict' (expected skip:live-runtime-present)" >&2
    exit 1
fi

# --- Case 2: a shared-stack service running -> must refuse -----------------
export FAKE_PODMAN_PS=$'tillandsias-git-mirror\ntillandsias-vault'
make_fake_podman
verdict="$(PATH="$FAKE_BIN:$PATH" bash "$PREFLIGHT" eligibility)"
if [ "$verdict" != "skip:live-runtime-present" ]; then
    echo "FAIL: shared stack present but verdict was '$verdict'" >&2
    exit 1
fi

# --- Case 3: no tillandsias containers -> eligible --------------------------
export FAKE_PODMAN_PS=$'some-other-container\nnginx'
make_fake_podman
verdict="$(PATH="$FAKE_BIN:$PATH" bash "$PREFLIGHT" eligibility)"
if [ "$verdict" != "eligible" ]; then
    echo "FAIL: no tillandsias runtime but verdict was '$verdict' (expected eligible)" >&2
    exit 1
fi

# --- Case 4: empty podman output -> eligible -------------------------------
export FAKE_PODMAN_PS=""
make_fake_podman
verdict="$(PATH="$FAKE_BIN:$PATH" bash "$PREFLIGHT" eligibility)"
if [ "$verdict" != "eligible" ]; then
    echo "FAIL: empty podman output but verdict was '$verdict' (expected eligible)" >&2
    exit 1
fi

# --- Case 5: operator override TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 forces
#            eligible even with a live forge present ------------------------
export FAKE_PODMAN_PS=$'tillandsias-tillandsias-forge'
make_fake_podman
verdict="$(PATH="$FAKE_BIN:$PATH" TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 bash "$PREFLIGHT" eligibility)"
if [ "$verdict" != "eligible" ]; then
    echo "FAIL: override set but verdict was '$verdict' (expected eligible)" >&2
    exit 1
fi

echo "PASS: e2e-preflight refuses live runtime, allows clean host (order 442)"
exit 0
