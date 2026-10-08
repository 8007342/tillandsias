#!/usr/bin/env bash
# @trace order:1506-euvq (change fleet-messaging-poc, Decision 6)
#
# Measures whether the Cloudflare One Client (cloudflare-warp) runs in WARP
# mode as a ROOTLESS sidecar sharing another container's network namespace,
# and prints the regime then exactly one outcome line as its LAST line:
#
#   outcome:mesh-ip-acquired | outcome:tun-denied-rootless |
#   outcome:firewall-refused | outcome:package-refuses-container |
#   outcome:registers-no-mesh-ip
#
# or, when no refusal fired and no mdm.xml was supplied, the explicit
# non-outcome line
#
#   outcome-pending:enrollment-required:<what the operator must provide>
#
# because the two remaining outcomes are facts about a registered client.
# This script NEVER logs in, never registers, never calls a Cloudflare API
# with credentials, and never writes mdm.xml: with --mdm it only bind-mounts
# a file the operator wrote. Its own network probe of Cloudflare is a bare
# TCP connect (no bytes sent) to a WARP edge address; note that warp-svc
# itself attempts unauthenticated pre-registration API requests at start
# whenever its namespace has egress.
#
# Usage:
#   scripts/research-warp-sidecar-rootless.sh --throwaway [--build] [--mdm FILE]
#       [--posture packet|repaired] [--owner-network internal|pasta]
#   scripts/research-warp-sidecar-rootless.sh --target tillandsias-router [--mdm FILE]
#
#   --throwaway   create a throwaway netns owner shaped like the router
#                 (alpine sleep, --cap-drop=ALL, no-new-privileges, keep-id,
#                 --read-only) and remove it, its network and every sidecar
#                 by exact name on exit. Never touches tillandsias-*.
#   --owner-network internal (default; a throwaway --internal bridge, the
#                 shape of tillandsias-enclave) | pasta (podman's default
#                 rootless network, which has egress).
#   --target NAME share NAME's network namespace (the packet's live run uses
#                 tillandsias-router; the script does not start or stop it).
#   --posture     packet (default): the flags 1506-euvq names —
#                   --userns=keep-id --user 0 --cap-drop=ALL
#                   --cap-add=NET_ADMIN --device /dev/net/tun
#                 repaired: the same, with --userns=container:<owner> in
#                 place of --userns=keep-id and --security-opt label=disable
#                 (the two changes this script's own arms show are needed).
#                 The kernel arms always run under BOTH postures; the
#                 posture picks which one the daemon runs under and which
#                 one decides the outcome.
#   --build       build images/warp first (tagged $WARP_IMAGE) and remove it
#                 on exit.
#   --mdm FILE    bind-mount FILE read-only at /var/lib/cloudflare-warp/mdm.xml
#                 and wait up to $WARP_WAIT_S seconds for registration and a
#                 100.96.0.0/12 address.
#
# Each arm prints `arm:<name> rc=<n>` with rc taken on its own line.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARP_IMAGE="${WARP_IMAGE:-localhost/tillandsias-warp-research:probe}"
WARP_WAIT_S="${WARP_WAIT_S:-60}"
PROBE_TAG="warp-research-$$"
OWNER_IMAGE="${OWNER_IMAGE:-docker.io/library/alpine:3.22}"
WARP_EDGE_V4="${WARP_EDGE_V4:-162.159.198.1}"

target=""
throwaway=0
do_build=0
mdm=""
posture_name="packet"
owner_network="internal"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --throwaway) throwaway=1 ;;
        --target) target="${2:?--target needs a container name}"; shift ;;
        --build) do_build=1 ;;
        --mdm) mdm="${2:?--mdm needs a file}"; shift ;;
        --posture) posture_name="${2:?--posture needs packet|repaired}"; shift ;;
        --owner-network) owner_network="${2:?--owner-network needs internal|pasta}"; shift ;;
        -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$posture_name" in packet|repaired) ;; *) echo "refused: --posture $posture_name" >&2; exit 2 ;; esac
case "$owner_network" in internal|pasta) ;; *) echo "refused: --owner-network $owner_network" >&2; exit 2 ;; esac
if [ "$throwaway" -eq 0 ] && [ -z "$target" ]; then
    echo "refused: pass --throwaway or --target <container>" >&2
    exit 2
fi
if [ -n "$mdm" ] && [ ! -r "$mdm" ]; then
    echo "refused: --mdm $mdm is not readable" >&2
    exit 2
fi

OUT="$(mktemp -d "${TMPDIR:-/tmp}/warp-research.XXXXXX")"
created_containers=()
created_network=""
created_volume=""

