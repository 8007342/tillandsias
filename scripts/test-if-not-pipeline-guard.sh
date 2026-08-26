#!/usr/bin/env bash
# @trace plan 795-imz3
# Proves that the if-not-pipeline gate behaves correctly.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail_fixture="$WORK/fail_fixture.sh"
echo '#!/usr/bin/env bash' > "$fail_fixture"
echo 'if ! printf "%s" "foo" | grep -q "foo"; then' >> "$fail_fixture"
echo '    exit 1' >> "$fail_fixture"
echo 'fi' >> "$fail_fixture"
chmod +x "$fail_fixture"

pass_fixture1="$WORK/pass_fixture1.sh"
echo '#!/usr/bin/env bash' > "$pass_fixture1"
echo 'if ! grep -q "foo" <<<"foo"; then' >> "$pass_fixture1"
echo '    exit 1' >> "$pass_fixture1"
echo 'fi' >> "$pass_fixture1"
chmod +x "$pass_fixture1"

pass_fixture2="$WORK/pass_fixture2.sh"
echo '#!/usr/bin/env bash' > "$pass_fixture2"
echo 'case $'"'\n'foo'\n'"' in' >> "$pass_fixture2"
echo '    *$'"'\n'foo'\n'"'*) ;;' >> "$pass_fixture2"
echo '    *) exit 1 ;;' >> "$pass_fixture2"
echo 'esac' >> "$pass_fixture2"
chmod +x "$pass_fixture2"

# 1. Pipeline fixture must FAIL
if scripts/check-no-spawn-in-if-not.sh "$fail_fixture" >/dev/null 2>&1; then
    echo "violation:if-not-pipeline-guard: failed to refuse pipeline" >&2
    exit 1
fi

# 2. Bare command fixture must PASS
if ! scripts/check-no-spawn-in-if-not.sh "$pass_fixture1" >/dev/null 2>&1; then
    echo "violation:if-not-pipeline-guard: refused bare command" >&2
    exit 1
fi

# 3. Case idiom fixture must PASS
if ! scripts/check-no-spawn-in-if-not.sh "$pass_fixture2" >/dev/null 2>&1; then
    echo "violation:if-not-pipeline-guard: refused case idiom" >&2
    exit 1
fi

echo "ok:if-not-pipeline-guard-shape:3"
exit 0
