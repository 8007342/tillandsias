#!/usr/bin/env bash
# @trace order:1158-y3ad, order:1156-eif4, order:980-ja2m
#
# test-lww-channel-consumers.sh — every reader of the LWW channel reads BOTH
# spellings, and a fourth reader cannot be written that does not.
#
# WHY. `lww_entries` has folded two channel spellings, ["fields", "status"],
# since the `fields:` key was introduced. Three consumers in main.rs read
# `doc.get("status")` alone, so a `fields:`-spelled write was invisible to all
# three. Found by auditing a question yolanda asked after 1156-eif4 fixed the
# same defect in compact_text; verified independently on yolanda, where
# `grep -c 'get("fields")' main.rs` returned 0 — not one consumer in that file
# read the canonical spelling.
#
# The first site named the hazard on the line above the bug:
#
#     // The LWW channel. `field:` is ANY field, not just status — the key is
#     // misnamed and plan/index.d/README.md says so.
#     if let Some(sts) = doc.get("status").and_then(Value::as_sequence) {
#
# TWO SYMPTOMS, ONE DEFECT, and this is the part that makes the class worth a
# guard rather than three patches. An invisible input fails OPEN in a consumer
# that scans for OFFENDERS — closure-evidence-check builds an offender list, so
# an unscanned write is never an offender and the gate stays green. It fails
# LOUD in a consumer that scans for an OMISSION — carry_forward_gaps fills
# `carried` from the channel, so an unseen next_action write does not silence
# the advisory, it makes it FIRE about a packet whose next_action WAS set.
# Neither presentation mentions `fields:`, and the loud one is worse in one
# specific way: a reader chases the false advisory, finds a perfectly good
# next_action in the fragment, and concludes the ADVISORY is broken rather than
# the reader — which trains people to ignore the guard. (yolanda, 2026-09-13,
# correcting this author's first statement of the class as uniformly fail-open.)
#
# THE FINDING THE GUARD ENFORCES: THE CANONICAL LIST EXISTED AND WAS NOT
# CANONICAL, because nothing forced a consumer to use it. Repairing three sites
# repairs today. Only a scan-side assertion stops a fourth, and the hardcoded
# reads did not look wrong — `doc.get("status")` reads perfectly naturally
# until you know there are two spellings.
#
# 980-ja2m'S SHAPE IS LOAD-BEARING HERE. A codebase that explains itself
# contains the strings it forbids: the comments above quote the exact read this
# guard refuses, in this very file and in main.rs. So the needle is ASSEMBLED AT
# RUNTIME and comment lines are stripped before matching, or the guard goes red
# on its own history the day it is written — which is how 980-ja2m's first class
# guard failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 721-nyev / 704-zcgi. Resolve through the shared probe, never a hardcoded
# target/ path — and note WHY, because this fixture was written with the
# hardcoded path and an `[ -x ]` skip guard, and the gate refused it: AN
# EXECUTABLE BIT IS A CLAIM, RUNNING THE BINARY IS EVIDENCE. That is the same
# rule esme measured from the other direction on 2026-09-13, where one file
# reported -rw-r--r-- from Git Bash and executed from inside the build distro —
# so an `-x` test disagrees with itself depending on which locus runs it, while
# run-don't-stat refuses honestly. The probe tests by running.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; pass=$((pass+1));
       else printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

if ! PLAN="$(resolve_plan_binary)" || [ -z "$PLAN" ]; then
    echo "skip:lww-channel-consumers:no-runnable-plan-binary (build or install tillandsias-plan)"
    exit 0
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/lww-consumers.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

echo "lww-channel-consumers: 1158-y3ad"

# ── Behavioural arms. Each fragment is written TWICE, once per spelling, and
#    the two spellings must produce the same verdict. Comparing the spellings
#    against EACH OTHER rather than against a hardcoded expectation is what
#    makes these arms survive a later change to either verdict's wording.

