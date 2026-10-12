#!/usr/bin/env bash
# @trace spec:inference-engine-slots, order:482c
#
# Order 482c: T0 engine-parity smoke for the inference slot, on a mutable podman
# host. It drives the PRODUCT code paths, not copies of them:
#   * image:    `tillandsias --internal-ensure-image <repo> inference <tag>`
#   * ensure:   `tillandsias --internal-inference-slot ensure <certs>`, which
#               is the launch path's own ensure_inference_for_launch (the
#               running-check, then build_inference_run_args) followed by
#               report_inference_readiness (SLOT-8 soft readiness)
#   * teardown: `tillandsias --internal-inference-slot teardown`, the
#               shutdown path's shared-stack cleanup
#
# EVERYTHING RUNS ON A THROWAWAY SUBSTRATE. The product names its container
# `tillandsias-inference` and its network `tillandsias-enclave`, exactly what
# the operator's live enclave uses, and build_inference_run_args `--replace`s.
# So these are private: the store (graphroot), the runroot (where netavark
# keeps the rootless netns, aardvark-dns config and IPAM, so the scratch
# `tillandsias-enclave` never touches the live one's DNS entries), libpod's
# engine.tmp_dir, the network config dir, the registry auth file, and HOME.
# HOME matters because setting XDG_CACHE_HOME alone makes adopt_legacy_cache
# MOVE the operator's ~/.cache/tillandsias/models into scratch.
# XDG_RUNTIME_DIR stays the real one ON PURPOSE. netavark starts aardvark-dns
# through `systemd-run --user` on a systemd host, and a private runtime dir has
# no user bus, so DNS never comes up (measured 2026-10-12 with linked, relayed
# and masked bus variants). Every podman mutation is preceded by a guard on
# GraphRoot and RunRoot. The operator's own inference container is only ever
# READ (id + start time, before and after).
#
# Lanes (default: all, in this order):
#   ollama        engine unset (the default), GPU per the detected tier
#   llama-cuda    engine=llama-server, backend=cuda (CDI device on gpu-cuda)
#   llama-vulkan  engine=llama-server, backend=vulkan (render nodes)
#   degraded      engine=llama-server on an --internal network with an empty
#                 cache: the slot can never become ready
#
# Per normal lane: free VRAM before; cold ensure on an egress network (the
# image has no enclave proxy here, so it runs direct); wait for readiness;
# /api/version (timed, -m 1), /v1/models and /v1/chat/completions through the
# `inference` alias from a separate consumer container; exactly one engine
# process; a second ensure must reuse the same container id; then the container
# is removed, the network is recreated --internal (no egress at all) and a third
# ensure must come up from cache with every file over 1 MiB unchanged (inode,
# size, mtime); teardown must leave no inference container.
#
# Usage: scripts/inference-engine-parity-smoke.sh <out-dir> [lane...]
# Env:   TILLANDSIAS_PARITY_BIN  binary under test (default target/release/tillandsias)
#        TILLANDSIAS_PARITY_ROOT  substrate parent (default <checkout>/target/work/inference-parity,
#                                 gitignored: development scratch stays inside the checkout).
#                                 The runroot and libpod tmp_dir go to a private dir under
#                                 $XDG_RUNTIME_DIR instead: pasta's SELinux domain cannot
#                                 open its pid file under a home-labelled checkout
#                                 ("rootless-netns-conn.pid: Permission denied", measured).
# Exit:  0 when every lane verdict is ok, 1 otherwise, 3 on a guard abort.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${TILLANDSIAS_PARITY_BIN:-$REPO/target/release/tillandsias}"
OUT="${1:?usage: inference-engine-parity-smoke.sh <out-dir> [lane...]}"
shift
LANES=("$@")
[ "${#LANES[@]}" -gt 0 ] || LANES=(ollama llama-cuda llama-vulkan degraded)
VERSION="$(tr -d '[:space:]' < "$REPO/VERSION")"
TAG="localhost/tillandsias-inference:v$VERSION"
NET=tillandsias-enclave
CTR=tillandsias-inference
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[ -x "$BIN" ] || { echo "ABORT: no binary at $BIN"; exit 3; }

