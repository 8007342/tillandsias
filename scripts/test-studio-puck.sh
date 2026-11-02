#!/usr/bin/env bash
# @trace order:1864-ay3x, order:1860-auhm
# Litmus: the Puck studio LANE. studio-puck is built from
# images/studio/Containerfile.puck (two stages: esbuild bundles Puck + React 19
# in a DISCARDED builder stage; the final stage is the local forge image), as
# the launcher builds it on first use, and run with its registry entry and
# --network none on a throwaway React checkout. The page data Puck's onPublish
# hands over, posted to the shared endpoint /__studio/save through the studio
# front (:4096), must land under .tillandsias/studio/puck/ as a
# `studio(puck): save` commit; a write anywhere else (source files, a path
# escaping the checkout, an absolute path) must be refused and change nothing.
# Also checks the operator's build-time-only rule: the final image has no
# esbuild and no node_modules under /opt, and React exists only inside the bundle.
#
# Exit: 0 pass, 1 fail, 3 could-not-run (no podman, no local forge image, or
# the build cannot reach the npm registry).
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
TAG="localhost/tillandsias-studio-puck:test-$$"
command -v podman >/dev/null 2>&1 || { echo "could-not-run:studio-puck:no-podman"; exit 3; }
# Any local tag of an image when this VERSION's is absent (as test-studio-front.lua).
local_tag() { podman images --format '{{.Repository}}:{{.Tag}}' --filter "reference=$1" | awk '!/<none>/ { print; exit }'; }
FORGE_IMAGE="${TILLANDSIAS_TEST_FORGE_IMAGE:-localhost/tillandsias-forge:v$VERSION}"
podman image exists "$FORGE_IMAGE" || FORGE_IMAGE="$(local_tag localhost/tillandsias-forge)"
[ -n "$FORGE_IMAGE" ] && podman image exists "$FORGE_IMAGE" || { echo "could-not-run:studio-puck:no-local-forge-image"; exit 3; }

work="$(mktemp -d "${TMPDIR:-/tmp}/studio-puck.XXXXXX")"
name="studio-puck-test-$$"
trap 'podman rm -f "$name" >/dev/null 2>&1 || true; podman rmi -f "$TAG" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
err="$work.build.err"
if ! podman build -q -t "$TAG" --build-arg "FORGE_IMAGE=$FORGE_IMAGE" \
     -f "$PROJECT_ROOT/images/studio/Containerfile.puck" "$PROJECT_ROOT/images/studio" >/dev/null 2>"$err"; then
  if grep -qE 'fetch https://registry.npmjs.org|ENOTFOUND|EAI_AGAIN' "$err"; then
    echo "could-not-run:studio-puck:registry-fetch-failed"; rm -f "$err"; exit 3
  fi
  cat "$err"; rm -f "$err"; echo "FAIL: studio-puck did not build on $FORGE_IMAGE"; exit 1
fi
rm -f "$err"

site="$work/site"
mkdir -p "$site/src"
git -C "$site" init -q
printf '{ "name": "fixture", "private": true, "dependencies": { "react": "19.0.0", "react-dom": "19.0.0" } }\n' > "$site/package.json"
printf 'export default function App() { return <h1>Before</h1>; }\n' > "$site/src/App.jsx"
git -C "$site" add -A
git -C "$site" -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -m site
base="$(git -C "$site" rev-parse HEAD)"

# The launcher's argv for a studio lane (apply_web_lane) and the git identity
# it passes (configure_git_identity), without which the front cannot commit.
podman run -d --rm --name "$name" --network none --userns keep-id --entrypoint /usr/local/bin/studio-puck \
  -e TILLANDSIAS_STUDIO=puck -e TILLANDSIAS_PROJECT=site -e TILLANDSIAS_PROJECT_HOST_MOUNT=1 \
  -e TILLANDSIAS_GIT_NAME=fixture -e TILLANDSIAS_GIT_EMAIL=fixture@tillandsias.invalid \
  -v "$site:/home/forge/src/site:Z" "$TAG" >/dev/null
probe() { podman exec "$name" node -e "$1" 2>&1; }
up=no
for _ in $(seq 1 60); do
  probe 'fetch("http://127.0.0.1:4096/healthz").then(r=>process.exit(r.ok?0:1),()=>process.exit(1))' >/dev/null && { up=yes; break; }
  sleep 1
done
[ "$up" = yes ] || { podman logs "$name" 2>&1 | tail -20; echo "FAIL: the studio front never answered on :4096"; exit 1; }

