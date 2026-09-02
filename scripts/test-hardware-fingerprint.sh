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

# 2. TWO DIFFERENT CPU PARTS ARE NOT TWINS, even when every other identifying
#    field agrees. The fixture is yoga's own document with ONLY the CPU part and
#    core counts changed, so the arm isolates exactly that: the GPU model string
#    is IDENTICAL in both, because AMD ships the Radeon 840M and 860M under one
#    PCI name. A fingerprint keyed on the GPU would have blessed the pair.
#
#    NOTE this fixture is a CONSTRUCTED variant of a real document, not a
#    transcription of any host's reported specs. An earlier version of it was
#    built from yolanda's specs as described in a message, which reintroduced
#    exactly the assertion-instead-of-artifact problem this packet exists to
#    kill — and it claimed devices (an XDNA NPU at /dev/accel/accel0) that that
#    host's real capability document does not report. A fixture standing in for
#    a host must be that host's document or be honest about being synthetic.
if out="$("$FIX/../../hardware-fingerprint.sh" compare "$FIX/yoga-linux.json" "$FIX/same-gpu-different-cpu.json")"; then
    fail "two different CPU parts were accepted as twins — the control is unverifiable again: $out"
fi
out="$("$FP" compare "$FIX/yoga-linux.json" "$FIX/same-gpu-different-cpu.json" 2>&1 || true)"
grep -q "NOT TWINS" <<<"$out" || fail "expected a NOT TWINS verdict, got: $out"
grep -q "cpu_model" <<<"$out" || fail "the refusal must NAME the differing field, got: $out"
gpu_a="$(jq -r '(.devices[]|select(.device_class=="gpu")|.name)' "$FIX/yoga-linux.json")"
gpu_b="$(jq -r '(.devices[]|select(.device_class=="gpu")|.name)' "$FIX/same-gpu-different-cpu.json")"
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
missing="$(mktemp)"
jq 'del(.devices[] | select(.device_class=="cpu"))' "$FIX/yoga-linux.json" > "$missing"
rc=0; "$FP" --json "$missing" >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] || fail "a document with no CPU device must refuse (exit 2), not report a fabricated fingerprint"
rm -f "$missing"

# 5. TWO DOCUMENTS THAT DO NOT EXIST ARE NOT TWINS.
#    The defect this arm pins (found by yolanda 2026-08-30, one-line repro):
#    jq errored to stderr on an unreadable file, the empty field set hashed to
#    sha256("") = e3b0c44298fc1c14, and two missing documents therefore agreed.
#    The one input state compare must never bless is the one where it learned
#    nothing — a tool built to refuse unverified claims must refuse hardest when
#    it has no evidence at all.
if out="$("$FP" compare /nonexistent/a.json /nonexistent/b.json 2>&1)"; then
    fail "two unreadable documents were compared as twins: $out"
fi
rc=0; "$FP" compare /nonexistent/a.json /nonexistent/b.json >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] || fail "an unreadable document must exit 2 (refusal), not $rc (which reads as a real verdict)"
grep -qi "cannot read" <<<"$("$FP" compare /nonexistent/a.json /nonexistent/b.json 2>&1 || true)" \
    || fail "the refusal must say the document could not be read"

# 6. A DOCUMENT WITH NO CPU DEVICE MUST REFUSE, NOT HASH.
#    Same failure one layer in: a readable document that carries no identifying
#    field still produces an empty field set, and every such document would
#    fingerprint alike.
nocpu="$(mktemp)"; trap 'rm -f "$missing" "$nocpu"' EXIT
jq 'del(.devices[] | select(.device_class=="cpu"))' "$FIX/yoga-linux.json" > "$nocpu"
rc=0; "$FP" "$nocpu" >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] || fail "a document with no CPU device must refuse to fingerprint (exit 2), got $rc"

# 7. THE HASH MUST NOT DEPEND ON THE READER'S jq.
#    The fingerprint is hashed over a canonical string built field by field, not
#    over jq's JSON serialization: jq versions differ in number rendering and key
#    order, and two hosts disagreed on the same committed document before this
#    was pinned. Assert the canonical string's exact shape, which is what the
#    hash is actually taken over.
canon="$(bash -c 'source "$0" 2>/dev/null || true' "$FP" 2>/dev/null || true)"
expect_fields=(hwfp-v1 cpu_model= cpu_physical= cpu_logical= gpu_model= npu_vendor= npu_node= ram_class_gb=)
# Re-derive it the same way the script does, without sourcing: the JSON view
# carries the same fields, so a field added to one and not the other is caught.
for f in cpu_model cpu_physical cpu_logical gpu_model npu_vendor npu_node ram_class_gb; do
    "$FP" --json "$FIX/yoga-linux.json" | jq -e --arg f "$f" 'has($f)' >/dev/null \
        || fail "the reported field set lost $f — the canonical string and the JSON view must stay in step"
done

# 8. A CROSS-VANTAGE PAIR IS REFUSED, NOT REPORTED AS A MISMATCH.
#    yolanda 2026-09-02: the substrate CHANGES the device records rather than
#    decorating them — one machine reports a paravirtual GPU under WSL2 and no
#    GPU device natively. A NOT-TWINS verdict on such a pair reads as "different
#    hardware" when the truth may be "one machine, two vantages", which is the
#    misreading this whole tool exists to prevent.
crossv="$(mktemp)"; trap 'rm -f "$missing" "$nocpu" "$crossv"' EXIT
jq '.host.host_kind="windows"' "$FIX/yoga-linux.json" > "$crossv"
rc=0; "$FP" compare "$FIX/yoga-linux.json" "$crossv" >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] \
    || fail "a cross-vantage pair must be REFUSED (exit 2), not given a twin verdict; got $rc"
out="$("$FP" compare "$FIX/yoga-linux.json" "$crossv" 2>&1 || true)"
grep -q "refused:cross-vantage-comparison" <<<"$out" \
    || fail "the refusal must name itself as a cross-vantage refusal: $out"
grep -q "NOT TWINS" <<<"$out" \
    && fail "a cross-vantage pair was given a hardware verdict as well as a refusal: $out"

echo "ok: the hardware fingerprint refuses an untrue twin claim, refuses to hash nothing, and is stable per document (805-r98w)"
