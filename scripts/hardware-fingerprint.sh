#!/usr/bin/env bash
# ORDER 805-r98w — derive a comparable HARDWARE FINGERPRINT from the capability
# document, so two hosts can be shown identical rather than asserted identical.
#
# WHY: fleet accel findings are confounded — hosts differ in hardware AND OS AND
# container substrate at once, so a disagreement about whether the NPU is usable
# attributes to nothing. A same-hardware pair removes the confound and leaves the
# substrate as the only free variable. But a control you cannot VERIFY is not a
# control, and the capability document carried no hardware identity: "these two
# hosts are the same machine" was an operator assertion a reader could not check.
#
# This derives that identity from fields the probe already collects. It answers
# "is this the same machine MODEL", not "is this the same installation", so it
# deliberately EXCLUDES kernel release, driver version, hostname, probe identity
# and every other field that differs legitimately between two same-model hosts.
#
# The `compare` mode exists to REFUSE a twin claim, not to bless one. That is the
# failure this packet was filed against, and on its first real use (2026-08-30,
# yoga vs yolanda) it refused: near-identical is not identical, and the GPU model
# string alone would have said "twin" because AMD ships Radeon 840M and 860M
# under ONE PCI name, "Krackan [Radeon 840M / 860M Graphics]". The CPU model is
# what separates them. A fingerprint built on the GPU name would have blessed a
# false control and every number keyed on it would have inherited the difference.
#
# Usage:
#   scripts/hardware-fingerprint.sh [--json] [<capabilities.json>]
#   scripts/hardware-fingerprint.sh compare <a.json> <b.json>
#
# With no file argument it runs the installed tray's `--capabilities` and uses
# that. Reads only; writes nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_fail() { echo "$*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || _fail "hardware-fingerprint: jq is required"

