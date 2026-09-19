#!/usr/bin/env bash
# @trace spec:vsock-transport
#
# test-vsock-seccomp-derivation.sh — order 830-xsk2.
#
# Guards scripts/derive-vsock-seccomp.sh, which emits podman's default seccomp
# profile with exactly one change: the rule denying socket(AF_VSOCK) flipped to
# allow. The forwarder container that bridges the macOS VM boundary needs that
# one allowance; nothing else may move.
#
# THE CLAIM THIS FIXTURE HAS TO DISCRIMINATE is not "AF_VSOCK works" — that is
# equally true of `seccomp=unconfined`, which is precisely the thing not to
# ship. It is "AF_VSOCK works AND everything the default denied is still
# denied". So the runtime arms form a 2x3 matrix over two socket families and
# three profiles, and the fixture reds unless the derived column sits strictly
# between the other two. MEASURED in the live guest 2026-09-19:
#
#                    NETLINK_AUDIT        AF_VSOCK
#     DEFAULT        DENIED errno=22      DENIED errno=1
#     DERIVED        DENIED errno=22      CREATED
#     UNCONFINED     CREATED              CREATED
#
# NETLINK_AUDIT is the negative probe on purpose: podman's default ERRNOs it
# without CAP_AUDIT_WRITE, and ATTEMPTING it needs no capability, so it
# separates the filter from the capability set. Two earlier candidates were
# discarded for failing exactly that test — `unshare -U` succeeded under all
# three profiles and `swapon` failed identically under all three, so neither
# distinguished anything. A control that does not discriminate is not a weaker
# control; it is not a control.
#
# GRAMMAR — exactly one line:
#   ^(ok:vsock-seccomp-derivation:[0-9]+|violation:vsock-seccomp-derivation:.*|unsupported:vsock-seccomp-derivation:.*)$
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVE="$ROOT/scripts/derive-vsock-seccomp.sh"
pass=0
fail=0
note() { printf '  %s\n' "$1" >&2; }
ck() { # ck <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then note "ok   $1"; pass=$((pass+1))
    else note "FAIL $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi
}

