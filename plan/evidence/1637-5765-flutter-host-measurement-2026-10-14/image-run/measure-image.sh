#!/usr/bin/env bash
# 1637-5765: build images/flutter in the private store, then run the forge-time
# phases against it with the logging proxy as the only egress.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git rev-parse --show-toplevel)"
D="$REPO/target/work/flutter-measure"
R="$(cat "$D/runtime-dir.txt")"
export CONTAINERS_STORAGE_CONF="$D/storage.conf" CONTAINERS_CONF="$D/containers.conf"
export REGISTRY_AUTH_FILE="$D/auth.json" HOME="$D/home"
got="$(podman info --format '{{.Store.GraphRoot}} {{.Store.RunRoot}}')"
[ "$got" = "$D/graph $R/run" ] || { echo "GUARD: store is [$got], refusing"; exit 2; }
cleanup() { podman rm -f fm-proxy >/dev/null 2>&1; podman network rm -f fm-internal fm-egress >/dev/null 2>&1; }
trap cleanup EXIT
cleanup
M="$D/m2"; mkdir -p "$M" "$D/proj2" "$D/pub2"
cp "$HERE/logproxy.py" "$M/logproxy.py"; : > "$M/hosts.tsv"; : > "$M/phases.txt"; echo build > "$M/phase"

t0=$(date +%s)
podman build --format docker -t localhost/tillandsias-flutter:measure -f "$REPO/images/flutter/Containerfile" "$REPO/images/flutter" > "$M/build.log" 2>&1
echo "phase=0-image-build rc=$? secs=$(( $(date +%s) - t0 ))" | tee -a "$M/phases.txt"
podman image inspect localhost/tillandsias-flutter:measure --format '{{.Size}}' >> "$M/phases.txt"

podman network create --internal fm-internal >/dev/null
podman network create fm-egress >/dev/null
podman run -d --name fm-proxy --network fm-egress -v "$M:/m:Z" \
  docker.io/library/python:3.13-slim python3 -I /m/logproxy.py 3128 /m/hosts.tsv /m/phase >/dev/null
podman network connect --alias fmproxy fm-internal fm-proxy
sleep 2
P=http://fmproxy:3128
run_phase() {
  echo "$1" > "$M/phase"
  local t0=$(date +%s)
  podman run --rm --network fm-internal --userns=keep-id \
    -e HTTPS_PROXY=$P -e HTTP_PROXY=$P -e https_proxy=$P -e http_proxy=$P -e NO_PROXY= \
    -e PUB_CACHE=/pub -v "$D/pub2:/pub:Z" -v "$D/proj2:/work:Z" -w /work \
    localhost/tillandsias-flutter:measure timeout 900 bash -c "$2" > "$M/$1.log" 2>&1
  echo "phase=$1 rc=$? secs=$(( $(date +%s) - t0 ))" | tee -a "$M/phases.txt"
  sleep 1
}
run_phase 1-version 'flutter --version; id'
run_phase 2-create 'flutter create --platforms web app'
run_phase 3-pub-add-flame 'cd app && flutter pub add flame'
run_phase 4-build-web 'cd app && flutter build web --release && ls build/web'
echo done > "$M/phase"
echo "harness complete"
