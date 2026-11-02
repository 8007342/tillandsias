#!/usr/bin/env bash
# @trace order:1862-wrx5, order:1860-auhm
# Litmus: the Decap CMS studio LANE. studio-decap is built from
# images/studio/Containerfile.decap on the local forge image, as the launcher
# builds it on first use, and run with its registry entry and --network none
# on a throwaway Hugo checkout. Through the studio front (:4096) it must serve
# the vendored admin UI (no CDN), point Decap's backend at the studio, list the
# Hugo posts, and a persistEntry must land in content/posts/hello.md as a
# `studio(decap): save` commit; a persistEntry writing outside the allowlist
# must be put back and commit nothing. decap-server listens on loopback only.
#
# Exit: 0 pass, 1 fail, 3 could-not-run (no podman, no local forge image, or
# the build cannot reach the npm registry).
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
TAG="localhost/tillandsias-studio-decap:test-$$"
command -v podman >/dev/null 2>&1 || { echo "could-not-run:studio-decap:no-podman"; exit 3; }
# Any local tag of an image when this VERSION's is absent (as test-studio-front.lua).
local_tag() { podman images --format '{{.Repository}}:{{.Tag}}' --filter "reference=$1" | awk '!/<none>/ { print; exit }'; }
FORGE_IMAGE="${TILLANDSIAS_TEST_FORGE_IMAGE:-localhost/tillandsias-forge:v$VERSION}"
podman image exists "$FORGE_IMAGE" || FORGE_IMAGE="$(local_tag localhost/tillandsias-forge)"
[ -n "$FORGE_IMAGE" ] && podman image exists "$FORGE_IMAGE" || { echo "could-not-run:studio-decap:no-local-forge-image"; exit 3; }

work="$(mktemp -d "${TMPDIR:-/tmp}/studio-decap.XXXXXX")"
name="studio-decap-test-$$"
trap 'podman rm -f "$name" >/dev/null 2>&1 || true; podman rmi -f "$TAG" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
err="$work.build.err"
if ! podman build -q -t "$TAG" --build-arg "FORGE_IMAGE=$FORGE_IMAGE" \
     -f "$PROJECT_ROOT/images/studio/Containerfile.decap" "$PROJECT_ROOT/images/studio" >/dev/null 2>"$err"; then
  if grep -qE 'fetch https://registry.npmjs.org|ENOTFOUND|EAI_AGAIN' "$err"; then
    echo "could-not-run:studio-decap:registry-fetch-failed"; rm -f "$err"; exit 3
  fi
  cat "$err"; rm -f "$err"; echo "FAIL: studio-decap did not build on $FORGE_IMAGE"; exit 1
fi
rm -f "$err"

site="$work/site"
mkdir -p "$site/content/posts"
git -C "$site" init -q
printf 'baseURL = "https://example.invalid/"\ntitle = "fixture"\n' > "$site/hugo.toml"
printf -- '---\ntitle: Before\ndate: 2026-11-01T00:00:00Z\n---\nThe old body.\n' > "$site/content/posts/hello.md"
git -C "$site" add -A
git -C "$site" -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -m site
base="$(git -C "$site" rev-parse HEAD)"

# The launcher's argv for a studio lane (apply_web_lane) and the git identity
# it passes (configure_git_identity), without which the front cannot commit.
podman run -d --rm --name "$name" --network none --userns keep-id --entrypoint /usr/local/bin/studio-decap \
  -e TILLANDSIAS_STUDIO=decap -e TILLANDSIAS_PROJECT=site -e TILLANDSIAS_PROJECT_HOST_MOUNT=1 \
  -e TILLANDSIAS_GIT_NAME=fixture -e TILLANDSIAS_GIT_EMAIL=fixture@tillandsias.invalid \
  -v "$site:/home/forge/src/site:Z" "$TAG" >/dev/null
probe() { podman exec "$name" node -e "$1" 2>&1; }
up=no
for _ in $(seq 1 60); do
  probe 'fetch("http://127.0.0.1:4096/healthz").then(r=>process.exit(r.ok?0:1),()=>process.exit(1))' >/dev/null && { up=yes; break; }
  sleep 1
done
[ "$up" = yes ] || { podman logs "$name" 2>&1 | tail -20; echo "FAIL: the studio front never answered on :4096"; exit 1; }

