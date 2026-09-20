#!/usr/bin/env bash
# ORDER 1286-4437 — the --reset-state CONTRACT, asserted across every platform
# arm that exists.
#
# WHAT THIS TESTS AND WHAT IT DOES NOT. It is a SOURCE contract test. It proves
# the three bodies agree on the flag's name, its single opt-out, its shared
# wording and its announce-before-destroy ordering. It does NOT boot a VM, does
# NOT destroy anything and therefore does NOT prove any body actually removes
# what it lists — that is a live destructive test on a smoke host, and a
# separate row. Do not read a green run here as "the reset works".
#
# It deliberately does NOT assert "--reset-state destroys more than
# --reset-guest". That is TRUE on macOS and FALSE on Windows, where the existing
# reset already cleared the credentials and the flag was a rename. Asserting it
# in either direction would encode one platform's history as the contract.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run under bash'; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FAIL=0
ok()   { printf 'ok: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; FAIL=1; }
skip() { printf 'SKIP(%s): %s\n' "$1" "$2"; }

CORE=crates/tillandsias-core/src/reset_state.rs
MAC=crates/tillandsias-macos-tray/src/reset_state.rs
MACMAIN=crates/tillandsias-macos-tray/src/main.rs
WIN=crates/tillandsias-windows-tray/src/main.rs
LIN=crates/tillandsias-headless/src/main.rs

# ARM 1 — one name. Every arm parses the identical literal.
for f in "$MACMAIN" "$WIN"; do
    if grep -q -- '"--reset-state"' "$f"; then ok "ARM1 $f parses --reset-state"
    else bad "ARM1 $f does not parse the literal \"--reset-state\""; fi
done
# The Linux body is pirria's next slice (it imports from core, which landed at
# 69f368e08). NAMED SKIP: a check that could not run must never claim what it
# would have found (965-sxec). When the body lands this becomes a real arm.
if grep -q -- '"--reset-state"' "$LIN"; then ok "ARM1 $LIN parses --reset-state"
else skip "linux-body-not-landed" "ARM1 $LIN — Linux dispatch is pirria's next slice; NOT a pass"; fi

# ARM 2 — one opt-out, and only one. A second env var was proposed, agreed by
# three hosts and approved before anyone read the source; core's guard documents
# why it must not exist.
#
# THE TOKEN IS COMPOSED AT RUNTIME AND NEVER WRITTEN WHOLE IN THIS FILE, the
# same device test-litmus-bindings.sh uses for fixture names. Two reasons, and
# the second was measured the hard way. First, this arm matches READS rather than
# mentions: its earlier version grepped the NAME and went red when pirria's Linux
# body landed carrying the same warning comment core has, and a check that fires
# on its own doctrine being written down teaches people to delete the doctrine.
# Second, litmus:installer-reprovisions-on-install asks the SAME question with a
# different grep, over crates/ and scripts/, excluding only lines that BEGIN with
# a comment marker. This file's ARM 2b deliberately writes a real env::var read as
# its positive control, and its scan greps for the token — so to that fixture, our
# control WAS a violation, and it went red on this file (FAIL:reads=2, 2026-09-20).
# A probe for a forbidden string cannot itself contain the string. Composing it
# keeps both instruments answering about the tree instead of about each other.
V_PREFIX='TILLANDSIAS_INSTALL'
V_SUFFIX='SKIP_RESET'
SECOND_OPTOUT="${V_PREFIX}_${V_SUFFIX}"
scan_reads() {
    grep -rn "$SECOND_OPTOUT" --include='*.rs' --include='*.sh' --include='*.ps1' "$@" 2>/dev/null \
      | grep -v '^[^:]*:[0-9]*:[[:space:]]*\(//\|#\|\*\|///\)'
}
HITS="$(scan_reads crates/ scripts/ | grep -v '^scripts/test-reset-state-contract.sh:')"
if [ -n "$HITS" ]; then bad "ARM2 a second opt-out is READ, not merely mentioned: $HITS"
else ok "ARM2 TILLANDSIAS_DESTRUCTIVE_RESET_OK is the only opt-out (named in prose to forbid it; read nowhere)"; fi

# ARM 2b — POSITIVE CONTROL for the comment-stripping above. An arm that ignores
# comment lines could ignore everything and still print ok. The scaffold is
# written to a TEMP DIR outside the checkout, so no tree-wide scan — ours or
# another fixture's — can mistake this control for a real read.
CTLDIR="$(mktemp -d)"
{
  printf 'fn f() {\n'
  printf '    // %s must not exist\n' "$SECOND_OPTOUT"
  printf '    let _ = std::env::var("%s");\n' "$SECOND_OPTOUT"
  printf '}\n'
} > "$CTLDIR/ctl.rs"
CTL="$(scan_reads "$CTLDIR")"
if [ -n "$CTL" ] && ! printf '%s' "$CTL" | grep -q 'must not exist'; then
    ok "ARM2b POSITIVE CONTROL — a real read is caught and the comment beside it is not"
else bad "ARM2b the comment-stripping arm cannot discriminate: got '$CTL'"; fi
rm -rf "$CTLDIR"

# ARM 3 — the pinned phrase lives in core ONLY, with no exceptions. A platform
# that spells it out itself is the exact drift the shared constant exists to
# prevent; it was paraphrased by hand once on macOS and was already wrong in its
# bytes before anyone compared them.
#
# THIS ARM CARRIED ONE PATH ALLOWLIST UNTIL 2026-09-20 and no longer does. The
# Windows tray predated the constant and kept its own line, which differed from
# core's at both ends — and the tails differed in MEANING, not just wording:
# core says it reprovisions through plain init, Windows said it provisions the
# existing state. The PINNED MIDDLE matched, which is why a phrase grep read it
# clean. An arm 3b watched that entry and failed the moment the divergence was
# fixed, so the allowlist could not quietly outlive its reason; yolanda's import
# landed (c73d796f2), 3b fired on the next run, and both it and the entry were
# deleted in the same slice. Recorded because an allowlist that leaves no trace
# of why it went away invites the next one to be added without the watchdog.
PHRASE='reset skipped by TILLANDSIAS_DESTRUCTIVE_RESET_OK=0'
STRAY="$(grep -rln --include='*.rs' -e "$PHRASE" crates/ | grep -v "^$CORE$")"
if [ -n "$STRAY" ]; then bad "ARM3 the pinned phrase is spelled out outside core: $STRAY"
else ok "ARM3 the pinned phrase lives only in $CORE (no allowlist)"; fi

# ARM 3c — every platform that has a skip path REACHES the constant. Arm 3 is an
# absence check and would stay green if a platform simply stopped printing the
# line at all, which is the other way to diverge.
for f in crates/tillandsias-windows-tray/src/notify_icon.rs "$MAC"; do
    if grep -q 'RESET_SKIPPED_LINE' "$f"; then ok "ARM3c $f uses the shared constant"
    else bad "ARM3c $f does not reference RESET_SKIPPED_LINE — it either dropped the skip line or re-spelled it"; fi
done

# ARM 4 — announce BEFORE destroy, in the macOS body. Ordering by byte offset:
# the announcement call must precede the first destructive call.
A="$(grep -n 'announce_reset_plan(&d, &p)' "$MAC" | head -1 | cut -d: -f1)"
D="$(grep -n 'wipe_provisioned_artifacts()' "$MAC" | head -1 | cut -d: -f1)"
if [ -n "$A" ] && [ -n "$D" ] && [ "$A" -lt "$D" ]; then
    ok "ARM4 macOS announces (line $A) before it destroys (line $D)"
else bad "ARM4 macOS announce=$A destroy=$D — announcement must come first"; fi

# ARM 5 — the preserved anchor is named in the PRESERVED list and never cleared.
# 803-49re: clearing it makes the next vault underivable rather than re-inited.
if grep -q 'PRESERVED_ANCHOR: &str = "installation-uuid-v1"' "$MAC" \
   && grep -q 'preserved: Vec<String> = vec!\[' "$MAC" \
   && ! grep -q 'CLEARED_CREDENTIALS.*installation-uuid' "$MAC"; then
    ok "ARM5 installation-uuid-v1 is preserved, not cleared"
else bad "ARM5 the installation anchor is not provably on the preserved side"; fi

# ARM 6 — NEGATIVE CONTROL. The arms above are greps, and a grep that matches
# nothing looks identical to one whose subject is correct. This proves they can
# still fail: assert a property that is deliberately FALSE.
if grep -q -- '"--reset-the-entire-machine"' "$MACMAIN"; then
    bad "ARM6 negative control matched — the probes are not discriminating"
else ok "ARM6 NEGATIVE CONTROL — a flag that does not exist is not found"; fi

[ "$FAIL" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAILED"; exit 1; }
