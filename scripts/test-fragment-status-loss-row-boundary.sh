#!/usr/bin/env bash
# @trace order:1331-884p, order:1570-mxcg
#
# test-fragment-status-loss-row-boundary.sh — the ROW BOUNDARY of the status-
# loss gate's `packets:` pass. ORDER 1331-884p (carried from 1319-vd5h) pinned
# it in the awk of scripts/check-fragment-status-loss.sh; ORDER 1570-mxcg ported
# the gate to scripts/lua/check-fragment-status-loss.lua, which reads every
# fragment with yaml.parse, so the boundary is now the YAML parser's and this
# fixture proves the port reads what each awk generation got wrong.
#
# The awk passes are taken VERBATIM from git history, never re-implemented:
#   PRE_SHA  (11e65bc86)  before 1331-884p — the FLUSH/CAPTURE faults:
#            a nested list between packet_id and status dropped the pair, and a
#            FLAT row (marker at indent 0) was never read at all.
#   LAST_SHA (537b09f6e)  the .sh's final version — 1331-884p widened the status
#            capture to `^[ ]*status:` at any depth, so a block scalar QUOTING
#            `status: completed` is read as the packet's status. Measured on
#            yoga 2026-10-10: that awk reads `completed` for a packet declared
#            `ready`, i.e. the .sh false-refuses such a fragment.
#
# ARMS. Each exists because a weaker version could not fail:
#   0 SELF-CHECK  both pinned passes extract non-empty and the runner has
#                 `script`; otherwise could-not-run, never a verdict.
#   1 NESTED      a: an indentless nested list (valid YAML) — PRE awk loses the
#                 pair, the port reads it. b: 1331-884p's own fixture shape is
#                 not YAML at all — the port refuses it as UNPARSEABLE.
#   2 FLAT        PRE awk never sees the packet; the port reads it.
#   3 PROSE       LAST awk reads the quoted `completed`; the port reads `ready`.
#   4 CORPUS      over the live ledger the port loses no pair PRE read, and
#                 reads the five rows PRE could not, BY NAME.
#   5 END TO END  through the gate's own verdict over a synthetic fold:
#                 a nested-list fragment declaring `completed` for a packet that
#                 folds `ready` REFUSES (the seeded violation reddens), and the
#                 prose fragment PASSES (no false refusal).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2
OLD_SUBJECT="scripts/check-fragment-status-loss.sh"
GUARD="$ROOT/scripts/lua/check-fragment-status-loss.lua"
PRE_SHA="${STATUS_LOSS_PIN_SHA:-11e65bc86adfbcf35c21278278d4e37ff785b7cf}"
LAST_SHA="${STATUS_LOSS_LAST_SHA:-537b09f6e4f4140bc1677eb6e65446ba3092c2a2}"