# 1-3. carry_forward_gaps: a next_action write must suppress the gap advisory.
#      ARM 1 IS THE POSITIVE PRECONDITION AND IT IS NOT OPTIONAL. Without it
#      arms 2-3 pass by ABSENCE — "the advisory did not fire" is satisfied by a
#      pass that never fires for any input, which is how a vacuous arm looks
#      exactly like a working one. So: fire it first, then silence it twice.
_carry() { # <file> <extra-yaml>
    cat > "$1" <<YAML
events:
  - packet_id: alpha
    event:
      type: note
      ts: "2026-02-02T00:00:00Z"
      agent_id: probe
      summary: touched
$2
YAML
}

_carry "$TMPD/carry-none.yaml" ""
gaps="$("$PLAN" carry-forward-check "$TMPD/carry-none.yaml" 2>&1 | grep -c '^alpha$')"
ck "PRECONDITION: a touched packet with NO next_action write DOES raise the advisory" \
   "1" "$gaps"

for chan in status fields; do
    _carry "$TMPD/carry-$chan.yaml" "$chan:
  - packet_id: alpha
    field: next_action
    value: \"the next step is written right here\"
    ts: \"2026-02-02T00:00:01Z\"
    host: probe"
    gaps="$("$PLAN" carry-forward-check "$TMPD/carry-$chan.yaml" 2>&1 | grep -c '^alpha$')"
    ck "carry-forward: a next_action written under \`$chan:\` suppresses the advisory" \
       "0" "$gaps"
done

# 4-5. closure-evidence-check: a terminal closure with NO evidence event must be
#      refused under either spelling. Under `fields:` it used to pass silently —
#      never scanned, therefore never an offender.
for chan in status fields; do
    f="$TMPD/closure-$chan.yaml"
    cat > "$f" <<YAML
$chan:
  - packet_id: alpha
    field: status
    value: completed
    ts: "2026-02-02T00:00:01Z"
    host: probe
YAML
    out="$("$PLAN" closure-evidence-check "$f" 2>&1)"; rc=$?
    ck "closure-evidence: an evidence-free closure under \`$chan:\` is refused" \
       "refused" "$([ "$rc" -ne 0 ] && echo refused || echo "passed-silently")"
done

# ── 6. THE SCAN-SIDE GUARD. A fourth consumer cannot be written that hardcodes
#       one spelling. Matches the DECLARATION — a fragment-channel sequence read
#       — with the needle assembled at runtime, over comment-stripped source.
needle_a='.get("'"status"'")'
needle_b='.get("'"fields"'")'
offenders=""
for src in "$ROOT/crates/tillandsias-plan/src/main.rs" "$ROOT/crates/tillandsias-plan/src/answer.rs"; do
    [ -f "$src" ] || continue
    hits="$(sed 's,//.*$,,' "$src" \
        | grep -nF -e "$needle_a" -e "$needle_b" \
        | grep -F 'as_sequence' || true)"
    [ -n "$hits" ] && offenders="$offenders$src:\n$hits\n"
done
if [ -z "$offenders" ]; then
    ck "no fragment-channel read is hardcoded outside lww_entries" "clean" "clean"
else
    printf '  FAIL a fragment-channel sequence read is hardcoded outside lww_entries:\n'
    printf "$offenders"
    printf '  Call tillandsias_plan::fragments::lww_entries instead — it reads BOTH\n'
    printf '  spellings. A hardcoded read is invisible to one of them (1158-y3ad).\n'
    fail=$((fail+1))
fi

# 7. NEGATIVE CONTROL for the guard itself (980-ja2m). This file and main.rs
#    both QUOTE the forbidden read in prose. The guard must not match its own
#    history — if it did, it would be red the day it was written and someone
#    would delete the explanation to make it pass.
probe="$TMPD/comment-only.rs"
printf '%s\n' '// if let Some(x) = doc.get("status").and_then(Value::as_sequence) {' \
              '/// and doc.get("fields").and_then(as_sequence) too' \
              'fn real_code() {}' > "$probe"
chits="$(sed 's,//.*$,,' "$probe" | grep -nF -e "$needle_a" -e "$needle_b" | grep -F 'as_sequence' || true)"
ck "NEGATIVE CONTROL: a comment quoting the forbidden read does not trip the guard" \
   "" "$chits"

printf 'lww-channel-consumers: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then echo "ok:lww-channel-consumers:$pass"; exit 0; fi
echo "fail:lww-channel-consumers:$fail"; exit 1