# The operator's environment, kept only to READ its live inference container.
OP_ENV=(env -u CONTAINERS_STORAGE_CONF -u CONTAINERS_CONF -u REGISTRY_AUTH_FILE -u XDG_CACHE_HOME "HOME=$HOME")
[ -z "${CONTAINERS_STORAGE_CONF:-}${CONTAINERS_CONF:-}" ] \
    || { echo "ABORT: run from a plain operator shell (CONTAINERS_STORAGE_CONF/CONTAINERS_CONF already set)"; exit 3; }

W="${TILLANDSIAS_PARITY_ROOT:-$REPO/target/work/inference-parity}"
mkdir -p "$W"
S="$(mktemp -d "$W/run.XXXXXX")"
R="$(mktemp -d "${XDG_RUNTIME_DIR:?}/tillandsias-parity.XXXXXX")"
echo "$S" > "$OUT/substrate.path"
mkdir -p "$S/graph" "$R/run" "$R/tmp" "$S/netconf" "$S/certs"
printf '%s\n' '[storage]' 'driver = "overlay"' "graphroot = \"$S/graph\"" "runroot = \"$R/run\"" > "$S/storage.conf"
# No systemd session behind the private runtime dir: cgroupfs, file events.
printf '%s\n' '[engine]' 'cgroup_manager = "cgroupfs"' 'events_logger = "file"' "events_logfile_path = \"$S/events.log\"" \
    "tmp_dir = \"$R/tmp\"" '[network]' "network_config_dir = \"$S/netconf\"" > "$S/containers.conf"

operator_inference() {
    "${OP_ENV[@]}" podman inspect --format '{{.Id}} {{.State.Status}} started={{.State.StartedAt}}' "$CTR" 2>&1
}
OP_BEFORE="$(operator_inference)"
# The live enclave's netavark state (DNS entries, IPAM, rootless netns). A
# scratch network must never write here; diffed at the end.
OP_NET="${XDG_RUNTIME_DIR:?}/containers/networks"
find "$OP_NET" -printf '%p %s %T@\n' > "$OUT/op-net-before" 2> /dev/null

export CONTAINERS_STORAGE_CONF="$S/storage.conf" CONTAINERS_CONF="$S/containers.conf" REGISTRY_AUTH_FILE="$S/auth.json"
unset TILLANDSIAS_INFERENCE_ENGINE TILLANDSIAS_INFERENCE_LLAMA_BACKEND
unset TILLANDSIAS_INFERENCE_TIER TILLANDSIAS_NO_LOCAL_INFERENCE TILLANDSIAS_INFERENCE_KEEP_ALIVE
export HOME="$S/home-build" XDG_CACHE_HOME="$S/home-build/.cache"
mkdir -p "$HOME"

guard() {
    local g
    g="$(podman info --format '{{.Store.GraphRoot}} {{.Store.RunRoot}}' 2>/dev/null)"
    [ "$g" = "$S/graph $R/run" ] || { echo "ABORT: podman store is '$g', not $S/graph $R/run"; exit 3; }
    case "$HOME" in "$S"/*) ;; *) echo "ABORT: HOME=$HOME is outside the substrate"; exit 3 ;; esac
}

log() { echo "$*" >> "$OUT/summary.txt"; echo "$*"; }

vram() {
    local f used
    log "vram[$1] nvidia: $(nvidia-smi --query-gpu=name,memory.used,memory.free,memory.total --format=csv,noheader 2>&1)"
    for f in /sys/class/drm/card*/device/mem_info_vram_used; do
        [ -r "$f" ] || continue
        used="$(cat "$f")"
        log "vram[$1] amdgpu ${f%/device/*}: $((used / 1048576)) MiB used"
    done
}

# One consumer request through the stable endpoint, from a SEPARATE container
# on the network, resolving the `inference` alias exactly as a forge does.
consumer() {
    podman run --rm --network "$NET" --entrypoint curl "$TAG" -sS "$@"
}

wait_ready() {
    local deadline=$((SECONDS + $1))
    while [ "$SECONDS" -lt "$deadline" ]; do
        podman exec "$CTR" curl -fsS -m 1 http://127.0.0.1:11434/api/version > /dev/null 2>&1 && return 0
        [ "$(podman inspect --format '{{.State.Running}}' "$CTR" 2> /dev/null)" = true ] || return 1
        sleep 5
    done
    return 1
}

engine_processes() {
    # comm of every process in the container, engine binaries counted.
    podman exec "$CTR" sh -c 'o=0; l=0; for p in /proc/[0-9]*; do c=$(cat "$p/comm" 2>/dev/null); [ "$c" = ollama ] && o=$((o+1)); [ "$c" = llama-server ] && l=$((l+1)); done; echo "ollama=$o llama-server=$l"'
}