rc=0
mkdir -p "$ROOT/target/plan-scratch"
tmp="$(mktemp -d "$ROOT/target/plan-scratch/status-loss-boundary.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM
note() { printf '%s\n' "$*"; }
fail() { printf 'FAIL:%s\n' "$*" >&2; rc=1; }

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
plan_from_checkout() {
    local p
    p="$(cd "$ROOT" && resolve_plan_binary)" || return 1
    case "$p" in
        /*) printf '%s\n' "$p" ;;
        *)  printf '%s/%s\n' "$ROOT" "${p#./}" ;;
    esac
}
PLAN="$(plan_from_checkout)" || PLAN=""
if [ -z "$PLAN" ]; then
    note "skip:status-loss-boundary:no-plan-binary"
    exit 0
fi

extract_pass() { awk '/^declared="\$\(awk/{f=1;next} f&&/^'"'"' "\$FRAG_DIR"/{exit} f{print}' "$1"; }

for s in "$PRE_SHA" "$LAST_SHA"; do
    if ! git cat-file -e "$s:$OLD_SUBJECT" 2>/dev/null; then
        note "skip:status-loss-boundary:pin-unreachable:$s (shallow clone or unfetched history)"
        exit 0
    fi
done
git show "$PRE_SHA:$OLD_SUBJECT"  > "$tmp/pre.sh"
git show "$LAST_SHA:$OLD_SUBJECT" > "$tmp/last.sh"
extract_pass "$tmp/pre.sh"  > "$tmp/pre.awk"
extract_pass "$tmp/last.sh" > "$tmp/last.awk"

# ── ARM 0 — CAN THIS RUN MEASURE? ───────────────────────────────────────────
caps="$("$PLAN" capabilities 2>/dev/null)"
if [ ! -s "$tmp/pre.awk" ] || [ ! -s "$tmp/last.awk" ] || ! grep -qx script <<<"$caps"; then
    note "could-not-run:status-loss-boundary:cannot-measure pre=$(wc -l < "$tmp/pre.awk") last=$(wc -l < "$tmp/last.awk") lines; script-runner=$(grep -cx script <<<"$caps")"
    echo "  A pinned awk pass could not be extracted, or the plan binary cannot run Lua. Nothing below measured anything; this is not a verdict on the gate." >&2
    exit 2
fi
note "ok:status-loss-boundary:arm0-can-measure:pre=$(wc -l < "$tmp/pre.awk") last=$(wc -l < "$tmp/last.awk") lines"

awk_pairs() { awk -f "$1" "$2" 2>/dev/null; }

# A scratch repo holding ONE fragment; the port's --dump-declared reads it.
# `repo <name> <fragment-file>` echoes the repo dir.
repo() {
    local d="$tmp/$1"
    mkdir -p "$d/plan/index.d"
    printf 'plan_index:\n  version: v1\n  root: plan/\n  steps: []\n' > "$d/plan/index.yaml"
    cp "$2" "$d/plan/index.d/a.yaml"
    printf '%s\n' "$d"
}
lua_pairs() { # lua_pairs <repo> -> "pid<TAB>status" rows the port read
    (cd "$1" && env -u TILLANDSIAS_REPO_ROOT "$PLAN" script run "$GUARD" -- --dump-declared 2>/dev/null) > "$1.dump"
    awk -F'\t' '!/^ok:/ { print $2 "\t" $3 }' "$1.dump"
}

# ── ARM 1 — a nested list BETWEEN packet_id and status ──────────────────────
# 1a: the shape a YAML dumper emits — an INDENTLESS nested sequence at the
#     parent key's indent (here under a flat row). Valid YAML; the PRE awk's
#     bare-dash flush drops the pair, the port reads it.
printf '%s\n' 'packets:' \
              '- packet_id: fixture-nested-list-between-packet-id-and-status' \
              '  capability_tags:' \
              '  - plan' \
              '  - tooling' \
              '  status: ready' > "$tmp/nested.yaml"
pre1="$(awk_pairs "$tmp/pre.awk" "$tmp/nested.yaml")"
post1="$(lua_pairs "$(repo nested "$tmp/nested.yaml")")"
[ -z "$pre1" ] || fail "status-loss-boundary:arm1a:the PRE pass should LOSE this pair (got [$pre1]) — the pin is not the pre-fix code"
case "$post1" in
  *fixture-nested-list-between-packet-id-and-status*ready*) note "ok:status-loss-boundary:arm1a-nested-list:pair lost by the PRE awk, read by the port" ;;
  *) fail "status-loss-boundary:arm1a:the port did not read the nested-list pair (got [$post1])" ;;
esac
# 1b: 1331-884p's own fixture put the nested dashes at indent 2 under an
#     indent-4 mapping. That is NOT YAML (the plan binary cannot fold it either),
#     which awk never noticed because it does not parse. The port must REFUSE it
#     as unparseable — loud — never read it as nothing (787-f7dh).
printf '%s\n' 'packets:' \
              '  - packet_id: fixture-nested-list-between-packet-id-and-status' \
              '    capability_tags:' \
              '  - plan' \
              '  - tooling' \
              '    status: ready' > "$tmp/nested-invalid.yaml"
# ── ARM 2 — a FLAT fragment, row marker at indent 0 ─────────────────────────
# printf '%s\n' FOR EVERY LINE: a leading dash is otherwise read as an option.
printf '%s\n' 'packets:' \
              '- packet_id: fixture-flat-row-marker-at-indent-zero' \
              '  order: 9999-flat' \
              '  capability_tags:' \
              '  - macos' \
              '  status: ready' > "$tmp/flat.yaml"
pre2="$(awk_pairs "$tmp/pre.awk" "$tmp/flat.yaml")"
post2="$(lua_pairs "$(repo flat "$tmp/flat.yaml")")"
[ -z "$pre2" ] || fail "status-loss-boundary:arm2:the PRE pass should not SEE this packet at all (got [$pre2])"
case "$post2" in
  *fixture-flat-row-marker-at-indent-zero*ready*) note "ok:status-loss-boundary:arm2-flat-row:packet invisible to the PRE awk, read by the port" ;;
  *) fail "status-loss-boundary:arm2:the port did not read the flat packet (got [$post2])" ;;
esac

# ── ARM 3 — a block scalar QUOTING a status line ────────────────────────────
printf '%s\n' 'packets:' \
              '  - packet_id: fixture-prose-quotes-a-status-line' \
              '    order: 9999-prose' \
              '    context: |' \
              '      the old fragment read' \
              '      status: completed' \
              '      which was prose, not a field' \
              '    status: ready' > "$tmp/prose.yaml"
last3="$(awk_pairs "$tmp/last.awk" "$tmp/prose.yaml")"
post3="$(lua_pairs "$(repo prose "$tmp/prose.yaml")")"
case "$last3" in
  *fixture-prose-quotes-a-status-line*completed*) ;;
  *) fail "status-loss-boundary:arm3:the LAST awk should read the QUOTED status (got [$last3]) — the pin is not the defective code" ;;
esac
if [ "$post3" = "$(printf 'fixture-prose-quotes-a-status-line\tready')" ]; then
    note "ok:status-loss-boundary:arm3-prose:the LAST awk read the quoted 'completed', the port reads the field 'ready'"
else
    fail "status-loss-boundary:arm3:the port did not read exactly the declared status (got [$post3])"
fi

# ── ARM 4 — THE LIVE CORPUS: NOTHING LOST, THE FIVE READ BY NAME ────────────
FIVE="1313-w78k 1314-2mdv 1315-d4qd 1323-pc8k 1327-r4zb"
corpus=(); while IFS= read -r f; do corpus+=("$f"); done < <(ls plan/index.d/*.yaml 2>/dev/null)
if [ "${#corpus[@]}" -eq 0 ]; then
    note "could-not-run:status-loss-boundary:arm4:no fragments found under plan/index.d — not a verdict on the gate"
else
    # Captured to files, never piped: each stage's status stays its own.
    : > "$tmp/pre.raw"
    for f in ${corpus[@]+"${corpus[@]}"}; do
        awk -f "$tmp/pre.awk" "$f" > "$tmp/one" 2>/dev/null
        awk -v f="$f" '{ print f "\t" $0 }' "$tmp/one" >> "$tmp/pre.raw"
    done
    LC_ALL=C sort -u -o "$tmp/pre.pairs" "$tmp/pre.raw"
    (env -u TILLANDSIAS_REPO_ROOT "$PLAN" script run "$GUARD" -- --dump-declared 2>/dev/null) > "$tmp/port.raw"
    awk '!/^ok:/' "$tmp/port.raw" > "$tmp/port.rows"
    LC_ALL=C sort -u -o "$tmp/port.pairs" "$tmp/port.rows"
    LC_ALL=C comm -23 "$tmp/pre.pairs" "$tmp/port.pairs" > "$tmp/lost"
    LC_ALL=C comm -13 "$tmp/pre.pairs" "$tmp/port.pairs" > "$tmp/gained"
    lost=$(wc -l < "$tmp/lost"); lost=$((lost + 0))
    gained=$(wc -l < "$tmp/gained"); gained=$((gained + 0))
    [ "$lost" -eq 0 ] || fail "status-loss-boundary:arm4:pairs the PRE awk read are LOST by the port: $lost"
    missing=""
    for o in $FIVE; do
        grep -q -- "$o" "$tmp/gained" || missing="$missing $o"
    done
    if [ -n "$missing" ]; then
        fail "status-loss-boundary:arm4:these rows were NOT read by the port:$missing (gained=$gained, lost=$lost)"
    else
        note "ok:status-loss-boundary:arm4-corpus:$gained pair(s) gained over PRE, 0 lost — all five named rows read:$(printf ' %s' $FIVE)"
    fi
fi

# ── ARM 5 — END TO END, THROUGH THE GATE'S VERDICT ──────────────────────────
# A synthetic fold where both packets fold `ready`; the gate asks the real
# binary. The nested-list shape now carries a TERMINAL declaration, so a lost
# pair would be a missed refusal (the seeded violation must redden).
e2e() { # e2e <name> <fragment> -> output, rc in E2E_RC
    local d="$tmp/e2e-$1"
    mkdir -p "$d/plan/index.d"
    printf '%s\n' 'plan_index:' '  version: v1' '  root: plan/' '  steps:' \
        '    - packet_id: fixture-nested-list-between-packet-id-and-status' \
        '      order: 9001' '      title: "nested"' '      status: ready' '      kind: fix' '      depends_on: []' \
        '    - packet_id: fixture-prose-quotes-a-status-line' \
        '      order: 9002' '      title: "prose"' '      status: ready' '      kind: fix' '      depends_on: []' > "$d/plan/index.yaml"
    cp "$2" "$d/plan/index.d/a.yaml"
    E2E_OUT="$(cd "$d" && env -u TILLANDSIAS_REPO_ROOT -u TILLANDSIAS_PLAN_BIN "$PLAN" script run "$GUARD" -- --plan "$PLAN" 2>&1)"
    E2E_RC=$?
}
sed 's/^  status: ready$/  status: completed/' "$tmp/nested.yaml" > "$tmp/nested-completed.yaml"
e2e nested "$tmp/nested-completed.yaml"
if [ "$E2E_RC" -eq 1 ] && grep -q "fixture-nested-list-between-packet-id-and-status: declared 'completed' in a fragment, folds as 'ready'" <<<"$E2E_OUT"; then
    note "ok:status-loss-boundary:arm5a-seeded-violation:the nested-list terminal declaration the fold discarded REFUSES"
else
    fail "status-loss-boundary:arm5a:a seeded discarded closure did not refuse (rc=$E2E_RC): $(tr '\n' ' ' <<<"$E2E_OUT")"
fi
e2e invalid "$tmp/nested-invalid.yaml"
if [ "$E2E_RC" -eq 1 ] && grep -q 'UNPARSEABLE' <<<"$E2E_OUT"; then
    note "ok:status-loss-boundary:arm1b-not-yaml:the 1331-884p fixture shape is refused as UNPARSEABLE, never read as nothing"
else
    fail "status-loss-boundary:arm1b:a fragment that is not YAML was not refused as unparseable (rc=$E2E_RC): $(tr '\n' ' ' <<<"$E2E_OUT")"
fi
e2e prose "$tmp/prose.yaml"
if [ "$E2E_RC" -eq 0 ] && grep -q '^ok:no-fragment-status-loss:' <<<"$E2E_OUT"; then
    note "ok:status-loss-boundary:arm5b-no-false-refusal:prose quoting 'status: completed' passes"
else
    fail "status-loss-boundary:arm5b:the prose fragment was refused (rc=$E2E_RC): $(tr '\n' ' ' <<<"$E2E_OUT")"
fi

if [ $rc -eq 0 ]; then note "ok:fragment-status-loss-row-boundary:8/8 arms"; else note "violation:fragment-status-loss-row-boundary"; fi
exit $rc
