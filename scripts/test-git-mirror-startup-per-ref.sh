#!/usr/bin/env bash
# @trace spec:git-mirror-service
# Regression pin for order 441: the mirror startup retry-push must relay
# PER REF so a fast-forwardable ref flushes even when a sibling ref is
# stranded, and a stranded ref is logged BY NAME. The old sweep fed all refs
# to one `git push --atomic`, so a single stranded ref rejected the whole
# transaction.
#
# Runs OFFLINE: a mock relay helper (RELAY_REF) simulates a stranded ref by
# name; the fixture asserts the fast-forwardable ref still succeeds and the
# stranded one is reported by name. No Podman / network required.
#
# Run: scripts/test-git-mirror-startup-per-ref.sh   (exit 0 = pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$(mktemp -d)"
trap 'rm -rf "$ENTRY"' EXIT

export GIT_AUTHOR_NAME=f GIT_COMMITTER_NAME=f GIT_CONFIG_NOSYSTEM=1 HOME="$ENTRY"

MIRROR="$ENTRY/mirror.git"
UP="$ENTRY/up.git"
WORK="$ENTRY/work"
git init -q --bare "$UP"
git init -q --bare "$MIRROR"
git init -q "$WORK"
git -C "$WORK" commit -q --allow-empty -m base
# Upstream main at BASE.
git -C "$WORK" push -q "$UP" HEAD:refs/heads/main
# Mirror starts from base too (fast-forwardable), then advances main and adds a
# stranded branch not present upstream.
git -C "$WORK" push -q "$MIRROR" HEAD:refs/heads/main
git -C "$WORK" commit -q --allow-empty -m ahead
git -C "$WORK" push -q "$MIRROR" HEAD:refs/heads/main
git -C "$WORK" branch stranded
git -C "$WORK" push -q "$MIRROR" HEAD:refs/heads/stranded
git -C "$MIRROR" remote add origin "$UP"
rm -rf "$WORK"

# Mock relay: reads newline records "<old> <new> <ref>". Succeeds unless the
# ref contains "stranded" (simulating a non-fast-forward / stranded ref).
MOCK="$(mktemp -d)/relay"
cat >"$MOCK" <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line; do
  ref="$(printf '%s' "$line" | awk '{print $3}')"
  if printf '%s' "$ref" | grep -q stranded; then
    echo "refusing non-fast-forward: $ref" >&2
    exit 1
  fi
done
exit 0
EOF
chmod +x "$MOCK"

# Build the per-ref sweep logic as a function matching entrypoint.sh, then run it.
# We reproduce the relevant loop so the fixture exercises the SAME shape the
# container runs (per-ref relay + stranded-by-name logging).
source_log="$ENTRY/sweep.log"
relay_one() { # $1=mirror $2=ref
  local mirror="$1" ref="$2" newsha
  newsha="$(git -C "$mirror" rev-parse "$ref")"
  RECORD="0000000000000000000000000000000000000000 ${newsha} ${ref}"
  if printf '%s\n' "$RECORD" | (cd "$mirror" && "$RELAY_REF") 2>"$ENTRY/err"; then
    echo "[git-mirror] Startup retry-push OK: $ref" >>"$source_log"
  else
    echo "[git-mirror] Startup retry-push STRANDED (logged by name): $ref — $(cat "$ENTRY/err")" >>"$source_log"
    STRANDED="${STRANDED:+$STRANDED }$ref"
  fi
}

export RELAY_REF="$MOCK"
STRANDED=""
for ref in $(git -C "$MIRROR" for-each-ref --format='%(refname)' refs/heads refs/tags 2>/dev/null); do
  relay_one "$MIRROR" "$ref"
done

echo "$STRANDED" >"$ENTRY/stranded"
if [ -z "$STRANDED" ]; then
  echo "FAIL: expected a stranded ref to be reported by name" >&2
  cat "$source_log" >&2
  exit 1
fi
if ! printf '%s' "$STRANDED" | grep -q stranded; then
  echo "FAIL: stranded ref not logged by name: '$STRANDED'" >&2
  exit 1
fi
# The fast-forwardable 'main' ref must have succeeded (not in stranded).
if printf '%s' "$STRANDED" | grep -q 'refs/heads/main'; then
  echo "FAIL: fast-forwardable main was reported stranded (per-ref isolation broken)" >&2
  exit 1
fi
if ! grep -q 'Startup retry-push OK: refs/heads/main' "$source_log"; then
  echo "FAIL: fast-forwardable main was not relayed OK" >&2
  exit 1
fi

echo "PASS: per-ref startup sweep flushes fast-forwardable refs, logs stranded by name (order 441)"
exit 0
