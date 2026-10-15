#!/usr/bin/env bash
# 1637-5765: measure every host a clean Flutter SDK install + `flutter create`
# + `pub add flame` + `flutter build web` reaches, with the logging proxy as
# the ONLY egress (an --internal network, like the forge).
# Private podman store per the isolated-store recipe. Never touches the
# operator's store.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git rev-parse --show-toplevel)"
D="$REPO/target/work/flutter-measure"
mkdir -p "$D"/{graph,sdk,work,home,croot,m}
R="$(cat "$D/runtime-dir.txt" 2>/dev/null)"; [ -n "$R" ] && [ -d "$R" ] || R="$(mktemp -d "$XDG_RUNTIME_DIR/fm.XXXXXX")"
mkdir -p "$R"/{run,tmp,net}
echo "$R" > "$D/runtime-dir.txt"
cat > "$D/storage.conf" <<EOF
[storage]
driver = "overlay"
graphroot = "$D/graph"
runroot = "$R/run"
EOF
cat > "$D/containers.conf" <<EOF
[engine]
tmp_dir = "$R/tmp"
cgroup_manager = "cgroupfs"
events_logger = "file"
[network]
network_config_dir = "$R/net"
EOF
export CONTAINERS_STORAGE_CONF="$D/storage.conf" CONTAINERS_CONF="$D/containers.conf"
export REGISTRY_AUTH_FILE="$D/auth.json"; echo '{}' > "$REGISTRY_AUTH_FILE"
export HOME="$D/home"

got="$(podman info --format '{{.Store.GraphRoot}} {{.Store.RunRoot}}')"
[ "$got" = "$D/graph $R/run" ] || { echo "GUARD: store is [$got], refusing"; exit 2; }
echo "guard ok: $got"
cleanup() { podman rm -f fm-proxy >/dev/null 2>&1; podman network rm -f fm-internal fm-egress >/dev/null 2>&1; }
trap cleanup EXIT
cleanup

podman network create --internal fm-internal >/dev/null
podman network create fm-egress >/dev/null
cp "$HERE/logproxy.py" "$D/m/logproxy.py"
: > "$D/m/hosts.tsv"; : > "$D/m/phases.txt"; echo setup > "$D/m/phase"

podman pull -q docker.io/library/python:3.13-slim >/dev/null
podman pull -q docker.io/library/debian:bookworm-slim >/dev/null
# Base tools are image-build-time (deb.debian.org), outside the measurement.
printf 'FROM docker.io/library/debian:bookworm-slim\nRUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils unzip && rm -rf /var/lib/apt/lists/*\n' > "$D/Containerfile"
podman build -q -t fm-base -f "$D/Containerfile" "$D" >/dev/null || { echo "base build failed"; exit 3; }

podman run -d --name fm-proxy --network fm-egress -v "$D/m:/m:Z" \
  docker.io/library/python:3.13-slim python3 -I /m/logproxy.py 3128 /m/hosts.tsv /m/phase >/dev/null
podman network connect --alias fmproxy fm-internal fm-proxy
sleep 2

P=http://fmproxy:3128
run_phase() {  # $1 phase name, $2 script
  echo "$1" > "$D/m/phase"
  local t0=$(date +%s)
  podman run --rm --network fm-internal \
    -e HTTPS_PROXY=$P -e HTTP_PROXY=$P -e https_proxy=$P -e http_proxy=$P -e NO_PROXY= \
    -e PUB_CACHE=/root/.pub-cache -e PATH=/opt/flutter/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    -v "$D/sdk:/opt:Z" -v "$D/work:/work:Z" -v "$D/croot:/root:Z" -w /work fm-base \
    timeout 1500 bash -c "$2" > "$D/m/$1.log" 2>&1
  local rc=$?
  echo "phase=$1 rc=$rc secs=$(( $(date +%s) - t0 ))" | tee -a "$D/m/phases.txt"
  sleep 1
}

run_phase 1-sdk-download 'set -e; curl -fsS https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json -o /work/releases.json; J=$(tr -d "\n " < /work/releases.json); h=$(printf %s "$J" | grep -o "\"current_release\":{[^}]*}" | grep -o "\"stable\":\"[0-9a-f]*\"" | grep -o "[0-9a-f]\{40\}"); a=$(printf %s "$J" | grep -o "\"hash\":\"$h\"[^}]*" | grep -o "\"archive\":\"[^\"]*\"" | cut -d\" -f4); echo "stable=$h archive=$a"; test -n "$a"; curl -fsS "https://storage.googleapis.com/flutter_infra_release/releases/$a" -o /work/flutter.tar.xz; ls -la /work/flutter.tar.xz; tar -xJf /work/flutter.tar.xz -C /opt; git config --global --add safe.directory /opt/flutter; du -sh /opt/flutter'
run_phase 2-first-run 'flutter --version; du -sh /opt/flutter'
run_phase 3-precache-web 'flutter precache --web --no-android --no-ios --no-linux --no-windows --no-macos --no-fuchsia --no-universal; du -sh /opt/flutter'
run_phase 4-create 'flutter create --platforms web app; du -sh /work/app /root/.pub-cache'
run_phase 5-pub-add-flame 'cd app && flutter pub add flame; du -sh /work/app /root/.pub-cache'
run_phase 6-build-web 'cd app && flutter build web --release; du -sh /work/app /work/app/build/web /work/app/.dart_tool /root/.pub-cache /opt/flutter; ls /work/app/build/web'
run_phase 7-build-web-again 'cd app && flutter build web --release'
echo done > "$D/m/phase"
podman logs fm-proxy > "$D/m/proxy.log" 2>&1
echo "harness complete"
