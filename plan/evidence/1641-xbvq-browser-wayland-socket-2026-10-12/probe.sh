#!/usr/bin/env bash
# 1641-xbvq live probe on a SCRATCH podman store (graph under target/work, runroot
# in a private $XDG_RUNTIME_DIR dir). Runs the browser with the product's real
# argv (args.txt, written by the browser_spec_live_probe_args helper), then looks
# from INSIDE the container for the host's podman socket, D-Bus bus, keyring and
# X11 socket, and records the Wayland protocol exchange (WAYLAND_DEBUG=client,
# added for the probe only) to show the compositor mapped a window.
#   probe.sh <variant>   variant: shipped (as built) | labeled (without label=disable)
set -u
V="${1:?variant}"
B=/var/home/lenovinha/claudia/tillandsias/target/work/1641
W="$B/store"
mkdir -p "$W/graph" "$W/netconf" "$B/out"
[ -f "$W/runtime.path" ] || mktemp -d "$XDG_RUNTIME_DIR/1641-probe.XXXXXX" > "$W/runtime.path"
R="$(cat "$W/runtime.path")"
mkdir -p "$R/run" "$R/tmp"
printf '%s\n' '[storage]' 'driver = "overlay"' "graphroot = \"$W/graph\"" "runroot = \"$R/run\"" > "$W/storage.conf"
printf '%s\n' '[engine]' 'cgroup_manager = "cgroupfs"' 'events_logger = "file"' "events_logfile_path = \"$W/events.log\"" \
    "tmp_dir = \"$R/tmp\"" '[network]' "network_config_dir = \"$W/netconf\"" > "$W/containers.conf"
SCRATCH=(env CONTAINERS_STORAGE_CONF="$W/storage.conf" CONTAINERS_CONF="$W/containers.conf" REGISTRY_AUTH_FILE="$W/auth.json")
g="$("${SCRATCH[@]}" podman info --format '{{.Store.GraphRoot}} {{.Store.RunRoot}}')"
[ "$g" = "$W/graph $R/run" ] || { echo "ABORT: store is '$g'"; exit 3; }
IMG=localhost/tillandsias-chromium-framework:v56.9.27.2
if ! "${SCRATCH[@]}" podman image exists "$IMG"; then
    [ -f "$B/chromium.tar" ] || podman save -q -o "$B/chromium.tar" "$IMG"   # operator store: read-only
    "${SCRATCH[@]}" podman load -q -i "$B/chromium.tar"
fi
O="$B/out/$V"
mkdir -p "$O"
mapfile -t ARGS < "$B/args.txt"
RUN=()
for a in "${ARGS[@]}"; do
    [ "$V" = labeled ] && [ "$a" = "--security-opt=label=disable" ] && continue
    [ "$V" = labeled ] && [ "$a" = "--rm" ] && continue
    if [ "$V" = labeled-z ]; then
        [ "$a" = "--security-opt=label=disable" ] && continue
        [ "$a" = "--rm" ] && continue
        case "$a" in *.profile:*.profile:rw) a="${a},Z" ;; esac
    fi
    if [ "$a" = "tillandsias-chromium-framework:v56.9.27.2" ]; then RUN+=(--env WAYLAND_DEBUG=client); fi
    RUN+=("$a")
done
printf '%s\n' "${RUN[@]}" > "$O/argv.txt"
NAME=tillandsias-browser-1641-probe
"${SCRATCH[@]}" podman rm -f "$NAME" > /dev/null 2>&1
"${SCRATCH[@]}" podman run "${RUN[@]}" > "$O/run.out" 2>&1
echo "run rc=$?"
sleep 10
"${SCRATCH[@]}" podman inspect --format '{{.State.Status}} {{.State.ExitCode}}' "$NAME" > "$O/state.txt" 2>&1
echo "state: $(cat "$O/state.txt")"
"${SCRATCH[@]}" podman exec "$NAME" sh -c '
echo "== /run/user/browser:"; ls -la /run/user/browser
echo "== mounts mentioning run/user, X11, wayland, bus, keyring:"; grep -E "run/user|X11|wayland|bus|keyring" /proc/self/mountinfo
for p in /run/user/1000 /run/user/1000/podman/podman.sock /run/user/1000/bus /run/user/1000/keyring /run/user/1000/tillandsias /run/user/browser/podman /run/user/browser/bus /run/user/browser/keyring /run/dbus/system_bus_socket /tmp/.X11-unix; do
  if [ -e "$p" ]; then echo "VISIBLE $p"; else echo "absent  $p"; fi
done
echo "== sockets anywhere outside /proc /sys:"; find / -path /proc -prune -o -path /sys -prune -o -type s -print 2>/dev/null
echo "== env DBUS: ${DBUS_SESSION_BUS_ADDRESS-<unset>} DISPLAY: ${DISPLAY-<unset>}"
' > "$O/inside.txt" 2>&1
cat "$O/inside.txt"
"${SCRATCH[@]}" podman logs "$NAME" > "$O/browser.log" 2>&1
echo "== window evidence (wayland protocol, compositor -> client):"
grep -E 'xdg_toplevel@[0-9]+\.configure|xdg_surface@[0-9]+\.configure|wl_surface@[0-9]+\.attach|xdg_wm_base|wl_display@1\.error|Failed to connect to Wayland|Could not connect' "$O/browser.log" | sort | uniq -c | sort -rn | head -12
"${SCRATCH[@]}" podman rm -f "$NAME" > /dev/null 2>&1
echo "removed $NAME"
