#!/usr/bin/env bash
# @trace order:1861-nmpp, order:1860-auhm
# Litmus: the GrapesJS studio LANE. studio-grapesjs is built from
# images/studio/Containerfile.grapesjs on the local forge image, as the
# launcher builds it on first use, and run with its registry entry and
# --network none on a throwaway git checkout. Through the studio front (:4096)
# it must serve the vendored core (no CDN) and the project's page, and a save
# posted to the shared endpoint /__studio/save must land in the checkout's
# index.html as a commit; a path outside the allowlist must be refused and
# write nothing. The browser arm drives the real editor in headless chromium.
#
# Exit: 0 pass, 1 fail, 3 could-not-run (no podman, no local forge image, or
# the build cannot fetch the pinned tarball).
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
TAG="localhost/tillandsias-studio-grapesjs:test-$$"
command -v podman >/dev/null 2>&1 || { echo "could-not-run:studio-grapesjs:no-podman"; exit 3; }
FORGE_IMAGE="${TILLANDSIAS_TEST_FORGE_IMAGE:-localhost/tillandsias-forge:v$VERSION}"
# Any local tag of an image when this VERSION's is absent (as test-studio-front.lua).
local_tag() { podman images --format '{{.Repository}}:{{.Tag}}' --filter "reference=$1" | awk '!/<none>/ { print; exit }'; }
podman image exists "$FORGE_IMAGE" || FORGE_IMAGE="$(local_tag localhost/tillandsias-forge)"
[ -n "$FORGE_IMAGE" ] && podman image exists "$FORGE_IMAGE" || { echo "could-not-run:studio-grapesjs:no-local-forge-image"; exit 3; }

