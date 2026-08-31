#!/usr/bin/env bash
# Emit this Windows machine's capability contribution, observed from the
# WINDOWS HOST locus (orders 806-2r4s, 809-7e4m, 808-7yrd).
#
# WHY THIS EXISTS AT ALL, because it looks like duplication of the in-guest
# probe and is not. On Windows a single machine is observed from two execution
# contexts and NEITHER sees the whole machine:
#
#   the WSL2 guest sees  cpu, and the paravirtual gpu via /dev/dxg
#   only Windows sees    the NPU, the true GPU name, and the real RAM
#
# The NPU is not merely undetected in the guest, it is STRUCTURALLY invisible:
# WSL2 paravirtualises the graphics adapter and passes through no PCI, so
# /dev/accel* is absent, amdxdna is not in /proc/modules, and no device matches
# 1022:17f0. No amount of in-guest probing will ever find it (809-7e4m). A row
# assembled from one context is not merely incomplete, it is confidently wrong
# in a way a consumer cannot detect.
#
# The RAM difference makes the same point in one number: the guest reports its
# VM slice (~7.3 GB) while the machine has ~15.2 GB. A scheduler sizing a model
# against the guest's figure is not slightly off, it is answering a different
# question.
#
# Output is a CapabilityDocument on stdout, or with --fragment a ready-to-file
# `capabilities:` ledger row carrying `locus: windows-host`. That locus is half
# the matrix fold key: without it this contribution would OVERWRITE the guest's
# row for the same host_id rather than sitting beside it (808-7yrd).
#
# NOT a replacement for the in-guest probe. Both rows are contributed; the
# consumer assembles them. This one deliberately reports no CPU: the guest
# already reports it, and two contexts disagreeing about the same device is a
# reconciliation problem nobody needs.

set -eu


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

usage() {
    cat <<'USAGE'
usage: windows-host-capability-probe.sh [--fragment] [--host-id ID] [--ts ISO8601]

  --fragment   emit a `capabilities:` ledger row instead of a bare document
  --host-id    override the derived machine name (default: short hostname,
               lowercased -- the same identifier that names
               plan/mo-full-attestations.d/<host>.md)
  --ts         override the timestamp (default: now, UTC)

Reads nothing and writes nothing; the document goes to stdout.
USAGE
}

EMIT_FRAGMENT=0
HOST_ID=""
TS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --fragment) EMIT_FRAGMENT=1 ;;
        --host-id) shift; HOST_ID="${1:-}" ;;
        --ts) shift; TS="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

for tool in powershell.exe jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool is required and was not found on PATH" >&2
        exit 3
    fi
done

# THE chain from scripts/agent-identity.sh, sourced rather than restated
# (order 859-b2zc). The matrix fold key and the attestation ledger's filename
# must be the same string (808-43mw), and the only way to guarantee that is to
# call the same function -- this block used to say "same chain as
# agent-identity.sh" above a private copy of it, which is how the copies get
# made. The copy here even worked, because Git Bash ships `hostname`; the
# sibling copy in check-capability-row.sh did not, because no Fedora image
# does, and it silenced the forge for as long as that gate has existed.
# tillandsias_node_name domain-strips and lowercases with builtins.
if [ -z "$HOST_ID" ]; then
    _ai_dir="${BASH_SOURCE[0]%/*}"
    [ "$_ai_dir" = "${BASH_SOURCE[0]}" ] && _ai_dir=.
    # shellcheck source=scripts/agent-identity.sh
    . "$_ai_dir/agent-identity.sh"
    HOST_ID="$(tillandsias_node_name)"
    [ -n "$HOST_ID" ] || HOST_ID=unknown
