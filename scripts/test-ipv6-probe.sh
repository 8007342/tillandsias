#!/usr/bin/env bash
# @trace order:1548-mhyk, spec:init-command
#
# test-ipv6-probe.sh — prove the --init IPv6 probe (a) parses its address list
# and (b) probes EVERY default router, declaring IPv6 functional only when all
# carry traffic. Hermetic: the probe core takes an injected route table and an
# injected per-router probe; nothing here touches containers.conf or the network.
#
# Arms (each is a named cargo unit test in tillandsias-headless):
#   parse     ipv6_probe_addresses_parse
#   one-blackhole  ipv6_egress_one_blackholing_router_is_not_functional  (egress=1/2, NOT functional)
#   both-ok   ipv6_egress_all_routers_working_is_functional              (2/2, functional)
#   no-router ipv6_egress_no_default_router_is_not_functional
#
# Pinned by litmus:ipv6-probe-per-router-shape.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

CARGO=(cargo)
command -v cargo >/dev/null 2>&1 || CARGO=(toolbox run cargo)

pass=0; fail=0
arm() {
    local label="$1" filter="$2" out rc
    out="$("${CARGO[@]}" test -p tillandsias-headless --bin tillandsias "$filter" -- --exact 2>&1)"
    rc=$?
    # An arm that ran zero tests is a false green: demand "1 passed".
    if [ "$rc" = 0 ] && printf '%s' "$out" | /usr/bin/grep -q 'test result: ok. 1 passed'; then
        pass=$((pass+1)); echo "  PASS  $label"
    else
        fail=$((fail+1)); echo "  FAIL  $label (rc=$rc)"; printf '%s\n' "$out" | tail -15
    fi
}

arm parse        tests::ipv6_probe_addresses_parse
arm one-blackhole tests::ipv6_egress_one_blackholing_router_is_not_functional
arm both-ok      tests::ipv6_egress_all_routers_working_is_functional
arm no-router    tests::ipv6_egress_no_default_router_is_not_functional

echo "ipv6-probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
