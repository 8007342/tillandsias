#!/usr/bin/env bash
# @trace spec:vsock-transport
#
# derive-vsock-seccomp.sh — order 830-xsk2.
#
# Emit podman's default seccomp profile with EXACTLY ONE change: the rule that
# denies `socket(AF_VSOCK, ...)` is flipped from deny to allow. Nothing else in
# the filter moves.
#
# WHY THIS EXISTS. Measured in the live guest 2026-09-14, four arms varying only
# podman flags: with /dev/vsock present inside the container, AF_VSOCK socket
# creation is STILL refused; with seccomp relaxed and NO device passed, the
# socket is created and the connect reaches CID 2. So the device is not the
# barrier — the filter is. The one rule responsible, read from the installed
# default on this fleet's guest:
#
#   {"names":["socket"], "action":"SCMP_ACT_ERRNO",
#    "args":[{"index":0,"value":40,"op":"SCMP_CMP_EQ"}]}      # 40 == AF_VSOCK
#
# WHY DERIVE RATHER THAN SHIP A COPY, which is the obvious alternative and the
# wrong one: a static fork of a 17,705-byte vendor profile silently stops
# tracking podman's default the day podman updates it. The container would keep
# running a filter that looks maintained and is not — and a stale ALLOW list is
# exactly the failure nobody notices. Deriving costs one file read and means the
# forwarder always runs the platform's current default plus one allowance.
#
# WHY NOT seccomp=unconfined, which was the right instrument to ISOLATE the
# cause and is the wrong one to fix it: it disables the whole filter to permit
# one socket family, on a container that exists to bridge the VM boundary. The
# allowance here is scoped to the dedicated forwarder container; every agent
# container stays on the untouched default.
#
# FAIL-LOUD: if the expected deny rule is absent, this REFUSES rather than
# emitting a profile. An absent rule means either podman's default changed shape
# or the input is not that default, and in both cases a silently-emitted profile
# would be a filter nobody verified — which is worse than no profile, because it
# reads as one.
#
# GRAMMAR — exactly one line on stdout when emitting to a file:
#   ^(ok:vsock-seccomp:[a-z0-9-]+|violation:vsock-seccomp:.*|unsupported:vsock-seccomp:.*)$
set -uo pipefail

IN="${1:-/usr/share/containers/seccomp.json}"
OUT="${2:-}"

command -v python3 >/dev/null 2>&1 || {
    echo "unsupported:vsock-seccomp:no-python3"
    exit 0
}
[ -r "$IN" ] || {
    echo "violation:vsock-seccomp:input-unreadable:$IN"
    exit 1
}

# The derivation is written to a temp file and run from there rather than fed
# through a heredoc inside $( ), which BASH 3.2 — this fleet's dialect floor,
# and what macOS ships — cannot parse. Caught by `bash -n` on this host.
# `mktemp -t NAME` is the BSD form and GNU coreutils refuses it ("too few X's
# in template") — caught by running this in the Linux guest, which is the only
# place it will ever actually run. Spell the template explicitly so the same
# file works on both, since this script is authored and linted on macOS.
_PY="$(mktemp "${TMPDIR:-/tmp}/vsock-seccomp-derive.XXXXXX")" || {
    echo "violation:vsock-seccomp:cannot-mktemp"
    exit 1
}
trap 'rm -f "$_PY"' EXIT

cat > "$_PY" <<'PY'
import json, os, sys

AF_VSOCK = 40

src = os.environ["IN"]
try:
    prof = json.load(open(src))
except Exception as exc:                      # malformed JSON is a refusal, not a warning
    print("ERR:unparsable:%s" % type(exc).__name__, file=sys.stderr)
    sys.exit(3)

blocks = prof.get("syscalls")
if not isinstance(blocks, list):
    print("ERR:no-syscalls-array", file=sys.stderr)
    sys.exit(3)

def denies_vsock(b):
    # The rule we are looking for: a DENY on `socket` whose first argument is
    # compared EQUAL to AF_VSOCK. Matching on the argument rather than on the
    # block's index keeps this working when podman reorders its profile, which
    # a positional match would not survive.
    if "socket" not in b.get("names", []):
        return False
    if b.get("action") not in ("SCMP_ACT_ERRNO", "SCMP_ACT_KILL", "SCMP_ACT_TRAP"):
        return False
    for a in b.get("args", []) or []:
        if a.get("index") == 0 and a.get("value") == AF_VSOCK and a.get("op") == "SCMP_CMP_EQ":
            return True
    return False

hits = [i for i, b in enumerate(blocks) if denies_vsock(b)]
if not hits:
    print("ERR:no-af-vsock-deny-rule", file=sys.stderr)
    sys.exit(4)

for i in hits:
    b = blocks[i]
    b["action"] = "SCMP_ACT_ALLOW"
    # The errno fields MUST go with the action. crun refuses a block that
    # carries an errno value under SCMP_ACT_ALLOW outright:
    #   "OCI runtime error: crun: errno value specified for action SCMP_ACT_ALLOW"
    # Measured in the live guest 2026-09-19 — the derived JSON looked perfectly
    # well-formed and every container using it failed to start. A profile that
    # is valid JSON and invalid OCI is exactly the shape a file-shape check
    # would have passed, which is why this is verified by running a container
    # rather than by inspecting the output.
    b.pop("errnoRet", None)
    b.pop("errno", None)

# Record WHY this file differs from the vendor default, inside the artefact, so
# a reader who finds it on a running host does not have to diff 17KB to find
# out. The OCI seccomp schema ignores unknown top-level keys.
prof["tillandsiasDerivedFrom"] = src
prof["tillandsiasChange"] = (
    "order 830-xsk2: %d rule(s) denying socket(AF_VSOCK) flipped to SCMP_ACT_ALLOW; "
    "nothing else altered" % len(hits)
)
json.dump(prof, sys.stdout, indent=1, sort_keys=True)
PY

derived="$(IN="$IN" python3 "$_PY")"
rc=$?

if [ "$rc" -ne 0 ]; then
    case "$rc" in
        3) echo "violation:vsock-seccomp:input-not-a-seccomp-profile" ;;
        4) echo "violation:vsock-seccomp:no-af-vsock-deny-rule-podman-default-changed-shape" ;;
        *) echo "violation:vsock-seccomp:derivation-failed-rc-$rc" ;;
    esac
    exit 1
fi

if [ -z "$OUT" ]; then
    printf '%s\n' "$derived"
    exit 0
fi

printf '%s\n' "$derived" > "$OUT" || {
    echo "violation:vsock-seccomp:cannot-write:$OUT"
    exit 1
}
echo "ok:vsock-seccomp:derived"
