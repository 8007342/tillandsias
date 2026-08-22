#!/usr/bin/env bash
# Fixture for order 843-624y: compaction must delete only the fragments it
# actually FOLDED, never merely the ones it LOADED.
#
# WHY THIS EXISTS. `fragments::compact` and `compact_text` both computed
# `consumed = fragments.iter().map(|f| f.path.clone())` — every fragment that
# LOADED — and the caller then deleted exactly that list. A fragment whose shape
# the fold does not absorb contributed nothing and was removed from the repo
# anyway. Measured casualty: `git show
# 9d12276ca^:plan/index.d/20260814t200300z-736-macos-control-wire-evidence.yaml`
# resolves and carries a v0.4 release-gate closure whose text exists nowhere
# under plan/ today. 1,144 fragment files have been deleted across history and
# nothing distinguished the folded from the eaten.
#
# The sibling module already had the right shape — loop_status.rs refuses with
# "compaction would LOSE fragment {} section" — so this is a port, not a design.
#
# HERMETIC: builds its own tiny ledger under mktemp. It NEVER touches
# plan/index.yaml, because the thing under test deletes files.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

. "$ROOT/scripts/plan-binary-probe.sh"
if ! PLAN="$(resolve_plan_binary)"; then
    echo "fail:compaction-coverage:no-runnable-plan-binary"
    exit 2
fi

