#!/usr/bin/env bash
# Enforces methodology.yaml `base64_script_injection_ban` (CRITICAL_VIOLATION):
# embedding an executable script inside a base64 literal and decoding+running it
# at runtime is forbidden (used 2026-07-01 to smuggle Python; reintroduced as a
# bash shim on windows-next and removed 2026-07-02).
#
# Verifiable constraint: fails (exit 1) if any tracked file exhibits the
# decode-to-EXECUTABLE idiom — a `base64 -d`/`--decode`/`-D` AND a `chmod +x`
# (or a `TILLANDSIAS_PODMAN_BIN=`/interpreter-swap) in the SAME file. That is the
# smell of "materialise a script from a base64 blob and run it".
#
# Deliberately narrow: decoding base64 DATA (a Shamir key, a cert, a doc example)
# is legitimate and uses `base64 -d` WITHOUT making the output executable, so it
# does not trip. Legitimate Rust base64 uses the crate API, not shell decode.
#
# @trace methodology.yaml base64_script_injection_ban
# @trace plan/issues/violation-python-base64-injection-2026-07-01.md
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

DECODE='base64 (-d|--decode|-D)\b'
EXECUTABLE='(chmod \+x|_PODMAN_BIN=|TILLANDSIAS_PODMAN_BIN)'

violations=()
# Candidate files: those containing a shell base64 decode, excluding this
# checker, the incident record, the methodology rule text, and archived docs.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -qE "$EXECUTABLE" -- "$f" 2>/dev/null; then
    violations+=("$f")
  fi
done < <(
  git grep -lE "$DECODE" -- \
    ':(exclude)scripts/check-no-base64-script-injection.sh' \
    ':(exclude)plan/issues/violation-python-base64-injection-*.md' \
    ':(exclude)plan/archive/**' \
    ':(exclude)methodology.yaml' \
    2>/dev/null || true
)

if [ "${#violations[@]}" -gt 0 ]; then
  echo "base64-script-injection-ban: VIOLATION — decode-to-executable idiom in:" >&2
  printf '  %s\n' "${violations[@]}" >&2
  echo "Do not materialise+run a script from a base64 literal. Use an approved-" >&2
  echo "language path, or surface the constraint and leave the flow broken-but-honest." >&2
  exit 1
fi

echo "ok:no-base64-script-injection"