fi
[ -n "$TS" ] || TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# One PowerShell invocation, emitting JSON directly. Deliberately not several:
# each launch costs ~200ms and a partial failure across three would leave the
# document half-observed with nothing saying which half.
#
# THE DEVICE FILTER IS A CLASS, NEVER A NAME REGEX. Filtering NPUs with a
# /NPU/ pattern silently matches every USB "I-npu-t Device" on the machine
# (measured 2026-08-18: four HID devices matched). Phantom NPUs in the fleet
# matrix would be worse than none, because a scheduler would believe them.
# `Class -eq 'ComputeAccelerator'` is the stable, exact signal.
PS_JSON="$(powershell.exe -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
$npus = @(Get-PnpDevice -PresentOnly | Where-Object { $_.Class -eq "ComputeAccelerator" })
$gpus = @(Get-PnpDevice -PresentOnly | Where-Object { $_.Class -eq "Display" })
function DriverVersion($id) {
    try { (Get-PnpDeviceProperty -InstanceId $id -KeyName "DEVPKEY_Device_DriverVersion").Data }
    catch { $null }
}
$out = [ordered]@{
    ram_bytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    os_version = [string](Get-CimInstance Win32_OperatingSystem).Version
    npus = @($npus | ForEach-Object {
        [ordered]@{ name = $_.FriendlyName; status = $_.Status
                    instance_id = $_.InstanceId; driver = (DriverVersion $_.InstanceId) } })
    gpus = @($gpus | ForEach-Object {
        [ordered]@{ name = $_.FriendlyName; status = $_.Status
                    instance_id = $_.InstanceId; driver = (DriverVersion $_.InstanceId) } })
}
$out | ConvertTo-Json -Depth 6 -Compress
' 2>/dev/null)" || {
    echo "error: the Windows device query failed" >&2
    exit 4
}

if [ -z "$PS_JSON" ]; then
    echo "error: the Windows device query returned nothing" >&2
    exit 4
fi

# STATUS=OK IS REPORTED, AND SEPARATELY FROM USABILITY. A device Windows calls
# healthy is still unusable BY US, because every engine this project ships runs
# inside the guest and the guest cannot reach these devices. Those are different
# facts and collapsing them is exactly the present-unusable contract violation
# 806-2r4s names: "absent" and "present but unreachable" are different
# engineering problems ("buy hardware" versus "ship a lane").
#
# The two reason strings are the fleet's existing vocabulary, not new terms.
DOC="$(printf '%s' "$PS_JSON" | "$JQ" -c \
    --arg host_id "$HOST_ID" \
    --arg ts "$TS" \
    '
    def dev($class; $reason): {
        device_class: $class,
        vendor: (if (.instance_id // "") | test("VEN_1022") then "amd"
                 elif (.instance_id // "") | test("VEN_1002") then "amd"
                 elif (.instance_id // "") | test("VEN_8086") then "intel"
                 elif (.instance_id // "") | test("VEN_10DE") then "nvidia"
                 else "unknown" end),
        name: (.name // "unknown"),
        device_node: (.instance_id // null),
        fw_version: null,
        driver: (.driver // null),
        usable: false,
        unusable_reason: $reason,
        lanes: [],
        memory_bandwidth_gbps: null,
        memory_bandwidth_source: "unknown",
        cpu_flags: null,
        cpu_cores: null,
        system_ram_gb: null,
        os_status: (.status // "unknown")
    };
    {
      schema_version: 2,
      legacy_tier: "cpu",
      devices: (
        [ .npus[] | dev("npu"; "wsl2-npu-not-exposed") ]
        + [ .gpus[] | dev("gpu"; "wsl2-no-dri-render-node") ]
      ),
      engines: [],
      measurements: [],
      host: {
        is_battery_present: true,
        kernel_release: (.os_version // "unknown"),
        host_id: $host_id,
        host_id_source: "node-name",
        host_kind: "windows",
        system_ram_gb: ((.ram_bytes // 0) / 1073741824)
      },
      timestamp: $ts
    }')"

if [ "$EMIT_FRAGMENT" -eq 0 ]; then
    printf '%s\n' "$DOC" | "$JQ" .
    exit 0
fi

# A ledger row, ready to drop into plan/index.d/. `locus` is mandatory: without
# it the fold refuses the row rather than letting it collide with the guest's
# contribution for the same machine (808-7yrd).
cat <<HEADER
# Ledger fragment -- append-only, IMMUTABLE once written.
# Generated by scripts/windows-host-capability-probe.sh at $TS.
#
# The WINDOWS-HOST half of this machine's capability row. The guest half is
# contributed separately with locus: in-guest; the two are keyed apart and a
# consumer assembles them (809-7e4m).

capabilities:
  - ts: "$TS"
    host: windows
    locus: windows-host
    document:
HEADER
printf '%s\n' "$DOC" | "$JQ" . | sed 's/^/      /'
