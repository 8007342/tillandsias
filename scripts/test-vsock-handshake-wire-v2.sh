#!/usr/bin/env bash
# @trace spec:vsock-transport
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

grep -Fq 'pub const WIRE_VERSION: u16 = 2;' \
    crates/tillandsias-control-wire/src/lib.rs
grep -Fq 'vsock-transport.invariant.wire-version-2' \
    openspec/specs/vsock-transport/spec.md
test -f crates/tillandsias-headless/tests/vsock_listener_e2e.rs
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
