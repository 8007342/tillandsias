#!/usr/bin/env bash
# @trace spec:runtime-diagnostics-stream, spec:logging-accountability
# @trace order:525
#
# Fixture for the inference engine's pull-failure classifier.
#
# THE DEFECT (order 525, exit criterion 3). A failed pull and an empty cache
# both reached the agent as `inference_reason=no-models`, whose detail named
# three causes at once. The one that mattered — the enclave CA not trusted by
# ollama's Go TLS stack, so every pull through squid's bump failed x509
# non-fatally — was indistinguishable from "nothing has been pulled yet". Two
# very different faults, one message: an ambiguous-state violation independent
# of the TLS bug itself, which criteria 1 and 2 already fixed.
#
# WHAT IS PINNED: the classifier maps real engine output to stable tokens, and
# in particular does not fold a TRUST failure into the generic bucket. The
# strings below are the shapes Go's crypto/x509 and ollama actually emit.
#
# Verdict grammar:
#   ok:pull-failure-classification:<n> passed   exit 0
#   violation:pull-failure-classification:<case> exit 1
#   blocked:<reason>                             exit 2
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

EP="images/inference/entrypoint.sh"
[ -f "$EP" ] || { echo "blocked:entrypoint-missing"; exit 2; }

D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT

# Extract only the two functions. Sourcing the entrypoint would start an engine.
awk '
    /^tillandsias_classify_pull_failure\(\) \{/ { inside = 1 }
    /^tillandsias_report_pull_failure\(\) \{/   { inside = 1 }
    inside { print }
    inside && /^\}/ { inside = 0 }
' "$EP" > "$D/unit.sh"

grep -q 'tillandsias_classify_pull_failure()' "$D/unit.sh" || { echo "blocked:extraction-failed"; exit 2; }
grep -q 'tillandsias_report_pull_failure()' "$D/unit.sh"   || { echo "blocked:extraction-failed-report"; exit 2; }

classify() { sh -c '. "$1"; tillandsias_classify_pull_failure "$2"' _ "$D/unit.sh" "$2"; }
report()   { sh -c '. "$1"; tillandsias_report_pull_failure "L" "M" "$2"' _ "$D/unit.sh" "$2" 2>&1; }

pass=0; fail=""
expect() { # <label> <expected-token> <engine-output>
    got="$(classify _ "$3")"
    if [ "$got" = "$2" ]; then pass=$((pass + 1)); else fail="${fail}$1(got:$got) "; fi
}

# The real shapes. Go's x509 wording differs from OpenSSL's, and ollama surfaces
# both depending on where the failure happens, so both are pinned.
expect tls-go        pull-failed-tls-untrusted "Error: pull model manifest: tls: failed to verify certificate: x509: certificate signed by unknown authority"
expect tls-openssl   pull-failed-tls-untrusted "curl: (60) SSL certificate problem: unable to get local issuer certificate"
expect tls-verify    pull-failed-tls-untrusted "Error: certificate verify failed"
expect unreachable   pull-failed-unreachable   "Error: pull model manifest: Get \"https://registry.ollama.ai/v2/\": dial tcp: lookup registry.ollama.ai: no such host"
expect refused       pull-failed-unreachable   "Error: connection refused"
expect notfound      pull-failed-not-found     "Error: pull model manifest: file does not exist"
expect other         pull-failed-other         "Error: something entirely unexpected happened"

# NEGATIVE CONTROL. Without this, a classifier that returns
# pull-failed-tls-untrusted unconditionally satisfies every arm above.
got="$(classify _ "Error: something entirely unexpected happened")"
if [ "$got" = "pull-failed-tls-untrusted" ]; then fail="${fail}classifier-always-says-tls "; else pass=$((pass + 1)); fi

# The TRUST case must name itself loudly AND say that no-models will lie, since
# being mistaken for an empty cache is the whole defect.
out="$(report _ "x509: certificate signed by unknown authority")"
printf '%s' "$out" | grep -q "reason=pull-failed-tls-untrusted" \
    && pass=$((pass + 1)) || fail="${fail}report-omits-token "
printf '%s' "$out" | grep -q "NOT an empty cache" \
    && pass=$((pass + 1)) || fail="${fail}report-omits-no-models-warning "

# EVIDENCE SURVIVES. A classifier that hides the output it classified is a
# nicer-looking swallow than the one this replaced.
printf '%s' "$out" | grep -q "pull-output|" \
    && pass=$((pass + 1)) || fail="${fail}report-drops-evidence "

# A non-trust failure must NOT carry the trust remedy, or the remedy is noise.
out2="$(report _ "Error: connection refused")"
printf '%s' "$out2" | grep -q "NOT an empty cache" \
    && fail="${fail}non-trust-carries-trust-remedy " || pass=$((pass + 1))

if [ -n "$fail" ]; then
    echo "violation:pull-failure-classification:${fail% }"
    exit 1
fi
echo "ok:pull-failure-classification:${pass} passed"