pass=0; fail=0
ck() { # ck <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/compaction-coverage.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/index.d"

cat > "$TMPD/index.yaml" <<'YAML'
plan_index:
  steps:
    - packet_id: fixture/alpha
      order: 900-aaaa
      title: "A fixture packet"
      status: ready
      kind: fix
      events:
        - type: note
          ts: "2025-12-31T00:00:00Z"
          agent_id: seed
          host: fixture
          summary: |
            A pre-existing event, so the packet's `events:` list is block-style.
            A flow-style `events: []` makes the renderer append a SECOND
            `events:` key rather than extending the first, and the candidate
            then fails to parse — a fixture artefact, not a product defect.
YAML

# FOLDED: a well-formed event on a packet that exists. Must be consumed.
cat > "$TMPD/index.d/20260101t000000z-good.yaml" <<'YAML'
events:
  - packet_id: fixture/alpha
    event:
      type: note
      ts: "2026-01-01T00:00:00Z"
      agent_id: fixture
      host: fixture
      summary: |
        A well-formed event that the fold absorbs.
YAML

# NOT FOLDED: a packet DEFINITION written under `events:` with no `event:`
# block. The fold `continue`s past it in silence — this is the exact shape that
# lost three follow-up packets under order 801-kqme.
cat > "$TMPD/index.d/20260101t000001z-misplaced.yaml" <<'YAML'
events:
  - packet_id: fixture/beta
    order: 900-bbbb
    title: "A definition written under the wrong key"
    status: ready
    kind: fix
YAML

# NOT FOLDED: a `capabilities:` block. fold_capabilities READS this channel and
# no writer ever SERIALISES it, so consuming this fragment destroys every row.
cat > "$TMPD/index.d/20260101t000002z-capabilities.yaml" <<'YAML'
capabilities:
  - host_id: fixture-host
    schema_version: 2
    devices:
      - device_class: cpu
        usable: true
YAML

out="$("$PLAN" --index "$TMPD/index.yaml" compact 2>&1)"; rc=$?
ck "compact exits 0 when there is folded work to do" 0 "$rc"

ck "the FOLDED fragment was consumed (deleted)" \
   "absent" "$([ -e "$TMPD/index.d/20260101t000000z-good.yaml" ] && echo present || echo absent)"

# The two refusals are the whole point: unfolded fragments survive on disk.
ck "the misplaced-definition fragment SURVIVED" \
   "present" "$([ -e "$TMPD/index.d/20260101t000001z-misplaced.yaml" ] && echo present || echo absent)"
ck "the capabilities fragment SURVIVED" \
   "present" "$([ -e "$TMPD/index.d/20260101t000002z-capabilities.yaml" ] && echo present || echo absent)"

# A refusal nobody is told about is a fragment that accumulates forever with no
# explanation, so the report is part of the contract, not decoration.
ck "the refusal is REPORTED, not silent" \
   "yes" "$(grep -q 'NOT consumed' <<<"$out" && echo yes || echo no)"
ck "the report NAMES the misplaced definition" \
   "yes" "$(grep -q 'no .event:. block' <<<"$out" && echo yes || echo no)"
ck "the report NAMES the capabilities channel" \
   "yes" "$(grep -q 'capabilities' <<<"$out" && echo yes || echo no)"

# The folded event must actually be in the base afterwards — otherwise
# "consumed" would be just as wrong in the other direction.
ck "the folded event reached the base" \
   "yes" "$(grep -q 'A well-formed event that the fold absorbs' "$TMPD/index.yaml" && echo yes || echo no)"

# NON-VACUITY: with ONLY unfoldable fragments there is nothing to consume, and
# compaction must say so rather than reporting a successful empty compaction.
TMPE="$(mktemp -d "${TMPDIR:-/tmp}/compaction-coverage-b.XXXXXX")"
mkdir -p "$TMPE/index.d"
cp "$TMPD/index.yaml" "$TMPE/index.yaml"
cp "$TMPD/index.d/20260101t000001z-misplaced.yaml" "$TMPE/index.d/"
out2="$("$PLAN" --index "$TMPE/index.yaml" compact 2>&1)"
ck "an all-refused run says so instead of claiming success" \
   "yes" "$(grep -q 'all 1 fragment(s) refused' <<<"$out2" && echo yes || echo no)"
ck "an all-refused run leaves the fragment alone" \
   "present" "$([ -e "$TMPE/index.d/20260101t000001z-misplaced.yaml" ] && echo present || echo absent)"
rm -rf "$TMPE"

# ARGUMENT SAFETY. `compact` ignored every argument until 2026-08-22, so
# `compact --help` performed the compaction — reading the usage WAS the
# mutation. These assert the three shapes an unrecognised or read-only
# invocation must have, and each one checks that the ledger is UNTOUCHED,
# because "exited 0" is not the property that matters here.
TMPF="$(mktemp -d "${TMPDIR:-/tmp}/compaction-coverage-c.XXXXXX")"
mkdir -p "$TMPF/index.d"
cp "$TMPD/index.yaml" "$TMPF/index.yaml"
# A foldable fragment: if any of these invocations mutates, it disappears.
cat >"$TMPF/index.d/20260101t000000z-good.yaml" <<'YAML'
events:
  - packet_id: fixture/alpha
    event:
      type: progress
      ts: "2026-01-01T00:00:00Z"
      agent_id: fixture
      host: fixture
      summary: A well-formed event that the fold absorbs
YAML
base_before="$(cksum <"$TMPF/index.yaml")"

out3="$("$PLAN" --index "$TMPF/index.yaml" compact --help 2>&1)"; rc3=$?
ck "--help exits 0" "0" "$rc3"
ck "--help prints usage, not a compaction report" \
   "yes" "$(grep -q '^usage: tillandsias-plan compact' <<<"$out3" && echo yes || echo no)"
ck "--help says the command MUTATES" \
   "yes" "$(grep -q 'MUTATING' <<<"$out3" && echo yes || echo no)"
ck "--help left the fragment on disk" \
   "present" "$([ -e "$TMPF/index.d/20260101t000000z-good.yaml" ] && echo present || echo absent)"
ck "--help left the base byte-identical" \
   "$base_before" "$(cksum <"$TMPF/index.yaml")"

set +e
out4="$("$PLAN" --index "$TMPF/index.yaml" compact --bogus 2>&1)"; rc4=$?
set -e
ck "an unknown argument REFUSES (exit 2)" "2" "$rc4"
ck "the refusal names the argument" \
   "yes" "$(grep -q -- '--bogus' <<<"$out4" && echo yes || echo no)"
ck "an unknown argument left the fragment on disk" \
   "present" "$([ -e "$TMPF/index.d/20260101t000000z-good.yaml" ] && echo present || echo absent)"

out5="$("$PLAN" --index "$TMPF/index.yaml" compact --dry-run 2>&1)"; rc5=$?
ck "--dry-run exits 0" "0" "$rc5"
ck "--dry-run reports what it WOULD fold" \
   "yes" "$(grep -q 'dry-run — would fold 1 fragment' <<<"$out5" && echo yes || echo no)"
ck "--dry-run wrote nothing to the base" \
   "$base_before" "$(cksum <"$TMPF/index.yaml")"
ck "--dry-run left the fragment on disk" \
   "present" "$([ -e "$TMPF/index.d/20260101t000000z-good.yaml" ] && echo present || echo absent)"

# CONTROL, both directions: the same fragment in the same tree MUST still be
# consumed by a bare `compact`. Without this the four assertions above would
# also pass against a build where compaction silently stopped working.
"$PLAN" --index "$TMPF/index.yaml" compact >/dev/null 2>&1
ck "CONTROL: a bare compact still consumes it" \
   "absent" "$([ -e "$TMPF/index.d/20260101t000000z-good.yaml" ] && echo present || echo absent)"
rm -rf "$TMPF"

printf 'compaction-coverage: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "ok:compaction-coverage:$pass"
