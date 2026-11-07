#!/usr/bin/env bash
# @trace order:1863-dmke, order:1860-auhm
# Litmus: the TinaCMS studio LANE in LOCAL mode (no Tina Cloud, telemetry off).
# studio-tina is built from images/studio/Containerfile.tina on the local forge
# image, as the launcher builds it on first use, and run with its registry
# entry and --network none on a Next.js markdown checkout. A document saved
# through Tina's local GraphQL, reached through the studio front (:4096), must
# land in content/posts/hello.md as a `studio(tina): save` commit touching
# nothing else, and the files tinacms dev writes at startup are left alone
# (a write OUTSIDE the allowlist being put back is front arm 5,
# scripts/lua/test-studio-front.lua). Tina's servers listen
# on loopback only and the run has zero egress (to tina.io or anywhere).
#
# Exit: 0 pass, 1 fail, 3 could-not-run (no podman, no local forge image, or
# the build cannot reach the npm registry).
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
TAG="localhost/tillandsias-studio-tina:test-$$"
command -v podman >/dev/null 2>&1 || { echo "could-not-run:studio-tina:no-podman"; exit 3; }
# Any local tag of an image when this VERSION's is absent (as test-studio-front.lua).
local_tag() { podman images --format '{{.Repository}}:{{.Tag}}' --filter "reference=$1" | awk '!/<none>/ { print; exit }'; }
FORGE_IMAGE="${TILLANDSIAS_TEST_FORGE_IMAGE:-localhost/tillandsias-forge:v$VERSION}"
podman image exists "$FORGE_IMAGE" || FORGE_IMAGE="$(local_tag localhost/tillandsias-forge)"
[ -n "$FORGE_IMAGE" ] && podman image exists "$FORGE_IMAGE" || { echo "could-not-run:studio-tina:no-local-forge-image"; exit 3; }

work="$(mktemp -d "${TMPDIR:-/tmp}/studio-tina.XXXXXX")"
name="studio-tina-test-$$"
trap 'podman rm -f "$name" >/dev/null 2>&1 || true; podman rmi -f "$TAG" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
err="$work.build.err"
if ! podman build -q -t "$TAG" --build-arg "FORGE_IMAGE=$FORGE_IMAGE" \
     -f "$PROJECT_ROOT/images/studio/Containerfile.tina" "$PROJECT_ROOT/images/studio" >/dev/null 2>"$err"; then
  if grep -qE 'fetch https://registry.npmjs.org|ENOTFOUND|EAI_AGAIN' "$err"; then
    echo "could-not-run:studio-tina:registry-fetch-failed"; rm -f "$err"; exit 3
  fi
  cat "$err"; rm -f "$err"; echo "FAIL: studio-tina did not build on $FORGE_IMAGE"; exit 1
fi
rm -f "$err"

site="$work/site"
mkdir -p "$site/content/posts" "$site/tina"
git -C "$site" init -q
printf '{ "name": "fixture", "private": true, "dependencies": { "next": "15.0.0", "react": "19.0.0", "tinacms": "3.15.1" } }\n' > "$site/package.json"
printf -- '---\ntitle: Before\n---\nThe old body.\n' > "$site/content/posts/hello.md"
cat > "$site/tina/config.ts" <<'TS'
import { defineConfig } from "tinacms";
export default defineConfig({
  branch: "main",
  clientId: null,
  token: null,
  build: { outputFolder: "admin", publicFolder: "public" },
  media: { tina: { mediaRoot: "", publicFolder: "public" } },
  schema: {
    collections: [
      {
        name: "post",
        label: "Posts",
        path: "content/posts",
        format: "md",
        fields: [
          { type: "string", name: "title", label: "Title", isTitle: true, required: true },
          { type: "rich-text", name: "body", label: "Body", isBody: true },
        ],
      },
    ],
  },
});
TS
git -C "$site" add -A
git -C "$site" -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -m site
base="$(git -C "$site" rev-parse HEAD)"

