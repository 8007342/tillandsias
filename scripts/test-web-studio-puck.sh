#!/usr/bin/env bash
# @trace order:1864-ay3x
# Litmus: the Puck studio's shared write-back endpoint stores the page data
# Puck's onPublish hands it as JSON in the project checkout, ONLY under the
# lane's write allowlist (.tillandsias/studio/puck/**), and refuses a write
# anywhere else (source files, a path escaping the checkout, a non-JSON
# file), leaving the checkout untouched. The studio runs with --network none.
#
# Runs images/web-studio-puck/server.mjs in the pinned node image on a
# throwaway React checkout. Exit: 0 pass, 1 fail, 3 could-not-run (no podman).
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_IMAGE="docker.io/library/node:22.19.0-bookworm-slim@sha256:4a4884e8a44826194dff92ba316264f392056cbe243dcc9fd3551e71cea02b90"
command -v podman >/dev/null 2>&1 || { echo "could-not-run:web-studio-puck:no-podman"; exit 3; }
podman image exists "$NODE_IMAGE" || podman pull -q "$NODE_IMAGE" >/dev/null 2>&1 \
  || { echo "could-not-run:web-studio-puck:no-node-image"; exit 3; }

work="$(mktemp -d "${TMPDIR:-/tmp}/web-studio-puck.XXXXXX")"
name="web-studio-puck-test-$$"
trap 'podman rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
git -C "$work" init -q
mkdir -p "$work/src"
printf '{ "name": "fixture", "private": true, "dependencies": { "react": "19.0.0", "react-dom": "19.0.0" } }\n' > "$work/package.json"
printf 'export default function App() { return <h1>Before</h1>; }\n' > "$work/src/App.jsx"
git -C "$work" add -A
git -C "$work" -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -m site

podman run -d --rm --name "$name" --network none --userns keep-id \
  -v "$PROJECT_ROOT/images/web-studio-puck/server.mjs:/opt/studio/server.mjs:ro,Z" \
  -v "$work:/project:Z" -e STUDIO_PROJECT=/project -e STUDIO_PORT=8090 \
  --entrypoint node "$NODE_IMAGE" /opt/studio/server.mjs >/dev/null
for _ in $(seq 1 30); do
  podman exec "$name" node -e 'fetch("http://127.0.0.1:8090/healthz").then(r=>process.exit(r.ok?0:1),()=>process.exit(1))' 2>/dev/null && break
  sleep 1
done
save() { podman exec "$name" node -e "fetch(\"http://127.0.0.1:8090/__studio/save\",{method:\"POST\",headers:{\"content-type\":\"application/json\"},body:JSON.stringify($1)}).then(async r=>console.log(r.status,await r.text()))" 2>&1; }
# The shape Puck's onPublish(data) hands over: {content: [...], root: {...}}.
data='{content:[{type:"Heading",props:{id:"Heading-1",title:"After"}}],root:{props:{title:"Home"}}}'
ok=$(save "{path:\".tillandsias/studio/puck/pages/home.json\",data:$data}")
src=$(save "{path:\"src/App.jsx\",data:$data}")
src_json=$(save "{path:\"src/page.json\",data:$data}")
esc=$(save "{path:\".tillandsias/studio/puck/../../src/App.json\",data:$data}")
abs=$(save "{path:\"/etc/passwd.json\",data:$data}")
loaded=$(podman exec "$name" node -e 'fetch("http://127.0.0.1:8090/__studio/load?path=.tillandsias/studio/puck/pages/home.json").then(async r=>console.log(r.status,await r.text()))' 2>&1)
egress=$(podman exec "$name" node -e 'fetch("https://registry.npmjs.org/").then(()=>console.log("reached"),()=>console.log("blocked"))' 2>&1)
echo "save-in-allowlist=$ok"; echo "save-source=$src"; echo "save-json-outside=$src_json"
echo "save-escape=$esc"; echo "save-absolute=$abs"; echo "load=$loaded"; echo "egress=$egress"
echo "repo-changes=$(git -C "$work" status --porcelain --untracked-files=all | awk '{print $2}' | sort | tr '\n' ' ')"

fail=0
grep -q '^200 {"saved":".tillandsias/studio/puck/pages/home.json"}$' <<<"$ok" || { echo "FAIL: the onPublish save under the allowlist was not stored"; fail=1; }
grep -q '"title": "After"' "$work/.tillandsias/studio/puck/pages/home.json" 2>/dev/null || { echo "FAIL: the page data JSON is not in the checkout"; fail=1; }
for v in "$src" "$src_json" "$esc" "$abs"; do
  grep -q '^403 {"error":"refused: ' <<<"$v" || { echo "FAIL: a write outside the allowlist was not refused: $v"; fail=1; }
done
grep -q 'outside the lane allowlist' <<<"$src_json" || { echo "FAIL: the refusal does not name the allowlist"; fail=1; }
git -C "$work" diff --quiet -- src || { echo "FAIL: a refused write changed src/"; fail=1; }
[ ! -e "$work/src/page.json" ] && [ ! -e "$work/src/App.json" ] || { echo "FAIL: a refused write created a file"; fail=1; }
[ "$(git -C "$work" status --porcelain --untracked-files=all | awk '{print $2}' | tr -d '\n')" = ".tillandsias/studio/puck/pages/home.json" ] \
  || { echo "FAIL: the checkout changed beyond the one allowed file"; fail=1; }
grep -q '"After"' <<<"$loaded" || { echo "FAIL: /__studio/load did not return the stored page"; fail=1; }
[ "$egress" = "blocked" ] || { echo "FAIL: the studio reached the network"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: Puck page data is stored under the lane allowlist only, refused elsewhere, no egress"
exit "$fail"
