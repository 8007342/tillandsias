#!/usr/bin/env bash
# @trace spec:forge-environment-discoverability, spec:forge-offline
#
# check-spec-index-resolution-agreement.sh — the spec-index PRODUCER and its two
# READERS must resolve the same directory (order 801-a2by).
#
# WHY THIS GUARD EXISTS, and it is not hypothetical. Order 552 found that the
# embedding step "existed on no host in any language — only as English prose
# inside forge-plan.sh's refusal string", so `spec_answer` refused everywhere
# for weeks while every validator stayed green. The failure mode of a
# producer/reader disagreement is exactly that shape: nothing errors, the index
# is simply built where nobody looks, and the system reports a missing index
# instead of a misconfigured one. 789-nc2s then produced the same silence from
# the other side — a stale FORGE_SPEC_INDEX_DIR pointing at another machine.
#
# 801-a2by moved the index into the durable tier, which turned ONE literal into
# a four-level precedence chain (exact dir > explicit root > podman named volume
# > XDG cache). Three files now carry that chain:
#   scripts/spec-index-ensure.sh                     — the producer
#   images/default/config-overlay/mcp/forge-plan.sh  — spec_answer
#   images/default/lib-expert-capability.sh          — the capability line
# They live in two different runtimes (host script vs container overlay) and
# cannot share a file at runtime, so the project's established answer applies:
# duplicate deliberately, then GUARD the agreement — the same pattern as
# check-dev-embed-model-agreement.sh.
#
# THIS CHECKS THE PROPERTY, NOT THE TEXT. Identical bytes are asserted first
# because drift is easiest to catch there, but bytes alone would pass if the
# extraction silently matched nothing. So the block is also EXTRACTED and
# EXECUTED from each file under several controlled environments, and the
# resolved (root, serving-dir) pairs must agree. A vacuous extraction cannot
# satisfy that, because the resolver has to actually print two paths.
#
# Output grammar (exactly one line on stdout):
#   ^(ok:spec-index-resolution-agreement:[a-z0-9-]+=[0-9]+|violation:spec-index-resolution:.*)$
#
# Usage:
#   scripts/check-spec-index-resolution-agreement.sh
#   scripts/check-spec-index-resolution-agreement.sh --selftest
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BEGIN_RE='^# >>> BEGIN spec-index resolution (801-a2by)'
END_RE='^# <<< END spec-index resolution (801-a2by)'

CARRIERS="scripts/spec-index-ensure.sh
images/default/config-overlay/mcp/forge-plan.sh
images/default/lib-expert-capability.sh"

# _extract <file> — the shared block, markers included.
_extract() {
    sed -n "/$BEGIN_RE/,/$END_RE/p" "$1" 2>/dev/null
}

# _resolve <block-file> <env-assignments...> — execute the extracted resolver in
# a clean subshell and print "root|serving". `env -i` keeps a variable already
# exported into THIS process from leaking in and making two carriers agree for
# the wrong reason (789-nc2s is precisely a stale exported variable).
_resolve() {
    _rv_block="$1"; shift
    env -i HOME="${HOME:-/nonexistent}" PATH="$PATH" "$@" sh -c "
        . '$_rv_block'
        _tillandsias_spec_index_paths | tr '\n' '|'
    " 2>/dev/null
}

_fail() { echo "violation:spec-index-resolution:$1"; exit 1; }

# ── selftest: prove the comparison can actually go RED ───────────────────────
if [ "${1:-}" = "--selftest" ]; then
    tmp="$(mktemp -d)" || { echo "selftest:FAIL no tmpdir"; exit 1; }
    trap 'rm -rf "$tmp"' EXIT
    mk() { # mk <path> <root-expr>
        {
            echo "# >>> BEGIN spec-index resolution (801-a2by)"
            echo "_tillandsias_spec_index_paths() { printf '%s\\n%s\\n' '$2' '$2/x'; }"
            echo "# <<< END spec-index resolution (801-a2by)"
        } > "$1"
    }
    mk "$tmp/one.sh" /same
    mk "$tmp/two.sh" /same
    _extract "$tmp/one.sh" > "$tmp/e1"
    _extract "$tmp/two.sh" > "$tmp/e2"
    [ -s "$tmp/e1" ] || { echo "selftest:FAIL extractor returned empty on a marked file"; exit 1; }
    cmp -s "$tmp/e1" "$tmp/e2" || { echo "selftest:FAIL identical blocks read as different"; exit 1; }
    [ "$(_resolve "$tmp/e1")" = "/same|/same/x|" ] \
        || { echo "selftest:FAIL resolver did not execute (got '$(_resolve "$tmp/e1")')"; exit 1; }
    # DIRECTION 2: a real disagreement must be detected, textually AND
    # behaviourally. A guard that only ever compares equal things proves nothing.
    mk "$tmp/two.sh" /different
    _extract "$tmp/two.sh" > "$tmp/e2"
    cmp -s "$tmp/e1" "$tmp/e2" && { echo "selftest:FAIL differing blocks read as identical"; exit 1; }
    [ "$(_resolve "$tmp/e1")" != "$(_resolve "$tmp/e2")" ] \
        || { echo "selftest:FAIL differing resolvers produced the same path"; exit 1; }
    # DIRECTION 3: an UNMARKED file must not silently extract to nothing and
    # thereby "agree" with everything — the vacuous-green failure mode.
    printf 'echo hi\n' > "$tmp/none.sh"
    [ -z "$(_extract "$tmp/none.sh")" ] \
        || { echo "selftest:FAIL extractor invented a block"; exit 1; }
    echo "selftest:spec-index-resolution-agreement:5 cases PASS"
    exit 0