# What the editor's publish() posts: the onPublish data, as JSON text.
data='JSON.stringify({content:[{type:"Heading",props:{id:"Heading-1",title:"After"}}],root:{props:{title:"Home"}}},null,2)+"\n"'
save() { probe "fetch(\"http://127.0.0.1:4096/__studio/save\",{method:\"POST\",headers:{\"content-type\":\"application/json\"},body:JSON.stringify({path:\"$1\",content:$data})}).then(async r=>console.log(r.status,await r.text()))"; }
ok=$(save .tillandsias/studio/puck/pages/home.json)
after_save="$(git -C "$site" rev-parse HEAD)"
src=$(save src/App.jsx)
src_json=$(save src/page.json)
esc=$(save .tillandsias/studio/puck/../../src/App.json)
abs=$(save /etc/passwd.json)
loaded=$(probe 'fetch("http://127.0.0.1:4096/__studio/load?path=.tillandsias/studio/puck/pages/home.json").then(async r=>console.log(r.status,await r.text()))')
egress=$(probe 'fetch("https://registry.npmjs.org/").then(()=>console.log("reached"),()=>console.log("blocked"))')
page=$(probe 'fetch("http://127.0.0.1:4096/").then(async r=>{const t=await r.text();console.log(r.status,/https?:\/\//.test(t)?"external-url":"self-contained")})')
bundle=$(probe 'fetch("http://127.0.0.1:4096/editor.js").then(async r=>{const t=await r.text();console.log(r.status,t.length>100000?"big":"small",/react\.dev\/errors|Minified React error/.test(t)?"react-inside":"no-react",/onPublish/.test(t)?"puck-inside":"no-puck")})')
# The build-time-only rule: no esbuild file, no node_modules under /opt, no
# React package directory anywhere in the FINAL image's filesystem.
leftovers=$(podman run --rm --network none --entrypoint sh "$TAG" -c 'find / -xdev \( -path /proc -o -path /sys \) -prune -o \( -iname "*esbuild*" -o \( -name node_modules -path "/opt/*" \) -o \( -name react-dom -type d \) \) -print 2>/dev/null' | tr '\n' ' ')
subject="$(git -C "$site" log -1 --format=%s "$after_save")"
changed="$(git -C "$site" diff --name-only "$base" HEAD | tr '\n' ' ')"
echo "forge=$FORGE_IMAGE"; echo "save-in-allowlist=$ok"; echo "save-source=$src"; echo "save-json-outside=$src_json"
echo "save-escape=$esc"; echo "save-absolute=$abs"; echo "commit=$subject"; echo "changed=$changed"
echo "load=$loaded"; echo "egress=$egress"; echo "status=$(git -C "$site" status --porcelain --untracked-files=all | tr '\n' ' ')"

fail=0
grep -q '^200 ' <<<"$ok" || { echo "FAIL: the onPublish save under the allowlist was refused"; fail=1; }
grep -q '"title": "After"' "$site/.tillandsias/studio/puck/pages/home.json" 2>/dev/null || { echo "FAIL: the page data JSON is not in the checkout"; fail=1; }
[ "$subject" = "studio(puck): save .tillandsias/studio/puck/pages/home.json" ] || { echo "FAIL: the front did not commit the page data"; fail=1; }
[ "$changed" = ".tillandsias/studio/puck/pages/home.json " ] || { echo "FAIL: the checkout's history changed beyond the one allowed file"; fail=1; }
for v in "$src" "$src_json" "$esc" "$abs"; do
  grep -q '^403 {"refused":"' <<<"$v" || { echo "FAIL: a write outside the allowlist was not refused: $v"; fail=1; }
done
grep -q '"refused":"not-allowlisted"' <<<"$src_json" || { echo "FAIL: the refusal does not name the allowlist"; fail=1; }
[ "$(git -C "$site" rev-parse HEAD)" = "$after_save" ] || { echo "FAIL: a refused write was committed"; fail=1; }
git -C "$site" diff --quiet -- src || { echo "FAIL: a refused write changed src/"; fail=1; }
[ ! -e "$site/src/page.json" ] && [ ! -e "$site/src/App.json" ] || { echo "FAIL: a refused write created a file"; fail=1; }
grep -q '"After"' <<<"$loaded" || { echo "FAIL: /__studio/load did not return the stored page"; fail=1; }
[ "$egress" = "blocked" ] || { echo "FAIL: the studio reached the network"; fail=1; }
echo "page=$page"; echo "bundle=$bundle"; echo "final-image-leftovers=${leftovers:-none}"
[ "$page" = "200 self-contained" ] || { echo "FAIL: the editor page is missing or references an external URL"; fail=1; }
[ "$bundle" = "200 big react-inside puck-inside" ] || { echo "FAIL: the bundle does not carry Puck and React"; fail=1; }
[ -z "$leftovers" ] || { echo "FAIL: the final image carries build-time-only files: $leftovers"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: the Puck lane commits page data through the front under its allowlist only, refused elsewhere, no esbuild in the final image, no egress"
exit "$fail"