api() { probe "fetch(\"http://127.0.0.1:4096/api/v1\",{method:\"POST\",headers:{\"content-type\":\"application/json\"},body:JSON.stringify($1)}).then(async r=>console.log(r.status,await r.text()))"; }
json() { printf '%s' "$1" | podman exec -i "$name" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))'; }
persist() { api "{action:\"persistEntry\",params:{branch:\"main\",dataFiles:[{slug:\"$2\",path:\"$1\",raw:$(json "$3")}],assets:[],options:{collectionName:\"posts\",commitMessage:\"Update $2\",useWorkflow:false,status:\"draft\"}}}"; }
bundle=$(probe 'fetch("http://127.0.0.1:4096/admin/decap-cms.js").then(async r=>console.log(r.status,(await r.text()).length>1000000?"big":"small"))')
admin=$(probe 'fetch("http://127.0.0.1:4096/admin/").then(async r=>{const t=await r.text();console.log(r.status,/https?:\/\//.test(t)?"external-url":"self-contained")})')
config=$(probe 'fetch("http://127.0.0.1:4096/admin/config.yml").then(async r=>console.log(r.status,JSON.stringify(await r.text())))')
listed=$(api '{action:"entriesByFolder",params:{branch:"main",folder:"content/posts",extension:"md",depth:1}}')
stored=$(persist content/posts/hello.md hello $'---\ntitle: After\ndate: 2026-11-02T00:00:00Z\n---\nThe new body, saved through Decap.\n')
after_save="$(git -C "$site" rev-parse HEAD)"
offlist=$(persist notes.md notes $'---\ntitle: Off the allowlist\n---\n')
# decap-server's listeners, from the kernel: 8081 is 1F91; 127.0.0.1 is
# 0100007F; LISTEN is state 0A. Anything else bound to 8081 is a leak.
listeners=$(podman exec "$name" sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' | awk '$2 ~ /:1F91$/ && $4 == "0A" {print $2}' | sort -u | tr '\n' ' ')
egress=$(probe 'fetch("https://registry.npmjs.org/").then(()=>console.log("reached"),()=>console.log("blocked"))')
subject="$(git -C "$site" log -1 --format=%s "$after_save")"
changed="$(git -C "$site" diff --name-only "$base" "$after_save" | tr '\n' ' ')"
echo "forge=$FORGE_IMAGE"; echo "bundle=$bundle"; echo "admin=$admin"; echo "config=$config"
echo "list=$listed"; echo "store=$stored"; echo "offlist=$offlist"; echo "commit=$subject"; echo "changed=$changed"
echo "decap-listeners=$listeners"; echo "egress=$egress"; echo "status=$(git -C "$site" status --porcelain | tr '\n' ' ')"

fail=0
[ "$bundle" = "200 big" ] || { echo "FAIL: vendored decap-cms.js not served through the front"; fail=1; }
[ "$admin" = "200 self-contained" ] || { echo "FAIL: the admin page references an external URL"; fail=1; }
grep -q 'proxy_url: /api/v1' <<<"$config" || { echo "FAIL: config.yml does not point the backend at the studio"; fail=1; }
grep -q 'content/posts/hello.md' <<<"$listed" || { echo "FAIL: entriesByFolder did not list the Hugo post"; fail=1; }
grep -q '^200 ' <<<"$stored" || { echo "FAIL: persistEntry refused"; fail=1; }
grep -q 'title: After' "$site/content/posts/hello.md" && ! grep -q 'Before' "$site/content/posts/hello.md" \
  || { echo "FAIL: the saved entry did not reach content/posts/hello.md"; fail=1; }
[ "$subject" = "studio(decap): save content/posts/hello.md" ] || { echo "FAIL: the front did not commit the entry"; fail=1; }
[ "$changed" = "content/posts/hello.md " ] || { echo "FAIL: the save commit touched more than the entry"; fail=1; }
grep -q '^403 ' <<<"$offlist" || { echo "FAIL: a write outside the allowlist was reported saved"; fail=1; }
[ ! -e "$site/notes.md" ] || { echo "FAIL: a write outside the allowlist was kept"; fail=1; }
[ "$(git -C "$site" rev-parse HEAD)" = "$after_save" ] || { echo "FAIL: the off-allowlist write was committed"; fail=1; }
podman logs "$name" 2>/dev/null | grep -q 'event:studio.save_refused .*path=notes.md' || { echo "FAIL: the refused write was not evented"; fail=1; }
[ -n "$listeners" ] || { echo "FAIL: decap-server is not listening at all"; fail=1; }
for l in $listeners; do
  case "$l" in
    0100007F:1F91 | 00000000000000000000000001000000:1F91) ;;
    *) echo "FAIL: decap-server listens beyond loopback ($l)"; fail=1 ;;
  esac
done
[ "$egress" = "blocked" ] || { echo "FAIL: the studio reached the network"; fail=1; }
# .cache/ is the forge's command-policy audit log: a forge image older than
# 1788-qlwq slice 7 writes it into any checkout, not only a Tillandsias one.
[ -z "$(git -C "$site" status --porcelain | grep -v '^?? \.cache/$')" ] || { echo "FAIL: the lane left files in the checkout"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: the Decap lane commits a Hugo entry through the front, puts back a write outside its allowlist, decap-server on loopback only, no egress"
exit "$fail"
