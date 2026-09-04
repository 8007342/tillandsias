#!/usr/bin/env bash
# @trace spec:litmus-framework, spec:methodology-accountability
# @trace order:972-cvdg
#
# Fixture for scripts/check-litmus-steps-can-fail.sh.
#
# A GUARD AGAINST TESTS THAT CANNOT FAIL MUST ITSELF BE ABLE TO FAIL, and that
# is not a joke — the five steps this guard was written for passed for their
# whole existence, and nothing about a passing run distinguished them from
# working ones. So this fixture drives the guard over a temporary corpus and
# asserts BOTH directions: it catches the shape, and it stays quiet on the
# legitimate two-token idiom next to it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/scripts/check-litmus-steps-can-fail.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0

expect() {
    local name="$1" want_rc="$2" want_grep="$3"
    local out rc
    out="$(TILLANDSIAS_LITMUS_DIR="$TMP" bash "$GUARD" 2>&1)"
    rc=$?
    if [ "$rc" != "$want_rc" ]; then
        echo "FAIL: $name — exit $rc, wanted $want_rc"
        echo "  output: $out"
        failures=$((failures + 1))
        return
    fi
    case "$out" in
        *"$want_grep"*) ;;
        *)
            echo "FAIL: $name — output does not contain '$want_grep'"
            echo "  output: $out"
            failures=$((failures + 1))
            return
            ;;
    esac
    echo "ok: $name"
}

# 1. THE REAL DEFECT, verbatim from litmus-podman-idiomatic-security-flags.yaml
#    before 972-cvdg fixed it.
cat > "$TMP/a.yaml" <<'EOF'
critical_path:
  - step: "verify podman inspect shows --userns=keep-id flag"
    command: "podman inspect x --format='{{json .HostConfig.UsernsMode}}' | grep -q 'keep-id' && echo 'USERNS_KEEP_ID_SET' || echo 'USERNS_KEEP_ID_SET'"
    expected_behavior: "USERNS_KEEP_ID_SET"
EOF
expect "the shipped defect is caught" 1 "violation:litmus-steps-cannot-fail:1"

# 2. THE LEGITIMATE IDIOM MUST NOT BE FLAGGED. `cmd && echo A || echo B` with
#    DIFFERENT tokens is how a step reports which of two states it found, and it
#    is everywhere in this corpus. A guard that flagged it would be noise, and
#    noise is how a guard stops being run.
cat > "$TMP/a.yaml" <<'EOF'
critical_path:
  - step: "report which state was found"
    command: "test -e /nope && echo 'PRESENT' || echo 'ABSENT'"
    expected_behavior: "ABSENT"
EOF
expect "two distinct tokens are left alone" 0 "ok:litmus-steps-can-fail"

# 3. QUOTING MUST NOT BE AN ESCAPE HATCH: 'X' and "X" are the same token, and a
#    guard that compared them raw would be evaded by changing one spelling.
cat > "$TMP/a.yaml" <<'EOF'
critical_path:
  - step: "mixed quoting is still the same token"
    command: "grep -q foo bar && echo 'SAME' || echo \"SAME\""
    expected_behavior: "SAME"
EOF
expect "quote spelling does not evade the guard" 1 "violation:litmus-steps-cannot-fail:1"

# 4. A CLEAN CORPUS IS SILENT — the negative control for the whole guard.
rm -f "$TMP"/*.yaml
cat > "$TMP/a.yaml" <<'EOF'
critical_path:
  - step: "no fallback at all"
    command: "podman info --format='{{.Security.Rootless}}'"
    expected_behavior: "true"
EOF
expect "a clean corpus passes quietly" 0 "ok:litmus-steps-can-fail:1 file(s) checked"

if [ "$failures" -gt 0 ]; then
    echo "FAILED: $failures case(s)"
    exit 1
fi
echo "ok: litmus steps-can-fail guard fixture 4/4"
