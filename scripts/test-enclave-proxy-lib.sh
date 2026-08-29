#!/usr/bin/env bash
# freshness: added 2026-08-29 linux-yoga (order 923-rmtw)
# @trace order:923-rmtw, order:801-kqme, spec:proxy-container
#
# test-enclave-proxy-lib.sh — the gate that keeps scripts/lib/enclave-proxy.sh
# equal to ENCLAVE_NO_PROXY_BASE in the Rust source.
#
# A shell copy of a Rust constant is a copy that stops tracking its source. Two
# of them were frozen at pre-801-kqme values for eleven days
# (run-forge-project.sh, orchestrate-enclave.sh), naming git-service and missing
# nix-cache, which is 883-ncrs's symptom set from a second source. The lib
# removed the duplication; this removes the drift, by PARSING main.rs rather
# than restating the value — a gate that hardcoded the expected list would be a
# third copy and would go stale the same way.
#
# Grammar: ok:enclave-proxy-lib:<n> checked | FAIL lines then a non-zero exit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${TILLANDSIAS_ENCLAVE_PROXY_LIB:-$ROOT/scripts/lib/enclave-proxy.sh}"
MAIN="${TILLANDSIAS_HEADLESS_MAIN:-$ROOT/crates/tillandsias-headless/src/main.rs}"
fail=0
checked=0

ck() { # ck <name> <expected> <actual>
    checked=$((checked + 1))
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
    else
        printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

[ -r "$LIB" ] || { echo "unavailable:enclave-proxy-lib-unreadable:$LIB"; exit 2; }
[ -r "$MAIN" ] || { echo "unavailable:headless-source-unreadable:$MAIN"; exit 2; }

# The Rust side, parsed. Both constants are single-line string literals; a
# multi-line reformat would empty these, which the emptiness check below turns
# into a loud failure rather than a vacuous pass.
rust_base="$(awk '
    /^const ENCLAVE_NO_PROXY_BASE: &str =/ { grab = 1 }
    grab {
        if (match($0, /"[^"]+"/)) {
            print substr($0, RSTART + 1, RLENGTH - 2); exit
        }
    }' "$MAIN")"
rust_subnet="$(awk -F'"' '/^const DEFAULT_ENCLAVE_SUBNET: &str =/ { print $2; exit }' "$MAIN")"

if [ -z "$rust_base" ] || [ -z "$rust_subnet" ]; then
    # An unparsable source must never read as agreement.
    echo "unavailable:cannot-parse-rust-constants (base='$rust_base' subnet='$rust_subnet')"
    exit 2
fi

# shellcheck source=scripts/lib/enclave-proxy.sh
. "$LIB"

echo "enclave-proxy-lib: 923-rmtw"
ck "the lib's base list equals ENCLAVE_NO_PROXY_BASE" "$rust_base" "$ENCLAVE_NO_PROXY_BASE"
ck "the lib's default subnet equals DEFAULT_ENCLAVE_SUBNET" "$rust_subnet" "$ENCLAVE_SUBNET_DEFAULT"
ck "the composed list appends the subnet, as enclave_no_proxy() does" \
   "$rust_base,$rust_subnet" "$ENCLAVE_NO_PROXY"

# The subnet override, mirroring TILLANDSIAS_ENCLAVE_SUBNET in enclave_subnet().
override="$(TILLANDSIAS_ENCLAVE_SUBNET=10.9.9.0/24 bash -c ". '$LIB'; printf '%s' \"\$ENCLAVE_NO_PROXY\"")"
ck "TILLANDSIAS_ENCLAVE_SUBNET overrides the subnet" "$rust_base,10.9.9.0/24" "$override"

# The six flags, in proxy_env_args() order.
ck "the env-arg array carries the six proxy flags" "12" "${#ENCLAVE_PROXY_ENV_ARGS[@]}"
ck "the array's no_proxy value is the composed list" \
   "no_proxy=$rust_base,$rust_subnet" "${ENCLAVE_PROXY_ENV_ARGS[9]}"

# REGRESSION GUARDS, and the reason this file exists rather than a one-line
# diff: these are the two values that were actually wrong on the two scripts.
case ",$ENCLAVE_NO_PROXY," in
    *,nix-cache,*) printf '  ok   nix-cache is present (801-kqme)\n'; checked=$((checked + 1)) ;;
    *) printf '  FAIL nix-cache missing — this is the 883-ncrs symptom set\n'; fail=1; checked=$((checked + 1)) ;;
esac
case ",$ENCLAVE_NO_PROXY," in
    *,git-service,*) printf '  FAIL git-service is back — the Rust list dropped it\n'; fail=1; checked=$((checked + 1)) ;;
    *) printf '  ok   git-service is absent, as in the Rust list\n'; checked=$((checked + 1)) ;;
esac

# NO SECOND COPY. The whole point is one shell definition, so a re-pasted
# literal anywhere under scripts/ is a failure — including a partial one. Only
# the lib and this gate may name the list; the packet trail records why.
copies="$(grep -rln 'no_proxy=localhost' "$ROOT/scripts" --include='*.sh' 2>/dev/null \
    | grep -v 'scripts/lib/enclave-proxy.sh' \
    | grep -v 'scripts/test-enclave-proxy-lib.sh' \
    | grep -v 'scripts/check-containers-conf-proxy-env.sh')"
checked=$((checked + 1))
if [ -z "$copies" ]; then
    printf '  ok   no script re-pastes the list\n'
else
    printf '  FAIL a script re-pastes the no_proxy list instead of sourcing the lib:\n'
    printf '%s\n' "$copies" | sed 's/^/         /'
    fail=1
fi

if [ "$fail" = 0 ]; then
    echo "ok:enclave-proxy-lib:$checked checked"
else
    echo "violation:enclave-proxy-lib-drift"
fi
exit "$fail"
