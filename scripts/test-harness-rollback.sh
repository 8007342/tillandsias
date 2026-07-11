#!/usr/bin/env bash
# @trace spec:default-image
# Fixture test for the order-284 harness last-good rollback in
# images/default/lib-common.sh: a fresh @latest that fails the health
# probe must roll back to the recorded last-good version; a healthy
# @latest must be recorded as the new last-good.
# Run: scripts/test-harness-rollback.sh   (exit 0 = all fixtures pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

export HOME="$WORK/home"
mkdir -p "$HOME/.cache/tillandsias-project"
export NPM_CONFIG_PREFIX="$WORK/prefix"
mkdir -p "$NPM_CONFIG_PREFIX/bin"
# stderr like production (lib-common) — _require_harness echoes its result
# on stdout inside a command substitution, so stdout traces would corrupt it.
trace_lifecycle() { echo "[lifecycle] $1 | ${*:2}" >&2; }

# Stub npm: @latest installs a BROKEN opencode (exit 1); @1.2.3 installs a
# working one. Other packages no-op successfully.
cat > npm <<'NPM'
#!/bin/bash
if [[ "$*" == *"ls -g"* ]]; then echo "opencode-ai@9.9.9-broken"; exit 0; fi
for a in "$@"; do
  case "$a" in
    opencode-ai@latest) printf '#!/bin/bash\nexit 1\n' > "$NPM_CONFIG_PREFIX/bin/opencode"; chmod +x "$NPM_CONFIG_PREFIX/bin/opencode" ;;
    opencode-ai@1.2.3) printf '#!/bin/bash\necho 1.2.3\n' > "$NPM_CONFIG_PREFIX/bin/opencode"; chmod +x "$NPM_CONFIG_PREFIX/bin/opencode" ;;
  esac
done
exit 0
NPM
chmod +x npm
export PATH="$WORK:$PATH"

# Extract the functions under test from the shipped library.
sed -n '/^harness_probe()/,/^}/p;/^harness_last_good_file()/,/^}/p;/^harness_record_last_good()/,/^}/p;/^ensure_forge_harnesses()/,/^}/p' \
    "$ROOT/images/default/lib-common.sh" > funcs.sh
# shellcheck disable=SC1091
source funcs.sh

fail() { echo "FAIL: $*" >&2; exit 1; }

# Fixture 1: broken @latest with a recorded last-good → rollback.
echo "1.2.3" > "$(harness_last_good_file opencode)"
out="$(ensure_forge_harnesses 2>&1)"
echo "$out" | grep -q "rolling back to last-good 1.2.3" || fail "no rollback attempt: $out"
echo "$out" | grep -q "rollback to 1.2.3 OK" || fail "rollback did not verify: $out"
[ "$("$NPM_CONFIG_PREFIX/bin/opencode" --version)" = "1.2.3" ] || fail "binary not rolled back"
echo "fixture 1 ok: broken @latest rolled back to last-good"

# Fixture 2: broken @latest with NO last-good → loud trace, no crash.
rm -rf "$HOME/.cache/tillandsias-project/npm-update.lock" "$NPM_CONFIG_PREFIX/bin/opencode"
rm -f "$(harness_last_good_file opencode)" "$HOME/.cache/tillandsias-project/harness-update-stamp"
out="$(ensure_forge_harnesses 2>&1)" || fail "updater must stay fail-soft"
echo "$out" | grep -q "no last-good recorded" || fail "missing loud no-last-good trace: $out"
echo "fixture 2 ok: no last-good is loud but non-fatal"

# Fixture 3: healthy install records last-good.
rm -rf "$HOME/.cache/tillandsias-project/npm-update.lock"
printf '#!/bin/bash\necho 9.9.9\n' > "$NPM_CONFIG_PREFIX/bin/opencode"
chmod +x "$NPM_CONFIG_PREFIX/bin/opencode"
harness_record_last_good opencode opencode-ai || fail "record must succeed for a healthy binary"
[ "$(cat "$(harness_last_good_file opencode)")" = "9.9.9-broken" ] || fail "last-good not recorded from npm ls"
echo "fixture 3 ok: healthy install records last-good"

# Fixture 4: sibling-updater race — harness invisible while the npm-update
# lock is held must WAIT for the sibling, not start a second npm / go fatal
# (2026-07-11 gate incident: consecutive launches raced the shared prefix).
sed -n '/^_require_harness()/,/^}/p' "$ROOT/images/default/lib-common.sh" > req.sh
# shellcheck disable=SC1091
source req.sh
rm -f "$NPM_CONFIG_PREFIX/bin/opencode"
mkdir -p "$HOME/.cache/tillandsias-project/npm-update.lock"
(
    sleep 3
    printf '#!/bin/bash\necho raced-ok\n' > "$NPM_CONFIG_PREFIX/bin/opencode"
    chmod +x "$NPM_CONFIG_PREFIX/bin/opencode"
    sleep 1
    rmdir "$HOME/.cache/tillandsias-project/npm-update.lock"
) &
resolved="$(_require_harness opencode opencode-ai opencode 2>/dev/null)"
wait
[ -x "$resolved" ] || fail "lock-wait did not resolve the sibling-installed harness (got: $resolved)"
[ "$("$resolved")" = "raced-ok" ] || fail "resolved wrong binary"
echo "fixture 4 ok: require waits out a sibling updater instead of racing it"

echo "PASS: harness rollback fixtures"
