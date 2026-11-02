#!/usr/bin/env bash
# @trace order:1864-ay3x
# Litmus: the Puck studio's shared write-back endpoint stores the page data
# Puck's onPublish hands it as JSON in the project checkout, ONLY under the
# lane's write allowlist (.tillandsias/studio/puck/**), and refuses a write
# anywhere else (source files, a path escaping the checkout, a non-JSON
# file), leaving the checkout untouched. The studio runs with --network none.
#
# Builds images/web-studio-puck (two stages: esbuild bundles Puck + React 19 in
# a DISCARDED builder stage) and runs the final image on a throwaway React
# checkout. Also checks the operator's build-time-only rule: the final image has
# no esbuild and no node_modules, and React exists only inside the bundle.
# Exit: 0 pass, 1 fail, 3 could-not-run (no podman, or the build cannot fetch).
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="localhost/tillandsias-web-studio-puck:v$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
command -v podman >/dev/null 2>&1 || { echo "could-not-run:web-studio-puck:no-podman"; exit 3; }
err="${TMPDIR:-/tmp}/web-studio-puck-build.$$.err"
if ! podman build -q -t "$TAG" "$PROJECT_ROOT/images/web-studio-puck" >/dev/null 2>"$err"; then
  if grep -qE 'fetch https://registry.npmjs.org|ENOTFOUND|EAI_AGAIN' "$err"; then
    echo "could-not-run:web-studio-puck:registry-fetch-failed"; rm -f "$err"; exit 3
  fi
  cat "$err"; rm -f "$err"; echo "FAIL: Puck studio image did not build"; exit 1
fi
rm -f "$err"

work="$(mktemp -d "${TMPDIR:-/tmp}/web-studio-puck.XXXXXX")"
name="web-studio-puck-test-$$"
trap 'podman rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
git -C "$work" init -q
mkdir -p "$work/src"
printf '{ "name": "fixture", "private": true, "dependencies": { "react": "19.0.0", "react-dom": "19.0.0" } }\n' > "$work/package.json"
printf 'export default function App() { return <h1>Before</h1>; }\n' > "$work/src/App.jsx"
git -C "$work" add -A
git -C "$work" -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -m site

podman run -d --rm --name "$name" --network none --userns keep-id:uid=1001,gid=1001 \
  -v "$work:/project:Z" "$TAG" >/dev/null
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
page=$(podman exec "$name" node -e 'fetch("http://127.0.0.1:8090/").then(async r=>{const t=await r.text();console.log(r.status,/https?:\/\//.test(t)?"external-url":"self-contained")})' 2>&1)
bundle=$(podman exec "$name" node -e 'fetch("http://127.0.0.1:8090/editor.js").then(async r=>{const t=await r.text();console.log(r.status,t.length>100000?"big":"small",/react\.dev\/errors|Minified React error/.test(t)?"react-inside":"no-react",/onPublish/.test(t)?"puck-inside":"no-puck")})' 2>&1)
# The build-time-only rule: no esbuild file, no node_modules, no React package
# directory anywhere in the FINAL image's filesystem.
leftovers=$(podman run --rm --network none --entrypoint sh "$TAG" -c 'find / -xdev \( -path /proc -o -path /sys \) -prune -o \( -iname "*esbuild*" -o \( -name node_modules -path "/opt/*" \) -o \( -name react-dom -type d \) \) -print 2>/dev/null' | tr '\n' ' ')
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
echo "page=$page"; echo "bundle=$bundle"; echo "final-image-leftovers=${leftovers:-none}"
[ "$page" = "200 self-contained" ] || { echo "FAIL: the editor page is missing or references an external URL"; fail=1; }
[ "$bundle" = "200 big react-inside puck-inside" ] || { echo "FAIL: the bundle does not carry Puck and React"; fail=1; }
[ -z "$leftovers" ] || { echo "FAIL: the final image carries build-time-only files: $leftovers"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: Puck page data is stored under the lane allowlist only, refused elsewhere, no egress"
exit "$fail"