cleanup() {
    local i
    # Reverse creation order: podman refuses to remove the netns owner while
    # a sidecar still joins its namespace (measured: two owners leaked on the
    # pasta runs before this loop was reversed).
    for ((i = ${#created_containers[@]} - 1; i >= 0; i--)); do
        podman rm -f -t 0 "${created_containers[$i]}" >/dev/null 2>&1
    done
    if [ -n "$created_volume" ]; then
        podman volume rm -f "$created_volume" >/dev/null 2>&1
    fi
    if [ -n "$created_network" ]; then
        podman network rm -f "$created_network" >/dev/null 2>&1
    fi
    if [ "$do_build" -eq 1 ]; then
        podman rmi -f "$WARP_IMAGE" >/dev/null 2>&1
    fi
}
trap cleanup EXIT

outcome=""
set_outcome() {
    # First refusal wins; later arms only add evidence.
    if [ -z "$outcome" ]; then outcome="$1"; fi
}

arm() {
    # arm <name> <command...>: run, record rc on its own line, keep output.
    local name="$1"; shift
    "$@" >"$OUT/$name.out" 2>&1
    local rc=$?
    echo "arm:$name rc=$rc"
    sed 's/^/    /' "$OUT/$name.out" | head -n 40
    return "$rc"
}

# ---- regime -------------------------------------------------------------
echo "regime:host=$(hostname)"
echo "regime:kernel=$(uname -r)"
echo "regime:podman=$(podman version --format '{{.Client.Version}}' 2>/dev/null)"
echo "regime:rootless=$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)"
echo "regime:selinux=$(getenforce 2>/dev/null || echo unknown)"
echo "regime:dev-net-tun=$(stat -c '%A %t,%T' /dev/net/tun 2>/dev/null || echo absent)"
echo "regime:posture=$posture_name"

if [ "$do_build" -eq 1 ]; then
    arm build podman build -t "$WARP_IMAGE" "$REPO_ROOT/images/warp"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "evidence-dir:$OUT"
        echo "outcome:package-refuses-container"
        exit 0
    fi
fi

client_version="$(podman run --rm --entrypoint /usr/bin/warp-cli "$WARP_IMAGE" --version 2>/dev/null)"
echo "regime:client=${client_version:-unknown}"
if [ -z "$client_version" ]; then
    echo "evidence-dir:$OUT"
    echo "outcome:package-refuses-container"
    exit 0
fi

# ---- netns owner ----------------------------------------------------------
if [ "$throwaway" -eq 1 ]; then
    target="$PROBE_TAG-owner"
    owner_net_args=()
    if [ "$owner_network" = "internal" ]; then
        created_network="$PROBE_TAG-internal"
        arm owner-network podman network create --internal "$created_network"
        owner_net_args=(--network "$created_network")
    fi
    created_containers+=("$target")
    arm owner podman run -d --name "$target" "${owner_net_args[@]}" \
        --cap-drop=ALL --security-opt=no-new-privileges --userns=keep-id \
        --read-only "$OWNER_IMAGE" sleep 3600
fi
echo "regime:netns-owner=$target owner-network=$owner_network"

share=(--network "container:$target")
posture_packet=(--cap-drop=ALL --userns=keep-id --user 0)
posture_repaired=(--cap-drop=ALL --userns "container:$target" --user 0 --security-opt label=disable)
if [ "$posture_name" = "packet" ]; then
    posture=("${posture_packet[@]}")
else
    posture=("${posture_repaired[@]}")
fi

TUN_SH='ip tuntap add dev probe0 mode tun && ip link set probe0 up && ip addr add 100.96.0.2/32 dev probe0 && ip -br addr show probe0; rc=$?; ip tuntap del dev probe0 mode tun 2>/dev/null; exit $rc'
NFT_SH='nft add table inet probe1506 && nft add chain inet probe1506 c "{ type filter hook output priority 0; }" && nft list tables; rc=$?; nft delete table inet probe1506 2>/dev/null; exit $rc'

# ---- kernel/podman facts the client depends on, under both postures ------
for p in packet repaired; do
    if [ "$p" = "packet" ]; then pa=("${posture_packet[@]}"); else pa=("${posture_repaired[@]}"); fi

    arm "$p-sysctl-src-valid-mark" podman run --rm "${share[@]}" "${pa[@]}" \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --entrypoint /bin/cat "$WARP_IMAGE" /proc/sys/net/ipv4/conf/all/src_valid_mark

    arm "$p-tun-no-netadmin" podman run --rm "${share[@]}" "${pa[@]}" \
        --device /dev/net/tun --entrypoint /bin/sh "$WARP_IMAGE" -c "$TUN_SH"

    arm "$p-tun-netadmin" podman run --rm "${share[@]}" "${pa[@]}" \
        --cap-add NET_ADMIN --device /dev/net/tun --entrypoint /bin/sh "$WARP_IMAGE" -c "$TUN_SH"
    tun_rc=$?

    arm "$p-nft-netadmin" podman run --rm "${share[@]}" "${pa[@]}" \
        --cap-add NET_ADMIN --entrypoint /bin/sh "$WARP_IMAGE" -c "$NFT_SH"
    nft_rc=$?

    if [ "$p" = "$posture_name" ]; then
        if [ "$tun_rc" -ne 0 ]; then set_outcome tun-denied-rootless; fi
        if [ "$nft_rc" -ne 0 ]; then set_outcome firewall-refused; fi
    fi
done

arm edge-tcp-from-netns podman run --rm "${share[@]}" "${posture[@]}" \
    --entrypoint /usr/bin/timeout "$WARP_IMAGE" 5 /bin/bash -c "exec 3<>/dev/tcp/$WARP_EDGE_V4/443"

# ---- the daemon ----------------------------------------------------------
start_sidecar() {
    # start_sidecar <name> <extra podman args...>
    local name="$1"; shift
    created_containers+=("$name")
    podman run -d --name "$name" "${share[@]}" "${posture[@]}" \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --read-only --tmpfs /run --tmpfs /var/log/cloudflare-warp --tmpfs /tmp \
        --volume "$created_volume:/var/lib/cloudflare-warp" \
        "$@" "$WARP_IMAGE"
}

wait_status() {
    # wait_status <name>: poll warp-cli status for up to 20 s.
    local name="$1" i
    for i in $(seq 1 20); do
        if podman exec "$name" warp-cli --accept-tos status >"$OUT/$name.status" 2>&1; then
            cat "$OUT/$name.status"
            return 0
        fi
        if [ "$(podman inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]; then
            return 2
        fi
        sleep 1
    done
    return 1
}

created_volume="$PROBE_TAG-state"
podman volume create "$created_volume" >/dev/null

mdm_args=()
if [ -n "$mdm" ]; then
    mdm_args=(--volume "$(realpath "$mdm"):/var/lib/cloudflare-warp/mdm.xml:ro")
fi

# Arm A: the selected posture minus NET_ADMIN.
arm svc-no-netadmin start_sidecar "$PROBE_TAG-svc-a" --device /dev/net/tun "${mdm_args[@]}"
arm svc-no-netadmin-status wait_status "$PROBE_TAG-svc-a"
podman logs "$PROBE_TAG-svc-a" >"$OUT/svc-a.log" 2>&1
podman rm -f -t 0 "$PROBE_TAG-svc-a" >/dev/null 2>&1

# Arm B: the selected posture with NET_ADMIN.
arm svc-netadmin start_sidecar "$PROBE_TAG-svc-b" --cap-add NET_ADMIN --device /dev/net/tun "${mdm_args[@]}"
start_rc=$?
arm svc-netadmin-status wait_status "$PROBE_TAG-svc-b"
svc_rc=$?
arm svc-netadmin-tun-visible podman exec "$PROBE_TAG-svc-b" test -c /dev/net/tun
arm svc-netadmin-settings podman exec "$PROBE_TAG-svc-b" warp-cli --accept-tos settings
arm svc-netadmin-modes podman exec "$PROBE_TAG-svc-b" warp-cli --accept-tos mode --help
if [ "$start_rc" -ne 0 ]; then
    # podman/crun refused the launch (e.g. the sysctl under a sibling
    # userns): a fact about the posture, not about the vendor package.
    echo "note:svc-launch-refused-by-runtime rc=$start_rc"
elif [ "$svc_rc" -ne 0 ]; then
    set_outcome package-refuses-container
fi

if [ -n "$mdm" ] && [ -z "$outcome" ]; then
    registered=0
    mesh_ip=""
    for _ in $(seq 1 "$WARP_WAIT_S"); do
        if podman exec "$PROBE_TAG-svc-b" warp-cli --accept-tos registration show >"$OUT/reg.out" 2>&1; then
            registered=1
        fi
        mesh_ip="$(podman exec "$PROBE_TAG-svc-b" ip -4 -o addr show 2>/dev/null \
            | awk '{print $4}' | /usr/bin/grep -E '^100\.(9[6-9]|10[0-9]|11[01])\.' | head -n 1)"
        if [ -n "$mesh_ip" ]; then break; fi
        sleep 1
    done
    arm svc-netadmin-registration cat "$OUT/reg.out"
fi
podman logs "$PROBE_TAG-svc-b" >"$OUT/svc-b.log" 2>&1

if /usr/bin/grep -q -i 'failed to start firewall' "$OUT/svc-a.log" "$OUT/svc-b.log" 2>/dev/null; then
    set_outcome firewall-refused
fi
if [ -n "$mdm" ] && [ -z "$outcome" ]; then
    if [ -n "$mesh_ip" ]; then
        echo "measured:mesh_ip=$mesh_ip"
        set_outcome mesh-ip-acquired
    elif [ "$registered" -eq 1 ]; then
        set_outcome registers-no-mesh-ip
    fi
fi

echo "evidence-dir:$OUT"
if [ -n "$outcome" ]; then
    echo "outcome:$outcome"
elif [ -z "$mdm" ]; then
    echo "outcome-pending:enrollment-required:operator-minted-service-token-mdm.xml"
else
    echo "outcome-pending:no-refusal-no-registration-within-${WARP_WAIT_S}s"
fi
