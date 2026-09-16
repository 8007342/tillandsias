#!/usr/bin/env bash
# @trace order:1219-dcma, order:975-rsgm, spec:enclave-network
#
# test-enclave-remedy-covers-the-named-service.sh — the way out a guard prints
# must work for the service it is complaining about.
#
# THE DEFECT, measured on lenovinha 2026-09-16 by FOLLOWING the instruction
# rather than reading it:
#     check-enclave-service-health.sh
#       fail:enclave-service-dead:service=tillandsias-inference:rc=137:restarts=0:age=3d1h
#       REMEDY: ... 'tillandsias --ensure-enclave' (idempotent), NOT 'podman start <service>'
#     tillandsias --ensure-enclave
#       ok:enclave-ensured:proxy=running          rc=0
#     check-enclave-service-health.sh
#       still degraded, dead=1, service still Exited(137)
# Confirmed in main.rs rather than inferred: --ensure-enclave ensures vault
# (feature-gated) and proxy, then prints ok:enclave-ensured:proxy=. Inference is
# never touched. The guard counts five services; the command covers two.
#
# So the operation SUCCEEDED and the subject was untouched — the shape this
# fleet keeps finding in detectors, here relocated to the REMEDY. Worse, the
# same block forecloses the alternative ("NOT podman start") on an argument that
# is sound for the PROXY (975-rsgm's CA-key precondition) and was applied to
# every class.
#
# THE ARMS THAT MATTER ARE 2 AND 3, the negative controls. The tempting
# over-correction is to blanket-disclaim --ensure-enclave, which would break the
# classes it IS correct for, or to re-legitimise `podman start` for the proxy,
# which 975-rsgm measured as producing a DIFFERENT failure naming neither the
# certificate nor the key.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3
GUARD="$ROOT/scripts/check-enclave-service-health.sh"
[ -f "$GUARD" ] || { echo "skip:enclave-remedy:$GUARD absent"; exit 3; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

echo "arm 1 — a service --ensure-enclave does NOT cover is named as uncovered"
# Asserted against the guard's source rather than a live run, so the fixture has
# a verdict on a host whose enclave is entirely healthy (where no detail lines
# exist to classify) as well as on one that is degraded.
if grep -q '1219-dcma' "$GUARD" \
   && grep -q 'NOT COVERED BY THAT REMEDY' "$GUARD" \
   && grep -q 'VAULT and PROXY only' "$GUARD"; then
    ok "the guard distinguishes covered from uncovered services"
else
    bad "the guard prints one remedy for every class again — an operator following it for inference gets rc=0 and no change"
fi

echo "arm 2 — CONTROL: the ORIGINAL remedy survives for the classes it does cover"
# --ensure-enclave is correct for vault and proxy. A fix that disclaims it
# wholesale would send an operator with a dead proxy nowhere.
if grep -q 'ensure-enclave' "$GUARD" && grep -q 'idempotent' "$GUARD"; then
    ok "the orchestration remedy is still prescribed"
else
    bad "the original remedy was removed; a dead proxy now has no stated way out"
fi

echo "arm 3 — CONTROL: 'podman start' stays foreclosed, with 975-rsgm's reason intact"
# The proxy's CA-key precondition is the reason, and it was MEASURED: a bare
# start produces squid X509_check_private_key() failed, naming neither file.
if grep -q "NOT 'podman start" "$GUARD" && grep -q 'X509_check_private_key' "$GUARD"; then
    ok "podman start is still refused and the measured reason is still given"
else
    bad "the podman-start foreclosure or its reason was lost — 975-rsgm's failure returns unexplained"
fi

echo "arm 4 — the uncovered list is DERIVED from the reported services, not hardcoded"
# A second hard-coded list drifts the moment a service is added. The names must
# come out of the detail lines the run just built.
if grep -q 'sed -n .s/.*:service=' "$GUARD"; then
    ok "the list is parsed from this run's own detail lines"
else
    bad "the uncovered set looks hardcoded; a service added later would be misclassified"
fi

echo "arm 5 — rc=137 is not left to read as an OOM without a check"
# The guard's own CAUSE text says 137=SIGKILL, which invites memory pressure as
# the first hypothesis. On lenovinha the kernel had NO out-of-memory record and
# the kill came from outside; a reader who assumes OOM searches the wrong place.
if grep -q 'journalctl -k' "$GUARD"; then
    ok "the guard tells the reader to check for an actual kernel OOM record"
else
    bad "rc=137 is presented without the check that distinguishes an OOM from an external kill"
fi

echo
echo "enclave remedy covers the named service: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo "violation:enclave-remedy:$fail"
    exit 1
fi
echo "ok:enclave-remedy:$pass"
exit 0