# /api/version answers as soon as the engine listens; ollama may still be
# pulling its T0 model at that point (run 4: /v1/models was data:null and the
# 397 MB blob was -partial). Parity is asked of a slot that SERVES a model, and
# the cache snapshot of a settled one, so wait for both, bounded.
wait_model() {
    local deadline=$((SECONDS + $1)) body
    while [ "$SECONDS" -lt "$deadline" ]; do
        body="$(consumer -m 5 http://inference:11434/v1/models 2> /dev/null)"
        [[ "$body" =~ \"id\":\"[^\"]+\" ]] && return 0
        sleep 5
    done
    return 1
}

wait_settled() {
    local deadline=$((SECONDS + $1)) partial
    while [ "$SECONDS" -lt "$deadline" ]; do
        partial="$(find "$HOME/.cache/tillandsias/models" -name '*-partial*' -print -quit 2> /dev/null)"
        [ -z "$partial" ] && return 0
        sleep 5
    done
    return 1
}

snapshot() {
    find "$HOME/.cache/tillandsias/models" -type f -size +1M -printf '%i %s %T@ %P\n' > "$1" 2>/dev/null
    sort -o "$1" "$1"
}

probe() {
    local tag="$1" body id code
    code="$(consumer -o /dev/null -m 1 -w '%{http_code} %{time_total}s' http://inference:11434/api/version)"
    log "  [$tag] consumer GET /api/version (curl -m 1): $code"
    [ "${code%% *}" = 200 ] || return 1
    body="$(consumer -m 10 http://inference:11434/v1/models)"
    printf '%s\n' "$body" > "$OUT/$LANE.$tag.v1-models.json"
    # The T0 chat model by its engine id (ollama qwen2.5:0.5b, llama-server
    # qwen2.5-0.5b-instruct); ollama also lists its embed model, which refuses chat.
    local rest="$body" ids=""
    id=""
    while [[ "$rest" =~ \"id\":\"([^\"]+)\"(.*) ]]; do
        ids="$ids ${BASH_REMATCH[1]}"
        [ -z "$id" ] && [[ "${BASH_REMATCH[1]}" == qwen2.5* ]] && id="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
    done
    [ -n "$id" ] || { log "  [$tag] /v1/models lists no T0 model:$ids"; return 1; }
    log "  [$tag] consumer GET /v1/models:$ids (T0 chat model: $id)"
    body="$(consumer -m 120 -H 'Content-Type: application/json' \
        -d "{\"model\":\"$id\",\"temperature\":0,\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: pong\"}]}" \
        http://inference:11434/v1/chat/completions)"
    printf '%s\n' "$body" > "$OUT/$LANE.$tag.chat.json"
    [[ "$body" =~ \"content\":\"([^\"]*)\" ]] || { log "  [$tag] /v1/chat/completions has no content: $body"; return 1; }
    log "  [$tag] consumer POST /v1/chat/completions: content=\"${BASH_REMATCH[1]}\""
    log "  [$tag] engine processes: $(engine_processes)"
}

ensure() {
    local n="$1" t0 rc
    guard
    t0=$SECONDS
    "$BIN" --internal-inference-slot ensure "$S/certs" --debug > "$OUT/$LANE.ensure-$n.log" 2>&1
    rc=$?
    log "  ensure-$n rc=$rc in $((SECONDS - t0))s: $(grep -h 'inference-slot: ensure' "$OUT/$LANE.ensure-$n.log")"
    grep -h -E 'DEGRADED|already running; reusing' "$OUT/$LANE.ensure-$n.log" >> "$OUT/summary.txt"
    return "$rc"
}

teardown() {
    local left
    guard
    "$BIN" --internal-inference-slot teardown --debug > "$OUT/$LANE.teardown.log" 2>&1
    left="$(podman ps -a --filter "name=^$CTR\$" --format '{{.Names}} {{.State}}')"
    log "  teardown: inference containers left: ${left:-none}"
    [ -z "$left" ]
}

net() {
    guard
    podman network rm -f "$NET" > /dev/null 2>&1
    podman network create "$@" "$NET" > /dev/null
    log "  network $NET recreated ${*:-with egress}"
}

run_lane() {
    local fail=0 id1 id2 count t0
    export HOME="$S/home-$LANE" XDG_CACHE_HOME="$S/home-$LANE/.cache"
    mkdir -p "$HOME"
    unset TILLANDSIAS_INFERENCE_ENGINE TILLANDSIAS_INFERENCE_LLAMA_BACKEND
    if [ "$LANE" = llama-cuda ]; then
        export TILLANDSIAS_INFERENCE_ENGINE=llama-server TILLANDSIAS_INFERENCE_LLAMA_BACKEND=cuda
    elif [ "$LANE" = llama-vulkan ]; then
        export TILLANDSIAS_INFERENCE_ENGINE=llama-server TILLANDSIAS_INFERENCE_LLAMA_BACKEND=vulkan
    elif [ "$LANE" = degraded ]; then
        export TILLANDSIAS_INFERENCE_ENGINE=llama-server TILLANDSIAS_INFERENCE_LLAMA_BACKEND=vulkan
    fi
    log "== lane $LANE: engine=${TILLANDSIAS_INFERENCE_ENGINE:-<unset: default>} backend=${TILLANDSIAS_INFERENCE_LLAMA_BACKEND:-<unset>} home=$HOME"
    vram "$LANE:before"

    if [ "$LANE" = degraded ]; then
        net --internal
        ensure 1 || fail=1
        grep -q 'inference-slot: ensure ready=false' "$OUT/$LANE.ensure-1.log" || { log "  FAIL: the never-ready slot did not report ready=false"; fail=1; }
        grep -q 'DEGRADED: local inference not ready (engine=llama-server)' "$OUT/$LANE.ensure-1.log" || { log "  FAIL: no DEGRADED line"; fail=1; }
        podman logs "$CTR" > "$OUT/$LANE.container.log" 2>&1
        log "  container: $(podman inspect --format '{{.State.Status}} exit={{.State.ExitCode}}' "$CTR" 2>&1)"
        grep -h -E 'reason=|FATAL|refused' "$OUT/$LANE.container.log" >> "$OUT/summary.txt"
        teardown || fail=1
        vram "$LANE:after-teardown"
        return "$fail"
    fi

    net
    ensure 1 || { log "  FAIL: the cold ensure could not start the slot"; teardown; return 1; }
    if ! wait_ready 900; then
        podman logs "$CTR" > "$OUT/$LANE.container-cold.log" 2>&1
        log "  FAIL: not ready within 900s after the cold ensure"
        teardown
        return 1
    fi
    podman logs "$CTR" > "$OUT/$LANE.container-cold.log" 2>&1
    grep -h -E '^\[inference\] (engine|llama|backend|tuning|payload|closure|gguf)|engine-set|GGML_BACKEND_PATH|using device|offloaded|CUDA0|Vulkan0|library=' "$OUT/$LANE.container-cold.log" > "$OUT/$LANE.engine-lines.txt"
    log "  engine evidence: $OUT/$LANE.engine-lines.txt ($(wc -l < "$OUT/$LANE.engine-lines.txt") lines)"
    t0=$SECONDS
    wait_model 900 || { log "  FAIL: no model listed within 900s of readiness"; fail=1; }
    wait_settled 900 || { log "  FAIL: model cache still has partial downloads after 900s"; fail=1; }
    log "  model listed and cache settled $((SECONDS - t0))s after readiness"
    vram "$LANE:serving-before-probe"
    probe cold || fail=1
    vram "$LANE:serving-after-probe"

    id1="$(podman inspect --format '{{.Id}}' "$CTR")"
    ensure 2 || fail=1
    id2="$(podman inspect --format '{{.Id}}' "$CTR")"
    mapfile -t count < <(podman ps -a --filter "name=^$CTR\$" --format '{{.Names}}')
    log "  double ensure: id ${id1:0:12} -> ${id2:0:12}; containers named $CTR: ${#count[@]}"
    [ "$id1" = "$id2" ] && [ "${#count[@]}" = 1 ] || { log "  FAIL: the second ensure did not reuse the running slot"; fail=1; }
    grep -q 'already running; reusing' "$OUT/$LANE.ensure-2.log" || { log "  FAIL: no reuse line"; fail=1; }

    snapshot "$OUT/$LANE.cache-pre.txt"
    guard
    podman rm -f "$CTR" > /dev/null
    net --internal
    ensure 3 || fail=1
    grep -q 'inference-slot: ensure ready=true' "$OUT/$LANE.ensure-3.log" || { log "  FAIL: no-egress warm ensure not ready"; fail=1; }
    podman logs "$CTR" > "$OUT/$LANE.container-warm.log" 2>&1
    snapshot "$OUT/$LANE.cache-post.txt"
    if cmp -s "$OUT/$LANE.cache-pre.txt" "$OUT/$LANE.cache-post.txt"; then
        log "  no re-download: $(wc -l < "$OUT/$LANE.cache-pre.txt") cached files >1MiB unchanged (inode size mtime) across a no-egress recreate"
    else
        log "  FAIL: cached files changed across the warm recreate:"
        diff "$OUT/$LANE.cache-pre.txt" "$OUT/$LANE.cache-post.txt" >> "$OUT/summary.txt"
        fail=1
    fi
    probe warm || fail=1
    teardown || fail=1
    vram "$LANE:after-teardown"
    return "$fail"
}

cleanup() {
    guard
    podman rm -a -f > /dev/null 2>&1
    podman network rm -f "$NET" > /dev/null 2>&1
    podman rmi -a -f > /dev/null 2>&1
    # One unshare: lazy-unmount every scratch mount (graph and runroot), then
    # remove the trees whose files belong to subordinate uids.
    podman unshare bash -c 'for d in "$1" "$2"; do grep -F "$d" /proc/self/mountinfo > "$1/mounts.$$" 2>/dev/null; while read -r _ _ _ _ m _; do umount -l "$m"; done < "$1/mounts.$$"; done; rm -rf "$1/graph" "$2/run" "$2/tmp"' _ "$S" "$R"
    rm -rf "$S" "$R"
    log "substrate removed: $S and $R"
}

log "482c parity smoke: bin=$BIN version=$VERSION tag=$TAG substrate=$S"
log "operator inference before: $OP_BEFORE"
guard
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=482c-parity -days 1 \
    -keyout "$S/certs/intermediate.key" -out "$S/certs/intermediate.crt" > /dev/null 2>&1
t0=$SECONDS
"$BIN" --internal-ensure-image "$REPO" inference "$TAG" > "$OUT/image-ensure.log" 2>&1 \
    || { log "ABORT: image ensure failed (see image-ensure.log)"; cleanup; exit 1; }
log "image ensured in $((SECONDS - t0))s: $(podman image inspect --format '{{.Id}} {{.Size}}' "$TAG")"
# The image's HEALTHCHECK is armed by podman as a systemd user timer, and the
# private runtime dir has no systemd. Linking the user manager in does not work
# either: netavark then starts aardvark-dns through systemd-run, whose bus path
# the rootless netns cannot see (both measured 2026-10-12). So the SCRATCH copy
# of the image gets one metadata layer, HEALTHCHECK NONE, under the same tag.
# Nothing else changes; readiness is probed by the product's own
# wait_for_inference_ready (podman exec curl /api/version), not the healthcheck.
log "image healthcheck removed for the scratch store: $(podman image inspect --format '{{json .Config.Healthcheck}}' "$TAG")"
guard
printf 'FROM %s\nHEALTHCHECK NONE\n' "$TAG" > "$S/Containerfile.nohc"
podman build -q --format docker -t "$TAG" -f "$S/Containerfile.nohc" "$S/certs" > /dev/null \
    || { log "ABORT: could not layer HEALTHCHECK NONE"; cleanup; exit 1; }
log "scratch image healthcheck now: $(podman image inspect --format '{{json .Config.Healthcheck}}' "$TAG")"

verdicts=()
overall=0
for LANE in "${LANES[@]}"; do
    if run_lane; then
        verdicts+=("ok:$LANE")
    else
        verdicts+=("fail:$LANE")
        overall=1
    fi
    guard
    podman rm -f "$CTR" > /dev/null 2>&1
done
cleanup
log "operator inference after:  $(operator_inference)"
find "$OP_NET" -printf '%p %s %T@\n' > "$OUT/op-net-after" 2> /dev/null
if cmp -s "$OUT/op-net-before" "$OUT/op-net-after"; then
    log "operator netavark state ($OP_NET): unchanged ($(wc -l < "$OUT/op-net-after") entries)"
else
    log "operator netavark state ($OP_NET) CHANGED during the run (the live enclave may have acted too):"
    diff "$OUT/op-net-before" "$OUT/op-net-after" >> "$OUT/summary.txt"
fi
log "verdicts: ${verdicts[*]}"
exit "$overall"
