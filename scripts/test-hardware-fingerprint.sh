#!/usr/bin/env bash
# ORDER 805-r98w — the hardware fingerprint's job is to REFUSE a twin claim that
# is not true. These arms pin that, and the third is the real 2026-08-30 case.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$SCRIPT_DIR/fixtures/hardware-fingerprint"
FP="$SCRIPT_DIR/hardware-fingerprint.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. SAME MACHINE MODEL, DIFFERENT INSTALLATION -> twin.
#    Kernel release, hostname, probe identity and timestamp all differ. The
#    fingerprint answers "same machine model", not "same installation", so it
#    must ignore every one of them.
out="$("$FP" compare "$FIX/yoga-linux.json" "$FIX/yoga-linux-other-install.json")" \
    || fail "a host and the same host with a different kernel/hostname were called NOT twins: $out"
grep -q "^twin:" <<<"$out" || fail "expected a twin verdict, got: $out"

# 2. THE REAL CASE, 2026-08-30: yoga vs yolanda, asserted twins by the operator.
#    Note the GPU model string is IDENTICAL in both documents — AMD ships the
#    Radeon 840M and 860M under one PCI name, "Krackan [Radeon 840M / 860M
#    Graphics]". A fingerprint keyed on the GPU name would have blessed a false
#    control. The CPU part and core counts are what separate them.
if out="$("$FP" compare "$FIX/yoga-linux.json" "$FIX/yolanda-windows-reported.json")"; then
    fail "two different CPU parts were accepted as twins — the control is unverifiable again: $out"
fi
out="$("$FP" compare "$FIX/yoga-linux.json" "$FIX/yolanda-windows-reported.json" 2>&1 || true)"
grep -q "NOT TWINS" <<<"$out" || fail "expected a NOT TWINS verdict, got: $out"
grep -q "cpu_model" <<<"$out" || fail "the refusal must NAME the differing field, got: $out"
gpu_a="$(jq -r '(.devices[]|select(.device_class=="gpu")|.name)' "$FIX/yoga-linux.json")"
gpu_b="$(jq -r '(.devices[]|select(.device_class=="gpu")|.name)' "$FIX/yolanda-windows-reported.json")"
[[ "$gpu_a" == "$gpu_b" ]] \
    || fail "fixture drift: arm 2 is only meaningful while both documents share one GPU model string"

# 3. THE FINGERPRINT IS A PROPERTY OF THE DOCUMENT, NOT OF THE READER.
#    A document must fingerprint the same wherever it is read, or a host cannot
#    match its own committed capability document.
a="$("$FP" "$FIX/yoga-linux.json")"
b="$(cd / && "$FP" "$FIX/yoga-linux.json")"
[[ "$a" == "$b" ]] || fail "the same document fingerprinted differently from another directory: $a vs $b"

# 4. A MISSING IDENTIFYING FIELD MUST NOT BECOME A MATCH.
#    Two documents that each lack the CPU device are not thereby the same
#    machine — but they will fingerprint alike, so the fields must at least
#    still be reported rather than silently collapsing to an empty record.
missing="$(mktemp)"; trap 'rm -f "$missing"' EXIT
jq 'del(.devices[] | select(.device_class=="cpu"))' "$FIX/yoga-linux.json" > "$missing"
[[ "$("$FP" --json "$missing" | jq -r .cpu_model)" == "none" ]] \
    || fail "a document with no CPU device must report cpu_model=none, not a fabricated value"

echo "ok: the hardware fingerprint refuses an untrue twin claim and is stable per document (805-r98w)"