# The launcher's argv for a studio lane (apply_web_lane) and the git identity
# it passes (configure_git_identity), without which the front cannot commit.
podman run -d --rm --name "$name" --network none --userns keep-id --entrypoint /usr/local/bin/studio-tina \
  -e TILLANDSIAS_STUDIO=tina -e TILLANDSIAS_PROJECT=site -e TILLANDSIAS_PROJECT_HOST_MOUNT=1 \
  -e TILLANDSIAS_GIT_NAME=fixture -e TILLANDSIAS_GIT_EMAIL=fixture@tillandsias.invalid \
  -v "$site:/home/forge/src/site:Z" "$TAG" >/dev/null
probe() { podman exec "$name" node -e "$1" 2>&1; }
up=no
for _ in $(seq 1 180); do
  probe 'fetch("http://127.0.0.1:4096/healthz").then(r=>process.exit(r.ok?0:1),()=>process.exit(1))' >/dev/null && { up=yes; break; }
  sleep 1
done
[ "$up" = yes ] || { podman logs "$name" 2>&1 | tail -30; echo "FAIL: the studio front never answered on :4096 (tinacms dev did not start)"; exit 1; }

gql() { probe "fetch(\"http://127.0.0.1:4096/graphql\",{method:\"POST\",headers:{\"content-type\":\"application/json\"},body:JSON.stringify($1)}).then(async r=>console.log(r.status,await r.text()))"; }
listed=$(gql '{query:"{ postConnection { edges { node { _sys { relativePath } title } } } }"}')
# Anything git sees as changed before the save is Tina's own startup output,
# not the save; it must survive the bracket untouched.
startup="$(git -C "$site" status --porcelain | tr '\n' ' ')"
saved=$(gql '{query:"mutation($r:String!,$p:DocumentUpdateMutation!){ updateDocument(collection:\"post\", relativePath:$r, params:$p){ __typename } }",variables:{r:"hello.md",p:{post:{title:"After",body:{type:"root",children:[{type:"p",children:[{type:"text",text:"The new body, saved through Tina."}]}]}}}}}')
after_save="$(git -C "$site" rev-parse HEAD)"
# Tina's listeners from the kernel (LISTEN = 0A), excluding the studio front's
# own :4096 (1000). Loopback is 0100007F (v4) or ::1 (v6).
listeners=$(podman exec "$name" sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' | awk '$4 == "0A" && $2 !~ /:1000$/ {print $2}' | sort -u | tr '\n' ' ')
egress=$(probe 'fetch("https://content.tinajs.io/").then(()=>console.log("reached"),()=>console.log("blocked"))')
subject="$(git -C "$site" log -1 --format=%s "$after_save")"
changed="$(git -C "$site" diff --name-only "$base" "$after_save" | tr '\n' ' ')"
echo "forge=$FORGE_IMAGE"; echo "list=$listed"; echo "startup-changes=$startup"; echo "save=$saved"
echo "commit=$subject"; echo "changed=$changed"; echo "tina-listeners=$listeners"; echo "egress=$egress"
echo "status=$(git -C "$site" status --porcelain | tr '\n' ' ')"

fail=0
grep -q 'hello.md' <<<"$listed" || { echo "FAIL: Tina did not list the post"; fail=1; }
grep -q '"updateDocument":{"__typename":"Post"}' <<<"$saved" || { echo "FAIL: updateDocument refused"; fail=1; }
grep -q 'title: After' "$site/content/posts/hello.md" && grep -q 'saved through Tina' "$site/content/posts/hello.md" \
  || { echo "FAIL: the saved document did not reach content/posts/hello.md"; fail=1; }
[ "$subject" = "studio(tina): save content/posts/hello.md" ] || { echo "FAIL: the front did not commit the document"; fail=1; }
[ "$changed" = "content/posts/hello.md " ] || { echo "FAIL: the save commit touched more than the document"; fail=1; }
[ -n "$listeners" ] || { echo "FAIL: tinacms dev is not listening at all"; fail=1; }
for l in $listeners; do
  case "$l" in
    0100007F:* | 00000000000000000000000001000000:*) ;;
    *) echo "FAIL: a Tina server listens beyond loopback ($l)"; fail=1 ;;
  esac
done
[ "$egress" = "blocked" ] || { echo "FAIL: the studio reached the network"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: the Tina lane commits a document saved through local GraphQL via the front, loopback only, no egress"
exit "$fail"
