#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-carry-forward.sh — name the packets a cycle picked up and put back down
# without saying what to do next.
#
# Order 831-ezea.
#
# THE DEFECT. The only BLOCKING exit condition the work loop enforces today is
# FILING A NEW ROW. Nothing anywhere requires that a cycle which touched a
# packet and left it open leaves that packet resumable, so arrival scales with
# service: every cycle adds rows and carries none forward, and the queue cannot
# drain at any service rate. `next_action` is the carry-forward artifact — it
# has had a READER since order 606-xu52 (crates/tillandsias-plan/src/answer.rs
# `next_action_snippet` -> the `next:` line of every `plan next` row) and is
# declared in plan/schema.yaml. Where a packet omits it that reader falls
# through to handoff_note -> outcome -> title, i.e. the row hands the next agent
# the packet's own NAME as its next step, and the next cycle replays instead of
# resuming.
#
# CLOSURES ARE EXEMPT BY DESIGN. A "what would have made this cheaper" note on a
# terminal row is a dead letter: no selector reads that row again. The exemption
# is what keeps this from degenerating into "every packet named in a fragment
# needs a next_action", which would be satisfied with filler.
#
# ADVISORY, NOT A GATE — DELIBERATELY, AND WITH A NUMBER ATTACHED.
#
#   MEASURED 2026-08-19 over plan/index.yaml (1020 packets, 367 with
#   status: ready):
#       ready rows carrying a packet-level next_action: 17/367 = 4.6%
#       all packets carrying one:                       65/1020 = 6.4%
#
#   Reproduce:
#     python3 -c "import yaml;s=yaml.safe_load(open('plan/index.yaml'))['plan_index']['steps'];\
#     r=[p for p in s if p.get('status')=='ready'];\
#     print(len([p for p in r if str(p.get('next_action','')).strip()]),'/',len(r))"
#
#   A hard refusal at 4.6% adoption would reject essentially every fragment the
#   fleet writes tonight. A gate that blocks everyone on its first night is
#   switched off within a day, and a switched-off gate is worse than none: it
#   reads as coverage. 699-dycj states the same constraint from the other side —
#   one host's habit must not become every host's red build.
#
#   PROMOTION BAR (831-ezea target): promote to blocking — change the two
#   `exit 0`s under `advisory:` below to `exit 1` and update the grammar — when
#   ready-row next_action adoption measured by the command above is >= 40%.
#   The local proxy this script prints (gap fragments / fragments checked) is
#   the second half of the evidence: promotion wants that ratio near zero on a
#   week of fresh fragments, not just a corpus-wide percentage, because the
#   corpus includes append-only history nobody may rewrite.
#
# GRAMMAR — exactly one line on stdout:
#   ^(ok:carry-forward:[0-9]+ of [0-9]+ fragments|advisory:carry-forward:[0-9]+ of [0-9]+ fragments|skipped:carry-forward:(no-plan-binary|stale-plan-binary))$
# Exit 0 always, today. `skipped:` is its own word on purpose: a pass that never
# ran must never report `ok` (785-sqe6, 787-f7dh).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FRAG_DIR="plan/index.d"
[ -d "$FRAG_DIR" ] || { echo "ok:carry-forward:0 of 0 fragments"; exit 0; }

# FAST PATH, matching check-fragment-status-loss.sh: a freshly-compacted
# checkout has no fragments and must cost no subprocess at all.
frag_present=0
for _f in "$FRAG_DIR"/*.yaml; do
    [ -f "$_f" ] && { frag_present=1; break; }
done
[ "$frag_present" -eq 1 ] || { echo "ok:carry-forward:0 of 0 fragments"; exit 0; }

# One probe, shared with every script that needs the binary (704-zcgi), and it
# resolves by EXECUTION (721-nyev): an executable BIT is a claim, RUNNING the
# binary is evidence.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary)" || PLAN=""
if [ -z "$PLAN" ]; then
    echo "skipped:carry-forward:no-plan-binary"
    echo "  tillandsias-plan not built; the carry-forward pass did not run" >&2
    exit 0
fi

# ORDER 702-68zj: a binary that predates the rule is STALE HOST STATE, not a
# ledger defect. Skip LOUDLY rather than approximating with a line grep — a
# grep cannot tell a `next_action:` key from prose quoting one, which is
# exactly how 752-pst5's checker invented a completion.
if ! plan_binary_has "$PLAN" carry-forward-check; then
    echo "skipped:carry-forward:stale-plan-binary"
    echo "  note: $PLAN predates carry-forward-check — pass SKIPPED (rebuild with 'cargo build --release -p tillandsias-plan')" >&2
    exit 0
fi

checked=0
gap_fragments=0
gap_packets=0
unparseable=0
report=""

for f in "$FRAG_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    # Command substitution, NOT a pipeline: $? here is the subcommand's own
    # status. Reading a pipeline's status as the producer's is how 787-f7dh's
    # unparseable fragments passed a gate green.
    out="$("$PLAN" carry-forward-check "$f" 2>/dev/null)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        # 3 is the typed unparseable verdict; anything else non-zero is equally
        # an unread fragment. NOT a refusal here: check-fragment-status-loss.sh
        # already hard-refuses this exact class (exit 1, `UNPARSEABLE`), and a
        # second red for one typo tells the author nothing new. Counted and
        # named so it is never silent.
        unparseable=$((unparseable + 1))
        echo "  note: ${f} could not be read (exit ${rc}) — its open packets are UNEXAMINED, not carried" >&2
        continue
    fi
    checked=$((checked + 1))
    [ -n "$out" ] || continue
    gap_fragments=$((gap_fragments + 1))
    n="$(printf '%s\n' "$out" | grep -c .)"
    gap_packets=$((gap_packets + n))
    report="${report}$(printf '%s\n' "$out" | sed "s|^|${f}: |")
"
done

if [ "$gap_fragments" -eq 0 ]; then
    echo "ok:carry-forward:0 of ${checked} fragments"
    exit 0
fi

echo "advisory:carry-forward:${gap_fragments} of ${checked} fragments"
printf '%s' "$report" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "  advisory: ${line} was touched and left OPEN with no next_action — the next cycle sees the packet's title as its next step" >&2
done
echo "  CAUSE: the cycle recorded what it DID and not what comes next, so the packet is not resumable. plan/schema.yaml declares next_action; answer.rs next_action_snippet is its reader." >&2
echo "  REMEDY: tillandsias-plan set-field <id|order> next_action \"<first concrete command or edit>\" --reason \"carry-forward\"" >&2
echo "          Use set-field, not a re-declaration under \`packets:\` — that channel is a G-Set and the fold discards the field (635-i6vm)." >&2
echo "  EXEMPT: packets this fragment CLOSED. A carry-forward note on a terminal row is a dead letter no selector reads again." >&2
echo "  ADVISORY ONLY at ${gap_packets} packet(s): next_action adoption is 4.6% of ready rows (17/367, measured 2026-08-19). Promotion bar is >= 40% — see the header of this file." >&2
exit 0
