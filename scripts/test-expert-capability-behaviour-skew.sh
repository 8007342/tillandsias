#!/usr/bin/env bash
# @trace order:984-i4k2, spec:meta-orchestration
#
# Fixture for the behaviour half of the expert-capability skew line.
#
# THE DEFECT. That line compared two SUBCOMMAND SETS — what the running binary
# reports against what the checkout's capabilities.txt declares. A subcommand
# present in both is invisible to it however much its BEHAVIOUR changed, so
# `skew=none` was truthful and useless simultaneously. Measured 2026-09-03:
# forges whose binaries predated 823e3ac0d kept writing `append-event` output
# into plan/index.yaml instead of a fragment, on FOUR hosts, every one of them
# reporting `skew=none`.
#
# WHAT THIS PINS, and the third case is the one that matters most: a binary
# that CANNOT say which sources it came from must report `unknown-currency`,
# not `none`. A truthful-but-inapplicable green is what the defect is made of,
# so the absence of an answer must never render as one — including in the
# advice prose, whose `*)` fallback used to say "No capability skew" for any
# verdict it did not recognise.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/images/default/lib-expert-capability.sh"
# shellcheck source=scripts/plan-binary-probe.sh
. "$REPO_ROOT/scripts/plan-binary-probe.sh"
BIN="${TILLANDSIAS_PLAN_BIN:-$(resolve_plan_binary 2>/dev/null || true)}"
case "$BIN" in
    /*) ;;
    ?*) BIN="$REPO_ROOT/${BIN#./}" ;;
esac
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

if [ ! -x "$BIN" ]; then
    echo "SKIP: no tillandsias-plan binary (cargo build --release -p tillandsias-plan)"
    exit 0
fi

# The binary must be able to answer both halves at all, or every case below is
# vacuous. This is the negative control for the fixture itself.
"$BIN" build-id >/dev/null 2>&1 || fail "the binary has no build-id subcommand"
"$BIN" source-revision "$REPO_ROOT/crates/tillandsias-plan" >/dev/null 2>&1 \
    || fail "the binary has no source-revision subcommand"

skew_for() {
    # skew_for <binary> <checkout>
    ( . "$LIB"; tillandsias_expert_capability "$1" "$2" >/dev/null 2>&1
      printf '%s' "${TILLANDSIAS_EXPERT_CAP_SKEW:-<unset>}" )
}
advice_for() { ( . "$LIB"; tillandsias_expert_capability_advice "$1" ); }

# 1. CURRENT binary against the checkout it was built from: no skew.
got="$(skew_for "$BIN" "$REPO_ROOT")"
[ "$got" = "none" ] || fail "current binary + own checkout should be none, got '$got'"

# 2. BEHAVIOUR SKEW: same subcommand set, different sources. Built by copying
#    the crate and perturbing one byte of a source file, so the capability sets
#    are IDENTICAL and only the content differs — which is precisely the case
#    the set comparison cannot see.
mkdir -p "$TMP/checkout/crates"
cp -r "$REPO_ROOT/crates/tillandsias-plan" "$TMP/checkout/crates/tillandsias-plan"
printf '\n// behaviour-skew fixture perturbation\n' >> "$TMP/checkout/crates/tillandsias-plan/src/main.rs"
got="$(skew_for "$BIN" "$TMP/checkout")"
[ "$got" = "rebuild-required" ] \
    || fail "perturbed sources with an identical capability set should be rebuild-required, got '$got'"

# 3. THE LOUD STATE: a binary that cannot report its build identity. It answers
#    `capabilities` exactly as the checkout declares, so the SET comparison is
#    satisfied and the old code would have said `none`.
cat > "$TMP/oldbin" <<EOF
#!/bin/sh
case "\$1" in
  capabilities) cat "$REPO_ROOT/crates/tillandsias-plan/capabilities.txt" ;;
  build-id) echo "error: unknown subcommand 'build-id'" >&2; exit 2 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TMP/oldbin"
got="$(skew_for "$TMP/oldbin" "$REPO_ROOT")"
[ "$got" = "unknown-currency" ] \
    || fail "a binary with no build-id must report unknown-currency, got '$got'"

# 4. AND THE ADVICE MUST NOT REASSURE. The `*)` fallback says "No capability
#    skew", so an unrecognised verdict reads as green prose beside a non-green
#    machine field — the defect one layer out.
for v in rebuild-required unknown-currency; do
    a="$(advice_for "$v")"
    case "$a" in
        *"No capability skew"*) fail "advice for '$v' falls through to the reassuring default" ;;
    esac
    [ -n "$a" ] || fail "advice for '$v' is empty"
done

# 5. The revision must actually discriminate, or every case above is theatre.
a="$("$BIN" source-revision "$REPO_ROOT/crates/tillandsias-plan")"
b="$("$BIN" source-revision "$TMP/checkout/crates/tillandsias-plan")"
[ "$a" != "$b" ] || fail "source-revision returned the same value for different sources ($a)"

if [ "$failures" -gt 0 ]; then
    echo "FAILED: $failures case(s)"
    exit 1
fi
echo "ok: expert-capability behaviour-skew fixture 5/5"
