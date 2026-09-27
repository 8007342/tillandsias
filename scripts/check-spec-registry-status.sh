#!/usr/bin/env bash
# check-spec-registry-status.sh — a spec and the litmus registry must agree on
# the spec's status.
# @trace order:1397-eppt
#
# WHY: CentiColon counts obligations from each spec's `## Status` (the spec is
# authoritative), while tooling reads openspec/litmus-bindings.yaml. When the two
# disagree, a spec the registry calls obsolete still counts as an active
# obligation, or a live one drops out of the denominator. Measured 2026-09-26 by
# the 1395-n7qd extractor: 21 disagreements on linux-next c52e15094 (7 specs
# active vs a dead registry word, 3 with no status, 3 draft/proposed vs active,
# 8 one dead word vs another).
#
# RULE: for every registry entry whose spec file exists, the first WORD of the
# first non-blank line under the spec's `## Status` (an optional `status:`
# prefix is ignored, and so is an annotation after the word) must equal the
# entry's `status:`. A spec with no `## Status` is a mismatch.
#
# OUTPUT: ok:spec-registry-status:<checked> undecided=<n> (each named above)  exit 0
#         refused:spec-registry-status:<n> + one `mismatch:` line per pair    exit 1
set -uo pipefail
# TILLANDSIAS_SPEC_ROOT is a TEST SEAM (scripts/test-spec-registry-status.sh
# points it at a fake openspec tree); production never sets it.
cd "${TILLANDSIAS_SPEC_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}" || { echo "could-not-run:spec-registry-status:no-root"; exit 3; }
R=openspec/litmus-bindings.yaml
[ -f "$R" ] || { echo "could-not-run:spec-registry-status:no-registry"; exit 3; }
# UNDECIDED PAIRS, named with the reason they could not be decided from the
# evidence (1397-eppt: "don't guess; name any you can't decide"). Each is
# PRINTED on every run and counted apart, so an open pair cannot hide in a
# green verdict. Remove an entry when its pair is decided.
UNDECIDED="${TILLANDSIAS_SPEC_UNDECIDED-tray-host-control-socket}"
undecided_reason() {
    case "$1" in
        tray-host-control-socket) echo "registry tombstone says superseded by orders 123-128 (host-guest-transport; 125 and 128 still pending); successor specs host-guest-transport and vsock-transport exist and control-wire traces vsock-transport 19x vs this spec 8x, but whether the Unix-socket tray control plane this spec describes still exists beside vsock is a design question" ;;
    esac
}
checked=0; bad=0; und=0; out=""
while IFS=' ' read -r id reg; do
    f="openspec/specs/$id/spec.md"
    [ -f "$f" ] || continue
    checked=$((checked + 1))
    # the STATUS WORD only: a line may annotate it ("obsolete (removed in v0.3
    # — see …)", secrets-management), which is not a disagreement
    spec="$(awk '/^## Status[[:space:]]*$/ { f = 1; next } f && NF { sub(/^status:[[:space:]]*/, ""); print $1; exit }' "$f")"
    if [ "$spec" != "$reg" ]; then
        case " $UNDECIDED " in
            *" $id "*) und=$((und + 1)); echo "undecided:$id:spec=$spec:registry=$reg — $(undecided_reason "$id")"; continue ;;
        esac
        bad=$((bad + 1))
        out="${out}mismatch:$id:spec=${spec:-<none>}:registry=$reg"$'\n'
    fi
done < <(awk '/^- spec_id:/ { id = $3 } /^  status:/ && id != "" { print id, $2; id = "" }' "$R")
[ "$checked" -gt 0 ] || { echo "could-not-run:spec-registry-status:no-entries-resolved"; exit 3; }
if [ "$bad" = 0 ]; then echo "ok:spec-registry-status:$checked undecided=$und"; exit 0; fi
printf '%s' "$out"
echo "refused:spec-registry-status:$bad (of $checked) — reconcile each pair with a recorded reason (1397-eppt)"
exit 1
