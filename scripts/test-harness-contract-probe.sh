#!/usr/bin/env bash
# @trace spec:forge-hot-cold-split, spec:litmus-framework
#
# Fixture for the harness CONTRACT probe (order 439).
#
# Order 284 gave the forge a harness health probe with last-good rollback after
# a broken opencode-ai@latest took the whole lane down. That probe is
# `--version` — LIVENESS. It cannot see behavioural drift, and we have already
# been bitten by exactly that:
#
#   * order 429: the forge passed `--dangerously-skip-permissions` to opencode,
#     a flag it does not have. yargs is non-strict, so it was silently swallowed
#     for an unknown length of time.
#   * order 431 is blocked because a release renaming the UNDOCUMENTED
#     OPENCODE_AUTH_CONTENT would pass a liveness probe while credentials
#     silently revert to disk.
#
# Hermetic: stub harnesses in a temp prefix, so this never depends on a real
# opencode/codex being installed or on their current upstream flag set.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -r "$LIB" ] || fail "cannot read $LIB"

trace_lifecycle() { :; }
export -f trace_lifecycle 2>/dev/null || true

# Load only the contract functions — sourcing all of lib-common.sh would run
# forge-container setup that has no business executing on a build host.
eval "$(sed -n \
    '/^harness_contract_help_cmd()/,/^}/p;/^harness_contract_flags()/,/^}/p;/^harness_contract_ok()/,/^}/p' \
    "$LIB")"

command -v harness_contract_ok >/dev/null 2>&1 \
    || fail "could not load harness_contract_ok from lib-common.sh"

mkdir -p "$WORK/bin"
export NPM_CONFIG_PREFIX="$WORK"

# stub_harness <name> <help-subcommand-echo-body>
stub_harness() {
    local name="$1" body="$2"
    cat > "$WORK/bin/$name" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *--version*) echo "9.9.9"; exit 0 ;;
esac
$body
EOF
    chmod +x "$WORK/bin/$name"
}

# --- case 1: a harness honouring every flag we pass ------------------------
stub_harness opencode 'echo "  --auto     auto-approve permissions"; echo "  --format   default or json"'
harness_contract_ok opencode || fail "case1: a compliant harness must pass"
echo "case 1 ok: compliant harness passes"

# --- case 2: THE ORDER-429 REGRESSION — a flag we pass does not exist -------
# This is the load-bearing case. If it does not fail, the probe is decorative
# and the phantom-flag class stays invisible.
stub_harness opencode 'echo "  --auto     auto-approve permissions"'
CAPTURED=""
trace_lifecycle() { CAPTURED="$CAPTURED $*"; }
if harness_contract_ok opencode; then
    fail "case2: a harness missing a flag we pass MUST fail the contract"
fi
printf '%s' "$CAPTURED" | grep -q -- "--format" \
    || fail "case2: the failure must NAME the missing flag. Got: $CAPTURED"
trace_lifecycle() { :; }
echo "case 2 ok: missing flag is DETECTED and named"

# --- case 3: codex contract ------------------------------------------------
stub_harness codex 'echo "  --json"; echo "  -o, --output-last-message <FILE>"; echo "  --dangerously-bypass-approvals-and-sandbox"'
harness_contract_ok codex || fail "case3: compliant codex stub must pass"
stub_harness codex 'echo "  --json"'
harness_contract_ok codex && fail "case3: codex missing flags must fail the contract"
echo "case 3 ok: codex contract enforced"

# --- case 4: a harness with no declared contract is not penalised ----------
stub_harness openspec 'echo "  --whatever"'
harness_contract_ok openspec || fail "case4: an undeclared harness must pass"
echo "case 4 ok: undeclared harness passes"

# --- case 5: infrastructure noise must NOT cause a spurious rollback -------
# A contract check that failed closed on a timeout or empty help would trigger
# rollbacks for network reasons. Only a POSITIVE absence may fail.
stub_harness opencode 'exit 7'
harness_contract_ok opencode \
    || fail "case5: unusable help output must not be treated as a broken contract"
stub_harness opencode 'echo ""'
harness_contract_ok opencode \
    || fail "case5: empty help output must not be treated as a broken contract"
echo "case 5 ok: ambiguous help does not trigger a false rollback"

echo "PASS: harness contract probe fixture (order 439)"
