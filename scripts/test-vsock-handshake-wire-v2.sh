#!/usr/bin/env bash
# @trace spec:vsock-transport
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# ORDER 1492-fswq. These preconditions used to be bare greps under `set -e`,
# the first of them for the LITERAL `pub const WIRE_VERSION: u16 = 2;`. The wire
# moved 2 -> 3 -> 4, that grep found nothing, and the litmus exited 1 with NO
# output on every host: indistinguishable from a green run that printed nothing.
# Now the version is READ from the named constant and checked as a FLOOR (v2 is
# the framing generation this test exercises; later versions are additive), and
# each precondition names itself when it fails.
fail() { echo "FAIL: $*" >&2; exit 1; }
wire_version="$(sed -n 's/^pub const WIRE_VERSION: u16 = \([0-9][0-9]*\);.*/\1/p' \
    crates/tillandsias-control-wire/src/lib.rs)"
[ -n "$wire_version" ] \
    || fail "could not read WIRE_VERSION from crates/tillandsias-control-wire/src/lib.rs"
[ "$wire_version" -ge 2 ] \
    || fail "WIRE_VERSION is $wire_version; this handshake test needs wire v2 framing or later"
grep -Fq 'vsock-transport.invariant.wire-version-2' openspec/specs/vsock-transport/spec.md \
    || fail "spec invariant vsock-transport.invariant.wire-version-2 is missing"
[ -f crates/tillandsias-headless/tests/vsock_listener_e2e.rs ] \
    || fail "crates/tillandsias-headless/tests/vsock_listener_e2e.rs is missing"
echo "ok: preconditions (WIRE_VERSION=$wire_version, >= 2)"
if grep -Fq 'vsock-handshake-probe' \
    openspec/litmus-tests/litmus-vsock-handshake.yaml; then
    echo "FAIL: handshake descriptor invokes removed probe example" >&2
    exit 1
fi

cargo test -q -p tillandsias-control-wire hello_
cargo test -q -p tillandsias-host-shell handshake_succeeds_against_fake_unix_server

if [[ "$(uname -s)" != Linux ]]; then
    echo "SKIP: wire-v2 vsock runtime requires a Linux loopback-capable host"
    exit 0
fi

set +e
output="$(cargo test -p tillandsias-headless --features listen-vsock \
    --test vsock_listener_e2e -- --ignored --nocapture 2>&1)"
status=$?
set -e
printf '%s\n' "$output"
if [[ $status -ne 0 ]]; then
    echo "FAIL: maintained wire-v2 vsock handshake fixture failed" >&2
    exit "$status"
fi

if grep -Fq '[skip] vsock loopback not available' <<<"$output"; then
    echo "SKIP: wire-v2 vsock loopback is unsupported for this unprivileged host"
    exit 0
fi

grep -Eq 'test result: ok\. 1 passed' <<<"$output" || {
    echo "FAIL: vsock fixture did not execute exactly one handshake test" >&2
    exit 1
}
echo "PASS: wire-v2 vsock Hello/HelloAck handshake completed"
