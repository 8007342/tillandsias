#!/usr/bin/env bash
# @trace order:1863-dmke
# Litmus: the TinaCMS studio image runs `tinacms dev` in LOCAL mode (no Tina
# Cloud, telemetry off) on a Next.js markdown checkout, and a document saved
# through Tina's local GraphQL endpoint, reached through the studio front,
# lands in the checkout as a git diff. Tina's servers listen on loopback only
# and the run has zero egress (to tina.io or anywhere): --network none.
#
# Builds images/web-studio-tina (the build fetches the package-lock'd tree;
# the RUN of the studio has no network).
# Exit: 0 pass, 1 fail, 3 could-not-run (no podman, or the build cannot fetch).
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="localhost/tillandsias-web-studio-tina:v$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
command -v podman >/dev/null 2>&1 || { echo "could-not-run:web-studio-tina:no-podman"; exit 3; }
err="${TMPDIR:-/tmp}/web-studio-tina-build.$$.err"
if ! podman build -q -t "$TAG" "$PROJECT_ROOT/images/web-studio-tina" >/dev/null 2>"$err"; then
  if grep -qE 'fetch https://registry.npmjs.org|ENOTFOUND|EAI_AGAIN' "$err"; then
    echo "could-not-run:web-studio-tina:registry-fetch-failed"; rm -f "$err"; exit 3
  fi
  cat "$err"; rm -f "$err"; echo "FAIL: Tina studio image did not build"; exit 1
fi
rm -f "$err"

work="$(mktemp -d "${TMPDIR:-/tmp}/web-studio-tina.XXXXXX")"
name="web-studio-tina-test-$$"
trap 'podman rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
git -C "$work" init -q
mkdir -p "$work/content/posts" "$work/tina"
printf '{ "name": "fixture", "private": true, "dependencies": { "next": "15.0.0", "react": "19.0.0", "tinacms": "3.15.1" } }\n' > "$work/package.json"
printf -- '---\ntitle: Before\n---\nThe old body.\n' > "$work/content/posts/hello.md"
cat > "$work/tina/config.ts" <<'TS'
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
git -C "$work" add -A
git -C "$work" -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -m site

podman run -d --rm --name "$name" --network none --userns keep-id:uid=1001,gid=1001 \
  -v "$work:/project:Z" "$TAG" >/dev/null
for _ in $(seq 1 180); do
  podman exec "$name" node -e 'fetch("http://127.0.0.1:8090/healthz").then(r=>process.exit(r.ok?0:1),()=>process.exit(1))' 2>/dev/null && break
  sleep 1
done

gql() { podman exec "$name" node -e "fetch(\"http://127.0.0.1:8090/graphql\",{method:\"POST\",headers:{\"content-type\":\"application/json\"},body:JSON.stringify($1)}).then(async r=>console.log(r.status,await r.text()))" 2>&1; }
health=$(podman exec "$name" node -e 'fetch("http://127.0.0.1:8090/healthz").then(r=>console.log(r.status),()=>console.log("down"))' 2>&1)
listed=$(gql '{query:"{ postConnection { edges { node { _sys { relativePath } title } } } }"}')
saved=$(gql '{query:"mutation($r:String!,$p:DocumentUpdateMutation!){ updateDocument(collection:\"post\", relativePath:$r, params:$p){ __typename } }",variables:{r:"hello.md",p:{post:{title:"After",body:{type:"root",children:[{type:"p",children:[{type:"text",text:"The new body, saved through Tina."}]}]}}}}}')
# Tina's listeners from the kernel (LISTEN = 0A), excluding the studio front's
# own :8090 (1F9A). Loopback is 0100007F (v4) or ::1 (v6).
listeners=$(podman exec "$name" sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' | awk '$4 == "0A" && $2 !~ /:1F9A$/ {print $2}' | sort -u | tr '\n' ' ')
egress=$(podman exec "$name" node -e 'fetch("https://content.tinajs.io/").then(()=>console.log("reached"),()=>console.log("blocked"))' 2>&1)
echo "health=$health"; echo "list=$listed"; echo "save=$saved"; echo "tina-listeners=$listeners"; echo "egress=$egress"
echo "repo-changes=$(git -C "$work" status --porcelain | awk '{print $2}' | sort | tr '\n' ' ')"

fail=0
[ "$health" = "200" ] || { echo "FAIL: the studio never became healthy (tinacms dev did not answer)"; fail=1; }
grep -q 'hello.md' <<<"$listed" || { echo "FAIL: Tina did not list the post"; fail=1; }
grep -q '"updateDocument":{"__typename":"Post"}' <<<"$saved" || { echo "FAIL: updateDocument refused"; fail=1; }
grep -q 'title: After' "$work/content/posts/hello.md" && grep -q 'saved through Tina' "$work/content/posts/hello.md" \
  || { echo "FAIL: the saved document did not reach content/posts/hello.md"; fail=1; }
git -C "$work" diff --quiet -- content/posts/hello.md && { echo "FAIL: no git diff on the post"; fail=1; }
[ -n "$listeners" ] || { echo "FAIL: tinacms dev is not listening at all"; fail=1; }
for l in $listeners; do
  case "$l" in
    0100007F:* | 00000000000000000000000001000000:*) ;;
    *) echo "FAIL: a Tina server listens beyond loopback ($l)"; fail=1 ;;
  esac
done
[ "$egress" = "blocked" ] || { echo "FAIL: the studio reached the network"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: Tina studio saves a document through local GraphQL as a repo diff, loopback only, no egress"
exit "$fail"