work="$(mktemp -d "${TMPDIR:-/tmp}/studio-grapesjs.XXXXXX")"
name="studio-grapesjs-test-$$"
pod="studio-grapesjs-pod-$$"
cleanup() {
  podman pod rm -f "$pod" >/dev/null 2>&1 || true
  podman rm -f "$name" >/dev/null 2>&1 || true
  podman rmi -f "$TAG" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

if ! podman build -q -t "$TAG" --build-arg "FORGE_IMAGE=$FORGE_IMAGE" \
     -f "$PROJECT_ROOT/images/studio/Containerfile.grapesjs" "$PROJECT_ROOT/images/studio" \
     >/dev/null 2>"$work.build.err"; then
  if grep -q 'fetch https://registry.npmjs.org' "$work.build.err"; then
    rm -f "$work.build.err"; echo "could-not-run:studio-grapesjs:tarball-fetch-failed"; exit 3
  fi
  cat "$work.build.err"; rm -f "$work.build.err"; echo "FAIL: studio-grapesjs did not build on $FORGE_IMAGE"; exit 1
fi
rm -f "$work.build.err"

site="$work/site"
mkdir -p "$site"
git -C "$site" init -q
printf '<!doctype html>\n<html><body>\n<h1>Before</h1>\n</body></html>\n' > "$site/index.html"
git -C "$site" add -A
git -C "$site" -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -m site
base="$(git -C "$site" rev-parse HEAD)"

# The launcher's argv for a studio lane: the registry entry as entrypoint and
# TILLANDSIAS_STUDIO naming it (apply_web_lane), and the git identity the
# launcher passes (configure_git_identity), without which the front cannot commit.
run_lane() {
  podman run -d --rm "$@" --userns keep-id --entrypoint /usr/local/bin/studio-grapesjs \
    -e TILLANDSIAS_STUDIO=grapesjs -e TILLANDSIAS_PROJECT=site -e TILLANDSIAS_PROJECT_HOST_MOUNT=1 \
    -e TILLANDSIAS_GIT_NAME=fixture -e TILLANDSIAS_GIT_EMAIL=fixture@tillandsias.invalid \
    -v "$site:/home/forge/src/site:Z" "$TAG" >/dev/null
}
run_lane --name "$name" --network none
probe() { podman exec "$name" node -e "$1" 2>&1; }
up=no
for _ in $(seq 1 60); do
  probe 'fetch("http://127.0.0.1:4096/healthz").then(r=>process.exit(r.ok?0:1),()=>process.exit(1))' >/dev/null && { up=yes; break; }
  sleep 1
done
[ "$up" = yes ] || { podman logs "$name" 2>&1 | tail -20; echo "FAIL: the studio front never answered on :4096"; exit 1; }

save() { probe "fetch(\"http://127.0.0.1:4096/__studio/save\",{method:\"POST\",headers:{\"content-type\":\"application/json\"},body:JSON.stringify({path:\"$1\",content:\"$2\"})}).then(async r=>console.log(r.status))"; }
vendor=$(probe 'fetch("http://127.0.0.1:4096/vendor/dist/grapes.min.js").then(async r=>console.log(r.status,(await r.text()).length>100000?"big":"small"))')
editor=$(probe 'fetch("http://127.0.0.1:4096/").then(async r=>{const t=await r.text();console.log(r.status,/https?:\/\//.test(t.replace(/<!--[\s\S]*?-->/g,""))?"external-url":"self-contained")})')
loaded=$(probe 'fetch("http://127.0.0.1:4096/load").then(async r=>console.log(JSON.stringify(await r.json())))')
stored=$(save index.html '<!doctype html><html><body><h1>After</h1></body></html>\n')
refused=$(save notes.txt 'outside the allowlist')
egress=$(probe 'fetch("https://registry.npmjs.org/").then(()=>console.log("reached"),()=>console.log("blocked"))')
echo "forge=$FORGE_IMAGE"; echo "vendor=$vendor"; echo "editor=$editor"; echo "load=$loaded"
echo "save=$stored"; echo "refused-save=$refused"; echo "egress=$egress"

fail=0
[ "$vendor" = "200 big" ] || { echo "FAIL: vendored grapes.min.js not served through the front"; fail=1; }
[ "$editor" = "200 self-contained" ] || { echo "FAIL: editor page references an external URL"; fail=1; }
grep -q 'Before' <<<"$loaded" || { echo "FAIL: /load did not return the project's page"; fail=1; }
[ "$stored" = "200" ] || { echo "FAIL: the shared endpoint refused index.html"; fail=1; }
grep -q 'After' "$site/index.html" && ! grep -q 'Before' "$site/index.html" || { echo "FAIL: the save did not reach index.html"; fail=1; }
subject="$(git -C "$site" log -1 --format=%s)"
changed="$(git -C "$site" diff --name-only "$base" HEAD | tr '\n' ' ')"
echo "commit=$subject"; echo "changed=$changed"
[ "$subject" = "studio(grapesjs): save index.html" ] || { echo "FAIL: the save was not committed by the front"; fail=1; }
[ "$changed" = "index.html " ] || { echo "FAIL: the commit touched more than index.html"; fail=1; }
[ "${refused:-}" != "200" ] && [ -n "$refused" ] || { echo "FAIL: a path outside the allowlist was accepted"; fail=1; }
[ ! -e "$site/notes.txt" ] || { echo "FAIL: the refused save wrote notes.txt"; fail=1; }
[ "$egress" = "blocked" ] || { echo "FAIL: the studio reached the network"; fail=1; }
podman rm -f "$name" >/dev/null 2>&1 || true

# Browser arm: the real editor in headless chromium, in a pod with no network,
# makes one edit (#selftest) that its own storage saves through the front.
CHROMIUM_IMAGE="${TILLANDSIAS_TEST_CHROMIUM_IMAGE:-localhost/tillandsias-chromium-framework:v$VERSION}"
podman image exists "$CHROMIUM_IMAGE" || CHROMIUM_IMAGE="$(local_tag localhost/tillandsias-chromium-framework)"
if [ -n "$CHROMIUM_IMAGE" ] && podman image exists "$CHROMIUM_IMAGE"; then
  podman pod create --name "$pod" --network none --userns keep-id >/dev/null
  podman run -d --rm --pod "$pod" --entrypoint /usr/local/bin/studio-grapesjs \
    -e TILLANDSIAS_STUDIO=grapesjs -e TILLANDSIAS_PROJECT=site -e TILLANDSIAS_PROJECT_HOST_MOUNT=1 \
    -e TILLANDSIAS_GIT_NAME=fixture -e TILLANDSIAS_GIT_EMAIL=fixture@tillandsias.invalid \
    -v "$site:/home/forge/src/site:Z" "$TAG" >/dev/null
  sleep 5
  podman run --rm --pod "$pod" --entrypoint chromium-browser "$CHROMIUM_IMAGE" \
    --headless=new --no-sandbox --disable-gpu --virtual-time-budget=15000 --dump-dom "http://127.0.0.1:4096/#selftest" > "$work/dom" 2>/dev/null || true
  sleep 2
  if grep -q "studio-selftest" "$site/index.html"; then echo "browser-arm=stored"; else echo "browser-arm=not-stored"; echo "FAIL: the editor in a browser did not save its edit"; fail=1; fi
  [ -f "$site/.tillandsias/studio/grapesjs/project.json" ] || { echo "FAIL: project data not saved under .tillandsias/studio/grapesjs"; fail=1; }
  grep -q "gjs-editor" "$work/dom" && echo "editor-dom=initialised" || { echo "FAIL: GrapesJS did not initialise in the browser"; fail=1; }
else
  echo "browser-arm=could-not-run:no-chromium-image:$CHROMIUM_IMAGE"
fi

[ "$fail" -eq 0 ] && echo "PASS: the GrapesJS lane saves through the shared endpoint as a commit, refuses outside its allowlist, no egress"
exit "$fail"