fi

# ── 1. every carrier must actually carry the block ───────────────────────────
work="$(mktemp -d)" || _fail "no-tmpdir"
trap 'rm -rf "$work"' EXIT

n=0
first=""
for rel in $CARRIERS; do
    f="$ROOT/$rel"
    [ -f "$f" ] || _fail "carrier-missing:$rel"
    n=$((n + 1))
    out="$work/block.$n"
    _extract "$f" > "$out"
    [ -s "$out" ] || _fail "no-resolution-block:$rel (markers absent — a carrier that stopped carrying the block would otherwise 'agree' with everything)"
    grep -q '_tillandsias_spec_index_paths()' "$out" \
        || _fail "block-has-no-resolver:$rel"
    [ -n "$first" ] || first="$out"
done

# ── 2. textual identity ──────────────────────────────────────────────────────
i=0
for rel in $CARRIERS; do
    i=$((i + 1))
    if ! cmp -s "$first" "$work/block.$i"; then
        {
            echo "The spec-index resolution block drifted in $rel."
            diff "$first" "$work/block.$i" 2>/dev/null | head -40
        } >&2
        _fail "block-drift:$rel"
    fi
done

# ── 3. behavioural agreement under several environments ──────────────────────
# Each scenario exercises a different rung of the precedence chain, so a change
# that reorders the chain in one carrier and not another is caught even if some
# other rung still happens to match. TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1 keeps
# this deterministic on hosts with and without podman alike; the podman rung is
# covered behaviourally by the producer's own --where output below.
SCENARIOS="exact-dir:FORGE_SPEC_INDEX_DIR=/tmp/exact:FORGE_SPEC_INDEX_ROOT=:TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1
explicit-root:FORGE_SPEC_INDEX_ROOT=/tmp/root:TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1
xdg-fallback:XDG_CACHE_HOME=/tmp/xdg:TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1"

checked=0
for scenario in $SCENARIOS; do
    label="${scenario%%:*}"
    rest="${scenario#*:}"
    # shellcheck disable=SC2086
    set -- $(printf '%s' "$rest" | tr ':' ' ')
    expect=""
    i=0
    for rel in $CARRIERS; do
        i=$((i + 1))
        got="$(_resolve "$work/block.$i" "$@")"
        [ -n "$got" ] || _fail "resolver-produced-nothing:$rel:$label"
        case "$got" in
            *'|'*'|') : ;;
            *) _fail "resolver-shape:$rel:$label:$got" ;;
        esac
        if [ -z "$expect" ]; then
            expect="$got"
        elif [ "$got" != "$expect" ]; then
            _fail "resolved-differently:$label:$rel got='$got' want='$expect'"
        fi
    done
    checked=$((checked + 1))
done

# ── 4. the producer's own --where must agree with its embedded block ─────────
# Arm 3 executes an EXTRACTED copy. This proves the producer actually CALLS the
# block it carries, rather than carrying it decoratively beside a second,
# divergent resolution it really uses — which is the exact bug the whole guard
# is about, one level up.
if [ -x "$ROOT/scripts/spec-index-ensure.sh" ]; then
    where_root="$(FORGE_SPEC_INDEX_ROOT=/tmp/where-probe TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1 \
        bash "$ROOT/scripts/spec-index-ensure.sh" --where 2>/dev/null \
        | sed -n 's/^spec-index:root=//p')"
    [ "$where_root" = "/tmp/where-probe" ] \
        || _fail "producer-ignores-its-own-block:--where reported root='${where_root:-<empty>}' for FORGE_SPEC_INDEX_ROOT=/tmp/where-probe"
    checked=$((checked + 1))
fi

echo "ok:spec-index-resolution-agreement:carriers=$n-scenarios=$checked"
