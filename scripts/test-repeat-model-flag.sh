#!/usr/bin/env bash
# Fixture for 1437-m5yx: the `claude)` arm of ./repeat must pass --model and
# --effort through to the claude binary, exactly as the codex/opencode arms
# already pass their -m flag. A stub CLAUDE_BIN records its argv; three arms
# check it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

cat >"$WORK/stub-claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_ARGV_FILE"
printf 'stub output\n'
exit 0
STUB
chmod +x "$WORK/stub-claude"

PASS=0

run_repeat() {
  # ./repeat hardcodes target/debug/tillandsias-policy under REPO_ROOT; a
  # redirected CARGO_TARGET_DIR (as forges set) must not leak into this
  # fixture (721-nyev names the same trap for the plan binary).
  ( cd "$ROOT" && env -u CARGO_TARGET_DIR CLAUDE_BIN="$WORK/stub-claude" \
      STUB_ARGV_FILE="$WORK/argv.txt" \
      timeout 120 ./repeat --times 1 --agent claude --prompt x "$@" \
      >"$WORK/repeat.log" 2>&1 )
}

# Arm 1: --model haiku must reach the claude argv.
rm -f "$WORK/argv.txt"
if run_repeat --model haiku && grep -qFx -- '--model' "$WORK/argv.txt" \
    && grep -A1 -Fx -- '--model' "$WORK/argv.txt" | grep -qFx -- 'haiku'; then
  PASS=$((PASS + 1))
  printf 'arm 1 ok: --model haiku reached claude argv\n'
else
  printf 'arm 1 FAILED: --model did not reach claude argv:\n' >&2
  cat "$WORK/argv.txt" 2>/dev/null >&2 || true
fi

# Arm 2: --effort low must reach the claude argv.
rm -f "$WORK/argv.txt"
if run_repeat --effort low && grep -qFx -- '--effort' "$WORK/argv.txt" \
    && grep -A1 -Fx -- '--effort' "$WORK/argv.txt" | grep -qFx -- 'low'; then
  PASS=$((PASS + 1))
  printf 'arm 2 ok: --effort low reached claude argv\n'
else
  printf 'arm 2 FAILED: --effort did not reach claude argv:\n' >&2
  cat "$WORK/argv.txt" 2>/dev/null >&2 || true
fi

# Arm 3 (negative control): no --model/--effort given, none appear.
rm -f "$WORK/argv.txt"
if run_repeat && ! grep -qFx -- '--model' "$WORK/argv.txt" \
    && ! grep -qFx -- '--effort' "$WORK/argv.txt"; then
  PASS=$((PASS + 1))
  printf 'arm 3 ok: no --model/--effort token when neither flag is given\n'
else
  printf 'arm 3 FAILED: unexpected --model/--effort token with neither flag given:\n' >&2
  cat "$WORK/argv.txt" 2>/dev/null >&2 || true
fi

printf 'ok:repeat-model-flag:%d/3\n' "$PASS"
[ "$PASS" -eq 3 ]
