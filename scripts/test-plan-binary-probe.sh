#!/usr/bin/env bash
# @trace spec:ci-release
#
# test-plan-binary-probe.sh — hermetic fixtures for resolve_plan_binary
# (order 783-jdeh).
#
# THE CASE THAT COST A FORGE CYCLE. Every forge exports
# CARGO_TARGET_DIR="$PROJECT_CACHE/cargo/target"
# (images/default/lib-common.sh), so the mounted checkout has NO ./target at
# all. cycle-preflight.sh runs `cargo build --release -p tillandsias-plan`,
# succeeds, then asks resolve_plan_binary for the artifact — and the probe,
# which looked only under ./target and PATH, could not see the binary that had
# just been built. It reported `blocked:preflight:plan:capabilities-refused`,
# blaming the instrument for a path assumption, and the in-forge cycle did zero
# work (observed on yoga 2026-08-17).
#
# The fixtures below run WITHOUT cargo, podman, or a network: a stub script
# standing in for the binary is enough, because what is under test is path
# resolution, not the binary's behaviour.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/plan-binary-probe.sh"
fail=0

_stub() {
    # A stand-in that answers `capabilities` the way the real binary does —
    # that is the probe's contract (exit 0 on a binary carrying order 569).
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "capabilities" ] && { echo "answer"; exit 0; }
exit 1
STUB
    chmod +x "$1"
}

_probe_in() {
    # Run the probe with CWD at $1 and the given CARGO_TARGET_DIR ($2, may be
    # empty), printing the resolved path or nothing.
    # A minimal PATH, not an empty one: the stub's shebang is
    # `#!/usr/bin/env bash`, so nuking PATH breaks the FIXTURE rather than
    # isolating the probe (it made cases 1/3/4 fail on a correct probe). What
    # isolation actually requires is only that `tillandsias-plan` not be
    # reachable via PATH, which /usr/bin:/bin satisfies.
    ( cd "$1" && CARGO_TARGET_DIR="${2:-}" PATH="/usr/bin:/bin" bash -c \
        ". '$PROBE'; resolve_plan_binary" 2>/dev/null )
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── CASE 1: the forge layout — no ./target, binary under CARGO_TARGET_DIR ────
mkdir -p "$tmp/forge/checkout"
_stub "$tmp/forge/cache/target/release/tillandsias-plan"
got="$(_probe_in "$tmp/forge/checkout" "$tmp/forge/cache/target")"
if [ -z "$got" ]; then
    echo "FAIL case1: probe could not see the binary under CARGO_TARGET_DIR (the 783-jdeh bug)"
    fail=1
else
    echo "ok case1: resolved under CARGO_TARGET_DIR"
fi

# ── CASE 2: NEGATIVE CONTROL — same tree, CARGO_TARGET_DIR unset ─────────────
# Proves case 1 passes BECAUSE of the env var, not because the fixture leaks a
# binary onto some other search path. Without this, case 1 could pass while the
# probe ignored CARGO_TARGET_DIR entirely.
got="$(_probe_in "$tmp/forge/checkout" "")"
if [ -n "$got" ]; then
    echo "FAIL case2: resolved '$got' with CARGO_TARGET_DIR unset — case 1 proves nothing"
    fail=1
else
    echo "ok case2: refuses without CARGO_TARGET_DIR (control holds)"
fi

# ── CASE 3: the ordinary host layout still works ────────────────────────────
mkdir -p "$tmp/host"
_stub "$tmp/host/target/release/tillandsias-plan"
got="$(_probe_in "$tmp/host" "")"
if [ -z "$got" ]; then
    echo "FAIL case3: ./target/release regressed"
    fail=1
else
    echo "ok case3: ./target/release still resolves"
fi

# ── CASE 4: a RELATIVE CARGO_TARGET_DIR resolves against the checkout ────────
# cargo itself treats a relative CARGO_TARGET_DIR as relative to the working
# directory; resolve_target_binary in the same file already does this, so the
# plan probe must not disagree with its sibling.
mkdir -p "$tmp/rel"
_stub "$tmp/rel/build/release/tillandsias-plan"
got="$(_probe_in "$tmp/rel" "build")"
if [ -z "$got" ]; then
    echo "FAIL case4: relative CARGO_TARGET_DIR not honoured"
    fail=1
else
    echo "ok case4: relative CARGO_TARGET_DIR honoured"
fi

# ── CASE 5: a binary that does NOT answer capabilities is refused ────────────
# The probe's contract is "runs AND carries order 569", not "exists". A stale
# binary must refuse here so callers can say `stale-plan-binary` rather than
# `no-plan-binary` (704-zcgi).
mkdir -p "$tmp/stale/target/release"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/stale/target/release/tillandsias-plan"
chmod +x "$tmp/stale/target/release/tillandsias-plan"
got="$(_probe_in "$tmp/stale" "")"
if [ -n "$got" ]; then
    echo "FAIL case5: accepted a binary that refuses 'capabilities'"
    fail=1
else
    echo "ok case5: a binary failing 'capabilities' is refused"
fi

# ── CASE 6: resolve_target_binary prefers the LOCUS-NATIVE artefact ──────────
# ORDER 1142-wn2k. On a shared Windows/WSL checkout both artefacts sit in one target
# dir, and with interop enabled BOTH run inside the distro — so candidate ORDER,
# not runnability, decides which is returned. This pins the ELF winning when
# both answer.
#
# REGIME: hermetic. Both stubs are scripts that exit 0, so both "run" on this
# host; the arm is about ordering and asserts nothing about real binaries or
# about this host's locus. No absolute moment is encoded.
#
# THE .exe STUB MUST BE RUNNABLE, and that is the whole arm. If it were made
# unrunnable the ELF would win by default and the test would pass against the
# PRE-FIX order too — a green that asserts nothing (1041-up99). The pre-fix
# order returns the .exe here, which is what esme measured in production.
mkdir -p "$tmp/locus/target/debug"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/locus/target/debug/tillandsias-policy"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/locus/target/debug/tillandsias-policy.exe"
chmod +x "$tmp/locus/target/debug/tillandsias-policy" "$tmp/locus/target/debug/tillandsias-policy.exe"
got="$( CARGO_TARGET_DIR="" PATH="/usr/bin:/bin" bash -c \
    ". '$PROBE'; resolve_target_binary tillandsias-policy debug '$tmp/locus'" 2>/dev/null || true )"
case "$got" in
    *"/tillandsias-policy")
        echo "ok case6: the ELF wins over a runnable .exe in the same dir (1142-wn2k)" ;;
    *"/tillandsias-policy.exe")
        echo "FAIL case6: the .exe was returned over a runnable ELF — the pre-fix order (1142-wn2k)"
        fail=1 ;;
    *)
        echo "FAIL case6: neither candidate resolved (got '$got')"
        fail=1 ;;
esac

if [ "$fail" -ne 0 ]; then
    echo "FAIL: plan-binary-probe fixture"
    exit 1
fi
echo "PASS: plan-binary-probe fixture (orders 783-jdeh, 1142-wn2k) 6/6"
