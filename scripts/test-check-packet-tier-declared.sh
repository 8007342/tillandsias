#!/usr/bin/env bash
# Fixture for 1437-cr8u: scripts/check-packet-tier-declared.sh must flag a
# newly declared packet missing size/implementer_tier, accept one that
# carries both, and treat an event-only append (no packets: section) as not
# a declaration at all. Hermetic: each arm gets its own scratch git repo
# with just the checker script copied in, so REPO_ROOT (derived from
# ${BASH_SOURCE[0]}) resolves to the scratch tree, same technique as
# litmus-added-fragment-parse-gate-shape.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0

setup_scratch() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/scripts" "$d/plan/index.d"
  cp "$ROOT/scripts/check-packet-tier-declared.sh" "$d/scripts/"
  ( cd "$d" && git init -q . \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base \
      && git branch -q -f linux-next )
  printf '%s' "$d"
}

# Arm 1: a new packet declared with neither size nor implementer_tier.
d1="$(setup_scratch)"
cat >"$d1/plan/index.d/new.yaml" <<'EOF'
packets:
  - packet_id: new-packet-no-tier
    order: 9999-aaaa
    status: ready
    kind: bug
EOF
out1="$( cd "$d1" && TILLANDSIAS_FRAGMENT_PARSE_BASE=linux-next bash scripts/check-packet-tier-declared.sh 2>/dev/null )"
rc1=$?
if [ "$rc1" -eq 0 ] && [ "$out1" = "advisory:packet-tier-undeclared:1" ]; then
  PASS=$((PASS + 1))
  printf 'arm 1 ok: undeclared tier flagged\n'
else
  printf 'arm 1 FAILED: got %q rc=%d\n' "$out1" "$rc1" >&2
fi
rm -rf "$d1"

# Arm 2: a new packet declared WITH both fields, as a notes-line.
d2="$(setup_scratch)"
cat >"$d2/plan/index.d/new.yaml" <<'EOF'
packets:
  - packet_id: new-packet-with-tier
    order: 9999-bbbb
    status: ready
    kind: bug
    notes: |
      size: S  implementer_tier: haiku
EOF
out2="$( cd "$d2" && TILLANDSIAS_FRAGMENT_PARSE_BASE=linux-next bash scripts/check-packet-tier-declared.sh 2>/dev/null )"
rc2=$?
if [ "$rc2" -eq 0 ] && [ "$out2" = "ok:packet-tier-declared:1" ]; then
  PASS=$((PASS + 1))
  printf 'arm 2 ok: declared tier accepted\n'
else
  printf 'arm 2 FAILED: got %q rc=%d\n' "$out2" "$rc2" >&2
fi
rm -rf "$d2"

# Arm 3 (negative control): a fragment that only appends an event to an
# existing packet — no packets: section at all — is not a declaration.
d3="$(setup_scratch)"
cat >"$d3/plan/index.d/event.yaml" <<'EOF'
events:
  - packet_id: some-existing-packet
    event:
      type: note
      ts: "2026-09-27T00:00:00Z"
      summary: just a note
EOF
out3="$( cd "$d3" && TILLANDSIAS_FRAGMENT_PARSE_BASE=linux-next bash scripts/check-packet-tier-declared.sh 2>/dev/null )"
rc3=$?
if [ "$rc3" -eq 0 ] && [ "$out3" = "ok:packet-tier-declared:0" ]; then
  PASS=$((PASS + 1))
  printf 'arm 3 ok: event-only fragment is not a declaration\n'
else
  printf 'arm 3 FAILED: got %q rc=%d\n' "$out3" "$rc3" >&2
fi
rm -rf "$d3"

printf 'ok:check-packet-tier-declared:%d/3\n' "$PASS"
[ "$PASS" -eq 3 ]