# Capability document -> the fields that identify the MACHINE MODEL.
#
# RAM is rounded to a CLASS, not recorded exactly: the same machine model
# reports a slightly different total depending on how much firmware reserved,
# and an exact byte count would make a host differ from itself across a BIOS
# update. Cores are exact — a core-count difference IS a different part.
_capture() {
    local doc="$1"
    jq -r '
      def dev($c): (.devices[]? | select(.device_class == $c)) // empty;
      def first_name($c): [dev($c) | .name] | (.[0] // "none");
      def first_node($c): [dev($c) | .device_node] | (.[0] // "none");
      {
        cpu_model:      (first_name("cpu")),
        cpu_physical:   ([dev("cpu") | .cpu_cores.physical] | (.[0] // 0)),
        cpu_logical:    ([dev("cpu") | .cpu_cores.logical]  | (.[0] // 0)),
        # gpu_model IS A WEAK DISCRIMINATOR — trust it less than it looks.
        # AMD ships the Radeon 840M and the 860M under ONE PCI name,
        # "Krackan [Radeon 840M / 860M Graphics]", so two genuinely different
        # parts produce an identical string here and this field alone would
        # call them the same machine. It is in the fingerprint because it
        # separates machines whose GPUs differ by more than a bin; it is not
        # in it because a match means anything on its own. When two hosts
        # agree on gpu_model, the CPU fields are what actually decided.
        #
        # WORSE ACROSS PLATFORMS: the field is not merely weak, it is
        # INCOMMENSURABLE. Two Linux hosts here both report "Krackan [...]",
        # the same machine probed inside WSL2 reports "WSL2 paravirtual GPU
        # (/dev/dxg)" — the PATH, not the silicon — and probed natively on
        # Windows reports "none" on a machine that has a Radeon. Comparing this
        # field between a Linux and a Windows document compares two different
        # kinds of fact, and a mismatch there is not evidence of different
        # hardware.
        gpu_model:      (first_name("gpu")),
        npu_vendor:     ([dev("npu") | .vendor] | (.[0] // "none")),
        npu_node:       (first_node("npu")),
        ram_class_gb:   ((([.devices[]? | .memory_mib // empty] | add) // 0)),
      }
    ' "$doc"
}

# RAM class comes from the accel line rather than the device list (the probe
# records host RAM outside devices[]), rounded DOWN to a 4 GB class.
_ram_class_gb() {
    local doc="$1" gb
    gb="$(jq -r '.host.ram_gb // empty' "$doc")"
    if [[ -z "$gb" || "$gb" == "null" ]]; then
        # DOCUMENT-ONLY, deliberately. Not every probe version records host RAM,
        # and the tempting fallback — read /proc/meminfo — is wrong twice over:
        # for a document another host handed us it is a different machine's
        # number, and even for our own document it makes the SAME document
        # fingerprint differently depending on where it is read, so a host would
        # fail to match its own committed capability document. An honest
        # "unknown" costs one discriminating field; a borrowed number blesses a
        # false twin, which is the failure this packet exists to prevent.
        #
        # Restoring RAM as a discriminator means recording it in the probe
        # (accel_probe.rs, owned elsewhere today) — filed rather than reached
        # around from here.
        echo "unknown"
        return 0
    fi
    # Rounded to a 4 GB CLASS, not recorded exactly: the same machine model
    # reports a slightly different total depending on how much firmware
    # reserved, and an exact figure would make a host differ from itself across
    # a BIOS update.
    echo "$(( (gb / 4) * 4 ))-$(( ((gb / 4) * 4) + 4 ))"
}

_fields_json() {
    local doc="$1"
    local base ram
    base="$(_capture "$doc")"
    ram="$(_ram_class_gb "$doc")"
    echo "$base" | jq --arg ram "$ram" '.ram_class_gb = $ram'
}

# The hash is taken over a canonical string WE build, field by field in a fixed
# order, not over jq's JSON serialization. jq versions differ in how they render
# numbers and order keys, and a fingerprint that changes with the reader's jq is
# not a fingerprint — yolanda's jq and mine disagreed on the same committed
# document, which is how this was caught (2026-08-30).
#
# FINGERPRINT_SCHEMA is part of the hashed string on purpose: if the field set
# ever changes, every fingerprint changes with it, so an old value can never be
# silently compared against a new one.
FINGERPRINT_SCHEMA="hwfp-v1"

_canonical_string() {
    local doc="$1" fields
    fields="$(_fields_json "$doc")"
    local cpu_model cpu_physical cpu_logical gpu_model npu_vendor npu_node ram
    cpu_model="$(jq -r '.cpu_model' <<<"$fields")"
    cpu_physical="$(jq -r '.cpu_physical' <<<"$fields")"
    cpu_logical="$(jq -r '.cpu_logical' <<<"$fields")"
    gpu_model="$(jq -r '.gpu_model' <<<"$fields")"
    npu_vendor="$(jq -r '.npu_vendor' <<<"$fields")"
    npu_node="$(jq -r '.npu_node' <<<"$fields")"
    ram="$(jq -r '.ram_class_gb' <<<"$fields")"

    # A DOCUMENT THAT TAUGHT US NOTHING MUST NOT FINGERPRINT.
    # Without this, two unreadable files both produce an empty field set, hash
    # to sha256("") and COMPARE AS TWINS — the one input state compare must
    # never bless is the one where it learned nothing. Reported by yolanda
    # 2026-08-30 with a one-line repro; it is the vacuous-test failure landing
    # inside the tool built to prevent it.
    if [[ "$cpu_model" == "none" || -z "$cpu_model" ]]; then
        _fail "hardware-fingerprint: $doc carries no CPU device — there is nothing to fingerprint, and an empty field set would compare equal to any other empty one. Refusing rather than returning a hash."
    fi

    printf '%s\ncpu_model=%s\ncpu_physical=%s\ncpu_logical=%s\ngpu_model=%s\nnpu_vendor=%s\nnpu_node=%s\nram_class_gb=%s\n' \
        "$FINGERPRINT_SCHEMA" "$cpu_model" "$cpu_physical" "$cpu_logical" \
        "$gpu_model" "$npu_vendor" "$npu_node" "$ram"
}

_fingerprint_of() {
    local doc="$1"
    _canonical_string "$doc" | sha256sum | cut -c1-16
}

_resolve_doc() {
    local arg="${1:-}"
    if [[ -n "$arg" ]]; then
        [[ -r "$arg" ]] || _fail "hardware-fingerprint: cannot read $arg"
        printf '%s' "$arg"
        return 0
    fi
    local bin=""
    for candidate in "${TILLANDSIAS_INSTALLED_BIN:-}" "$HOME/.local/bin/tillandsias" "$(command -v tillandsias 2>/dev/null || true)"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then bin="$candidate"; break; fi
    done
    [[ -n "$bin" ]] || _fail "hardware-fingerprint: no capability document given and no installed tillandsias to ask"
    local tmp
    tmp="$(mktemp)"
    # The tray prints the one-line accel summary first, then the JSON document.
    "$bin" --capabilities 2>/dev/null | tail -n +2 > "$tmp" || _fail "hardware-fingerprint: --capabilities failed"
    jq -e . "$tmp" >/dev/null 2>&1 || _fail "hardware-fingerprint: --capabilities did not produce a JSON document"
    printf '%s' "$tmp"
}

case "${1:-}" in
compare)
    [[ $# -eq 3 ]] || _fail "usage: hardware-fingerprint.sh compare <a.json> <b.json>"
    a="$2"; b="$3"
    # Check BOTH documents before comparing. A missing file used to reach the
    # hash as an empty field set, and two missing files then compared as twins.
    for _d in "$a" "$b"; do
        [[ -r "$_d" ]] || _fail "hardware-fingerprint: cannot read $_d — refusing to compare, an absent document is not evidence of anything"
        jq -e . "$_d" >/dev/null 2>&1 || _fail "hardware-fingerprint: $_d is not a readable JSON capability document — refusing to compare"
    done
    # ORDER 805-r98w — REFUSE A CROSS-VANTAGE COMPARISON RATHER THAN REPORT A
    # MISMATCH. yolanda's finding, 2026-09-02: the substrate does not merely
    # decorate the device records, it CHANGES them. One machine reports
    # "WSL2 paravirtual GPU (/dev/dxg)" under WSL2 and NO gpu device at all
    # natively. So two documents whose host_kind differs may be one machine seen
    # two ways, and a NOT-TWINS verdict there reads as "different hardware" when
    # the truth is "different vantage" — the exact misreading this tool exists to
    # prevent, arriving through the tool itself.
    #
    # This is not a mismatch to report, it is a comparison that cannot be made.
    _ka="$(jq -r '.host.host_kind // "unknown"' "$a" 2>/dev/null)"
    _kb="$(jq -r '.host.host_kind // "unknown"' "$b" 2>/dev/null)"
    if [[ "$_ka" != "$_kb" ]]; then
        echo "refused:cross-vantage-comparison"
        echo "  $a is host_kind=$_ka; $b is host_kind=$_kb." >&2
        echo "  The substrate CHANGES the device records — the same machine reports a" >&2
        echo "  paravirtual GPU under WSL2 and no GPU device natively — so a verdict here" >&2
        echo "  cannot distinguish different hardware from one machine seen two ways." >&2
        echo "  Compare documents taken from the same vantage, or fix the probe first." >&2
        exit 2
    fi

    fa="$(_fingerprint_of "$a")" || exit 2
    fb="$(_fingerprint_of "$b")" || exit 2
    [[ -n "$fa" && -n "$fb" ]] || _fail "hardware-fingerprint: refusing to compare an empty fingerprint"
    if [[ "$fa" == "$fb" ]]; then
        echo "twin: both documents fingerprint $fa — same machine model, so a difference between these hosts isolates the substrate"
        exit 0
    fi
    echo "NOT TWINS: $a fingerprints $fa, $b fingerprints $fb"
    echo ""
    echo "The hosts differ in these identifying fields:"
    diff <(_fields_json "$a" | jq -S .) <(_fields_json "$b" | jq -S .) | sed 's/^/  /' || true
    echo ""
    echo "A comparison between these two hosts does NOT isolate the OS or the"
    echo "container substrate: any delta bundles the hardware difference above."
    echo "Do not key a tier matrix on this pair as a control (805-r98w)."
    exit 1
    ;;
--json)
    doc="$(_resolve_doc "${2:-}")"
    # Compute the hash into a variable FIRST. Inlining it as $(...) runs _fail in
    # a subshell, whose exit does not stop this one — the refusal was printed and
    # sha256("") was then reported as the fingerprint anyway. Same class of bug as
    # the one this refusal exists to prevent, one layer out.
    fp="$(_fingerprint_of "$doc")" || exit 2
    [[ -n "$fp" ]] || _fail "hardware-fingerprint: refusing to report an empty fingerprint"
    _fields_json "$doc" | jq --arg fp "$fp" '{fingerprint: $fp} + .'
    ;;
*)
    doc="$(_resolve_doc "${1:-}")"
    fp="$(_fingerprint_of "$doc")" || exit 2
    [[ -n "$fp" ]] || _fail "hardware-fingerprint: refusing to report an empty fingerprint"
    printf '%s\n' "$fp"
    ;;
esac
