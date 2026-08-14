#!/usr/bin/env bash
# @trace order:731-d89b, spec:ci-release
set -uo pipefail

# Fixture for the exec-bit guard (order 731-d89b).
#
# Hermetic: a throwaway git repo containing one caller and one script. Nothing
# here touches the real worktree, because the check reads `git ls-files -s` and
# the whole point is to control what that returns.
#
# Both directions matter. A guard that flagged every shebanged file would be
# satisfied by the breach case alone while flagging the 26 files that are
# CORRECTLY non-executable here — sourced libraries, and scripts every caller
# invokes as `bash scripts/x.sh`, which works at any mode.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-script-exec-bits.sh"

failures=()

# fixture <mode> <caller-line>  -> prints the verdict
fixture() {
    local mode="$1" caller="$2" d
    d="$(mktemp -d "${TMPDIR:-/tmp}/exec-bit-fixture.XXXXXX")"
    mkdir -p "$d/scripts" "$d/skills/demo"
    cp "$CHECK" "$d/scripts/"
    printf '#!/usr/bin/env bash\necho hi\n' > "$d/scripts/subject.sh"
    printf '# runbook\n\n```bash\n%s\n```\n' "$caller" > "$d/skills/demo/SKILL.md"
    (
        cd "$d" || exit 2
        git init -q .
        git add -A >/dev/null 2>&1
        git update-index --chmod="$mode" scripts/subject.sh >/dev/null 2>&1
        bash scripts/check-script-exec-bits.sh 2>/dev/null
    )
    rm -rf "$d"
}

check() {
    local name="$1" want="$2" got="$3"
    [ "$got" = "$want" ] || failures+=("$name: expected '$want', got '$got'")
}

# 1. THE BREACH: bare invocation + mode 100644. This is exactly how
#    resolve-release-run.sh reached linux-next from the Windows host.
check "bare-invocation-non-executable" \
    "violation:script-not-executable:1" \
    "$(fixture -x 'scripts/subject.sh --flag')"

# 2. POSITIVE CONTROL, same caller, mode 100755. Without this the guard could
#    be refusing on the invocation alone and nobody would notice.
check "bare-invocation-executable" \
    "ok:script-exec-bits:0 checked" \
    "$(fixture +x 'scripts/subject.sh --flag')"

# 3. NEGATIVE CONTROL: `bash scripts/subject.sh` works at ANY mode, so mode
#    100644 must NOT be flagged. Flagging it would condemn most of scripts/.
check "interpreter-prefixed-non-executable" \
    "ok:script-exec-bits:1 checked" \
    "$(fixture -x 'bash scripts/subject.sh --flag')"

# 4. NEGATIVE CONTROL: a SOURCED library must stay unflagged — several here are
#    meant to be non-executable, and making them +x would be the wrong fix.
check "sourced-library-non-executable" \
    "ok:script-exec-bits:1 checked" \
    "$(fixture -x 'source scripts/subject.sh')"

if [ "${#failures[@]}" -gt 0 ]; then
    printf 'FAIL: %s\n' "${failures[@]}" >&2
    echo "script-exec-bits: FAIL ${#failures[@]} scenario(s)"
    exit 1
fi
echo "PASS: script-exec-bits fixture 4/4 scenarios green (bare-invocation-non-executable, bare-invocation-executable, interpreter-prefixed-non-executable, sourced-library-non-executable)"