[ -x "$DERIVE" ] || { echo "violation:vsock-seccomp-derivation:no-derive-script"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "unsupported:vsock-seccomp-derivation:no-python3"; exit 0; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/vsock-seccomp-fixture.XXXXXX")" || {
    echo "violation:vsock-seccomp-derivation:cannot-mktemp"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

# ---- ARM A: the refusals. These run on EVERY host and need no podman. -------
# A profile emitted for an input nobody verified is worse than none, because it
# reads as one — so each of these must refuse rather than emit.
ck "refuses an unreadable input" \
   "violation:vsock-seccomp:input-unreadable:$TMPD/absent.json" \
   "$("$DERIVE" "$TMPD/absent.json" "$TMPD/out.json" 2>/dev/null)"

printf 'not json at all\n' > "$TMPD/bad.json"
ck "refuses a malformed profile" \
   "violation:vsock-seccomp:input-not-a-seccomp-profile" \
   "$("$DERIVE" "$TMPD/bad.json" "$TMPD/out.json" 2>/dev/null)"

printf '%s\n' '{"defaultAction":"SCMP_ACT_ERRNO","syscalls":[{"names":["read"],"action":"SCMP_ACT_ALLOW"}]}' > "$TMPD/norule.json"
ck "refuses a profile with no AF_VSOCK deny rule" \
   "violation:vsock-seccomp:no-af-vsock-deny-rule-podman-default-changed-shape" \
   "$("$DERIVE" "$TMPD/norule.json" "$TMPD/out.json" 2>/dev/null)"

# ---- ARM B: the structural claim, on a synthetic profile of known shape -----
# Exhaustive where a runtime probe can only sample: EVERY block is compared.
cat > "$TMPD/in.json" <<'JSON'
{"defaultAction":"SCMP_ACT_ERRNO",
 "syscalls":[
   {"names":["read"],"action":"SCMP_ACT_ALLOW"},
   {"names":["socket"],"action":"SCMP_ACT_ERRNO","errnoRet":1,"errno":"EPERM",
    "args":[{"index":0,"value":40,"valueTwo":0,"op":"SCMP_CMP_EQ"}]},
   {"names":["socket"],"action":"SCMP_ACT_ERRNO","errnoRet":22,"errno":"EINVAL",
    "args":[{"index":0,"value":16,"valueTwo":0,"op":"SCMP_CMP_EQ"},
            {"index":2,"value":9,"valueTwo":0,"op":"SCMP_CMP_EQ"}]}]}
JSON
ck "emits on a well-formed profile" "ok:vsock-seccomp:derived" \
   "$("$DERIVE" "$TMPD/in.json" "$TMPD/derived.json" 2>/dev/null)"

# Written to a file rather than heredoc'd inside $( ), which bash 3.2 — this
# fleet's dialect floor and what macOS ships — cannot parse.
cat > "$TMPD/structural.py" <<'PY'
import json, os
a = json.load(open(os.environ["IN"]));  b = json.load(open(os.environ["OUT"]))
sa, sb = a["syscalls"], b["syscalls"]
if len(sa) != len(sb):                      print("block-count-changed"); raise SystemExit
diff = [i for i in range(len(sa)) if sa[i] != sb[i]]
if len(diff) != 1:                          print("blocks-differing=%d" % len(diff)); raise SystemExit
i = diff[0]
if sa[i]["names"] != sb[i]["names"]:        print("names-changed"); raise SystemExit
if sa[i].get("args") != sb[i].get("args"):  print("args-changed"); raise SystemExit
if sb[i]["action"] != "SCMP_ACT_ALLOW":     print("action-not-allow"); raise SystemExit
# crun REFUSES a block carrying an errno value under SCMP_ACT_ALLOW outright, so
# stripping these is load-bearing, not tidiness. Measured: every container using
# a profile that kept them failed to start with
# "errno value specified for action SCMP_ACT_ALLOW" — while the JSON stayed
# perfectly well-formed, which is why this is asserted and not eyeballed.
if "errnoRet" in sb[i] or "errno" in sb[i]: print("errno-fields-retained"); raise SystemExit
# The AF_NETLINK/NETLINK_AUDIT deny must be untouched — it is the fixture's
# runtime negative probe, and a derivation that relaxed it would still pass a
# test that only looked at AF_VSOCK.
other = [x for j, x in enumerate(sb) if j != i and "socket" in x.get("names", [])]
if any(x["action"] != "SCMP_ACT_ERRNO" for x in other): print("other-socket-rule-relaxed"); raise SystemExit
print("one-block-action-only")
PY
structural="$(IN="$TMPD/in.json" OUT="$TMPD/derived.json" python3 "$TMPD/structural.py")"
ck "changes exactly one block, action and errno fields only" "one-block-action-only" "$structural"

# ---- ARM C: the runtime matrix. Needs podman and an image with python3. -----
runtime_arms=0
if command -v podman >/dev/null 2>&1 && [ -r /usr/share/containers/seccomp.json ]; then
    IMG="${TILLANDSIAS_VSOCK_PROBE_IMAGE:-$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
         | grep tillandsias-forge-base | grep -v ':latest' | grep -v ':sha256-' | head -1)}"
    if [ -n "$IMG" ] && podman image exists "$IMG" 2>/dev/null; then
        "$DERIVE" /usr/share/containers/seccomp.json "$TMPD/live.json" >/dev/null 2>&1
        CODE='import socket
try:
    s=socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 9); print("NL:CREATED"); s.close()
except OSError: print("NL:DENIED")
try:
    v=socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM); print("VS:CREATED"); v.close()
except OSError: print("VS:DENIED")'
        probe() { # probe <extra-flags>
            podman run --rm --cap-drop=ALL --security-opt=no-new-privileges $1 \
                --entrypoint python3 "$IMG" -c "$CODE" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
        }
        ck "DEFAULT denies both"            "NL:DENIED VS:DENIED"   "$(probe "")"
        ck "DERIVED allows only AF_VSOCK"   "NL:DENIED VS:CREATED"  "$(probe "--security-opt seccomp=$TMPD/live.json")"
        ck "UNCONFINED allows both (control proves the probe can see a difference)" \
                                            "NL:CREATED VS:CREATED" "$(probe "--security-opt seccomp=unconfined")"
        runtime_arms=3
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "violation:vsock-seccomp-derivation:$fail-arm(s)-failed"
    exit 1
fi
if [ "$runtime_arms" -eq 0 ]; then
    # Say which half was skipped rather than report a bare green: the refusal and
    # structural arms cannot tell you crun will accept the file.
    echo "unsupported:vsock-seccomp-derivation:structural-only-no-podman-or-probe-image"
    exit 0
fi
echo "ok:vsock-seccomp-derivation:$pass"
