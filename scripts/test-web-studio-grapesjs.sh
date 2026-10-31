#!/usr/bin/env bash
# @trace order:1861-nmpp
# Litmus: the GrapesJS studio image serves the vendored core (no CDN), loads a
# static project's page, and an edit stored through its endpoint lands in the
# project checkout as a git diff. The studio runs with --network none.
#
# Builds images/web-studio-grapesjs (the build fetches and verifies the pinned
# GrapesJS tarball; the RUN of the studio has no network).
# Exit: 0 pass, 1 fail, 3 could-not-run (no podman, or the build cannot fetch).
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="localhost/tillandsias-web-studio-grapesjs:v$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
command -v podman >/dev/null 2>&1 || { echo "could-not-run:web-studio:no-podman"; exit 3; }
if ! podman build -q -t "$TAG" "$PROJECT_ROOT/images/web-studio-grapesjs" >/dev/null 2>"${TMPDIR:-/tmp}/web-studio-build.err"; then
  if grep -q 'fetch https://registry.npmjs.org' "${TMPDIR:-/tmp}/web-studio-build.err"; then
    echo "could-not-run:web-studio:tarball-fetch-failed"; exit 3
  fi
  cat "${TMPDIR:-/tmp}/web-studio-build.err"; echo "FAIL: studio image did not build"; exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/web-studio.XXXXXX")"
name="web-studio-test-$$"
trap 'podman rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
git -C "$work" init -q
printf '<!doctype html>\n<html><body>\n<h1>Before</h1>\n</body></html>\n' > "$work/index.html"
git -C "$work" add -A
git -C "$work" -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -m site

podman run -d --rm --name "$name" --network none --userns keep-id:uid=1001,gid=1001 \
  -v "$work:/project:Z" "$TAG" >/dev/null
for _ in $(seq 1 30); do
  podman exec "$name" node -e 'fetch("http://127.0.0.1:8090/healthz").then(r=>process.exit(r.ok?0:1),()=>process.exit(1))' 2>/dev/null && break
  sleep 1
done

probe() { podman exec "$name" node -e "$1" 2>&1; }
vendor=$(probe 'fetch("http://127.0.0.1:8090/vendor/dist/grapes.min.js").then(async r=>console.log(r.status,(await r.text()).length>100000?"big":"small"))')
editor=$(probe 'fetch("http://127.0.0.1:8090/").then(async r=>{const t=await r.text();console.log(r.status,/https?:\/\//.test(t.replace(/<!--[\s\S]*?-->/g,""))?"external-url":"self-contained")})')
loaded=$(probe 'fetch("http://127.0.0.1:8090/load").then(async r=>console.log(JSON.stringify(await r.json())))')
stored=$(probe 'fetch("http://127.0.0.1:8090/store",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({html:"<h1>After</h1>",css:"h1{color:teal}",projectData:{pages:[]}})}).then(async r=>console.log(r.status,await r.text()))')
egress=$(probe 'fetch("https://registry.npmjs.org/").then(()=>console.log("reached"),()=>console.log("blocked"))')
echo "vendor=$vendor"; echo "editor=$editor"; echo "load=$loaded"; echo "store=$stored"; echo "egress=$egress"
diff_names=$(git -C "$work" status --porcelain | awk '{print $2}' | sort | tr '\n' ' ')
echo "repo-changes=$diff_names"

fail=0
[ "$vendor" = "200 big" ] || { echo "FAIL: vendored grapes.min.js not served"; fail=1; }
[ "$editor" = "200 self-contained" ] || { echo "FAIL: editor page references an external URL"; fail=1; }
grep -q 'Before' <<<"$loaded" || { echo "FAIL: /load did not return the project's page"; fail=1; }
grep -q '^200 ' <<<"$stored" || { echo "FAIL: /store refused"; fail=1; }
[ "$egress" = "blocked" ] || { echo "FAIL: the studio reached the network"; fail=1; }
grep -q 'After' "$work/index.html" && ! grep -q 'Before' "$work/index.html" || { echo "FAIL: the edit did not reach index.html"; fail=1; }
grep -q 'teal' "$work/styles.css" 2>/dev/null || { echo "FAIL: styles.css missing the edit"; fail=1; }
git -C "$work" diff --quiet -- index.html && { echo "FAIL: no git diff on index.html"; fail=1; }
# Browser arm: the real editor in headless chromium, in a pod with no network,
# makes one edit (#selftest) that its own autosave stores through /store.
CHROMIUM_IMAGE="${TILLANDSIAS_TEST_CHROMIUM_IMAGE:-localhost/tillandsias-chromium-framework:v$(tr -d "[:space:]" < "$PROJECT_ROOT/VERSION")}"
if podman image exists "$CHROMIUM_IMAGE"; then
  pod="web-studio-pod-$$"
  podman pod create --name "$pod" --network none --userns keep-id:uid=1001,gid=1001 >/dev/null
  trap 'podman pod rm -f "$pod" >/dev/null 2>&1 || true; podman rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
  podman run -d --rm --pod "$pod" -v "$work:/project:Z" "$TAG" >/dev/null
  sleep 3
  podman run --rm --pod "$pod" --entrypoint chromium-browser "$CHROMIUM_IMAGE" \
    --headless=new --no-sandbox --disable-gpu --virtual-time-budget=15000 --dump-dom "http://127.0.0.1:8090/#selftest" > "$work.dom" 2>/dev/null || true
  sleep 2
  if grep -q "studio-selftest" "$work/index.html"; then echo "browser-arm=stored"; else echo "browser-arm=not-stored"; echo "FAIL: the editor in a browser did not store its edit"; fail=1; fi
  grep -q "gjs-editor" "$work.dom" && echo "editor-dom=initialised" || { echo "FAIL: GrapesJS did not initialise in the browser"; fail=1; }
  rm -f "$work.dom"
else
  echo "browser-arm=could-not-run:no-chromium-image:$CHROMIUM_IMAGE"
fi

[ "$fail" -eq 0 ] && echo "PASS: GrapesJS studio stores an edit as a repo diff with no egress"
exit "$fail"
