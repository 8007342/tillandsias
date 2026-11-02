#!/usr/bin/env bash
# @trace order:1862-wrx5
# Litmus: the Decap CMS studio image serves the vendored admin UI (no CDN),
# lists a Hugo project's posts through decap-server, and an entry saved
# through the studio's /api/v1 lands in the project checkout as a git diff.
# decap-server listens on loopback only, so the studio front is the one way
# in. The studio runs with --network none.
#
# Builds images/web-studio-decap (the build fetches and verifies the pinned
# decap-cms tarball and the package-lock'd decap-server tree; the RUN of the
# studio has no network).
# Exit: 0 pass, 1 fail, 3 could-not-run (no podman, or the build cannot fetch).
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="localhost/tillandsias-web-studio-decap:v$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
command -v podman >/dev/null 2>&1 || { echo "could-not-run:web-studio-decap:no-podman"; exit 3; }
err="${TMPDIR:-/tmp}/web-studio-decap-build.$$.err"
if ! podman build -q -t "$TAG" "$PROJECT_ROOT/images/web-studio-decap" >/dev/null 2>"$err"; then
  if grep -qE 'fetch https://registry.npmjs.org|ENOTFOUND|EAI_AGAIN' "$err"; then
    echo "could-not-run:web-studio-decap:registry-fetch-failed"; rm -f "$err"; exit 3
  fi
  cat "$err"; rm -f "$err"; echo "FAIL: Decap studio image did not build"; exit 1
fi
rm -f "$err"

work="$(mktemp -d "${TMPDIR:-/tmp}/web-studio-decap.XXXXXX")"
name="web-studio-decap-test-$$"
trap 'podman rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
git -C "$work" init -q
mkdir -p "$work/content/posts"
printf 'baseURL = "https://example.invalid/"\ntitle = "fixture"\n' > "$work/hugo.toml"
printf -- '---\ntitle: Before\ndate: 2026-11-01T00:00:00Z\n---\nThe old body.\n' > "$work/content/posts/hello.md"
git -C "$work" add -A
git -C "$work" -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -m site

podman run -d --rm --name "$name" --network none --userns keep-id:uid=1001,gid=1001 \
  -v "$work:/project:Z" "$TAG" >/dev/null
for _ in $(seq 1 60); do
  podman exec "$name" node -e 'fetch("http://127.0.0.1:8090/healthz").then(r=>process.exit(r.ok?0:1),()=>process.exit(1))' 2>/dev/null && break
  sleep 1
done

probe() { podman exec "$name" node -e "$1" 2>&1; }
api() { probe "fetch(\"http://127.0.0.1:8090/api/v1\",{method:\"POST\",headers:{\"content-type\":\"application/json\"},body:JSON.stringify($1)}).then(async r=>console.log(r.status,await r.text()))"; }
health=$(probe 'fetch("http://127.0.0.1:8090/healthz").then(r=>console.log(r.status))')
bundle=$(probe 'fetch("http://127.0.0.1:8090/admin/decap-cms.js").then(async r=>console.log(r.status,(await r.text()).length>1000000?"big":"small"))')
admin=$(probe 'fetch("http://127.0.0.1:8090/admin/").then(async r=>{const t=await r.text();console.log(r.status,/https?:\/\//.test(t)?"external-url":"self-contained")})')
config=$(probe 'fetch("http://127.0.0.1:8090/admin/config.yml").then(async r=>console.log(r.status,JSON.stringify(await r.text())))')
listed=$(api '{action:"entriesByFolder",params:{branch:"main",folder:"content/posts",extension:"md",depth:1}}')
raw=$'---\ntitle: After\ndate: 2026-11-02T00:00:00Z\n---\nThe new body, saved through Decap.\n'
stored=$(api "{action:\"persistEntry\",params:{branch:\"main\",dataFiles:[{slug:\"hello\",path:\"content/posts/hello.md\",raw:$(printf '%s' "$raw" | podman exec -i "$name" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))')}],assets:[],options:{collectionName:\"posts\",commitMessage:\"Update Posts hello\",useWorkflow:false,status:\"draft\"}}}")
# decap-server's listeners, from the kernel: 8081 is 1F91; 127.0.0.1 is
# 0100007F; LISTEN is state 0A. Anything else bound to 8081 is a leak.
listeners=$(podman exec "$name" sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' | awk '$2 ~ /:1F91$/ && $4 == "0A" {print $2}' | sort -u | tr '\n' ' ')
egress=$(probe 'fetch("https://registry.npmjs.org/").then(()=>console.log("reached"),()=>console.log("blocked"))')
echo "health=$health"; echo "bundle=$bundle"; echo "admin=$admin"; echo "config=$config"
echo "list=$listed"; echo "store=$stored"; echo "decap-listeners=$listeners"; echo "egress=$egress"
echo "repo-changes=$(git -C "$work" status --porcelain | awk '{print $2}' | sort | tr '\n' ' ')"

fail=0
[ "$health" = "200" ] || { echo "FAIL: the studio never became healthy (decap-server did not answer)"; fail=1; }
[ "$bundle" = "200 big" ] || { echo "FAIL: vendored decap-cms.js not served"; fail=1; }
[ "$admin" = "200 self-contained" ] || { echo "FAIL: the admin page references an external URL"; fail=1; }
grep -q 'proxy_url: /api/v1' <<<"$config" || { echo "FAIL: config.yml does not point the backend at the studio"; fail=1; }
grep -q 'content/posts/hello.md' <<<"$listed" || { echo "FAIL: entriesByFolder did not list the Hugo post"; fail=1; }
grep -q '^200 ' <<<"$stored" || { echo "FAIL: persistEntry refused"; fail=1; }
grep -q 'title: After' "$work/content/posts/hello.md" && ! grep -q 'Before' "$work/content/posts/hello.md" \
  || { echo "FAIL: the saved entry did not reach content/posts/hello.md"; fail=1; }
git -C "$work" diff --quiet -- content/posts/hello.md && { echo "FAIL: no git diff on the post"; fail=1; }
[ -n "$listeners" ] || { echo "FAIL: decap-server is not listening at all"; fail=1; }
for l in $listeners; do
  case "$l" in
    0100007F:1F91 | 00000000000000000000000001000000:1F91) ;;
    *) echo "FAIL: decap-server listens beyond loopback ($l)"; fail=1 ;;
  esac
done
[ "$egress" = "blocked" ] || { echo "FAIL: the studio reached the network"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: Decap studio saves a Hugo entry as a repo diff, decap-server on loopback only, no egress"
exit "$fail"
