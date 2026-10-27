#!/usr/bin/env bash
# test-start-a-new-project-gcp.sh — order 1906-md6q.
#
# The start-a-new-project scaffold's Google Cloud deploy targets render their
# own files, filled in, without overwriting anything.
#
# ARM 1 --deploy gcp-dockerfile (static, flutter) renders Dockerfile, nginx
#       template, .dockerignore, cloudbuild.yaml, service.yaml: no {{...}} left,
#       the slug and port filled in, a non-root USER base, $PORT honoured
# ARM 2 --deploy gcp-buildpacks --runtime python --port 9000 renders
#       project.toml (GOOGLE_RUNTIME=python) and service.yaml (port 9000)
# ARM 3 the runtime is read from the project's files (package.json -> node)
# ARM 4 buildpacks for a static app exits 3 and creates NOTHING
# ARM 5 a second run creates nothing; a user's own Dockerfile is kept
# ARM 6 the skill states the billing requirement; no cloud command runs
#       (the scaffold never calls gcloud)
#
# Asserts only its own files (the shared convention with the Cloudflare
# target). Prints ok:start-a-new-project-gcp:<n> or FAIL lines and exits 1.
#
# @trace spec:project-bootstrap-readme, order:1906-md6q
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/start-a-new-project"
S="$SKILL/scaffold.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/start-a-new-project-gcp.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0 failed=0
ok() { echo "  ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

# ARM 1
A="$W/a"; mkdir -p "$A"
out="$(bash "$S" --dir "$A" --name "Pong Party" --summary s --stack flutter --deploy gcp-dockerfile --no-specs 2>&1)"; rc=$?
left="$(grep -rl '{{' "$A" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ -f "$A/Dockerfile" ] && [ -f "$A/nginx.conf.template" ] \
    && [ -f "$A/.dockerignore" ] && [ -f "$A/cloudbuild.yaml" ] && [ -f "$A/service.yaml" ] \
    && [ -z "$left" ] && grep -q '^  name: pong-party$' "$A/service.yaml" \
    && grep -q 'containerPort: 8080' "$A/service.yaml" \
    && grep -q '_SERVICE_NAME: pong-party' "$A/cloudbuild.yaml" \
    && grep -q '^FROM docker.io/nginxinc/nginx-unprivileged:' "$A/Dockerfile" \
    && grep -q 'listen ${PORT};' "$A/nginx.conf.template" \
    && grep -qx 'ok:scaffold:8' <<<"$out"; then
    ok "ARM 1: gcp-dockerfile renders five files for a Flutter web app, filled in, unprivileged nginx on \$PORT"
else
    bad "ARM 1: rc=$rc left='$left' out='$(tail -2 <<<"$out" | tr '\n' ' ')'"
fi

# ARM 2
B="$W/b"; mkdir -p "$B"
bash "$S" --dir "$B" --name "My API" --summary s --deploy gcp-buildpacks --runtime python --port 9000 --no-specs >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^value = "python"$' "$B/project.toml" \
    && grep -q 'containerPort: 9000' "$B/service.yaml" && [ ! -e "$B/Dockerfile" ] \
    && ! grep -rq '{{' "$B"; then
    ok "ARM 2: gcp-buildpacks renders project.toml (python) and service.yaml (port 9000), no Dockerfile"
else
    bad "ARM 2: rc=$rc"
fi

# ARM 3
C="$W/c"; mkdir -p "$C"; printf '{"name":"c"}\n' > "$C/package.json"
bash "$S" --dir "$C" --name C --summary s --deploy gcp-dockerfile --no-specs >/dev/null 2>&1
if grep -q '^FROM docker.io/library/node:' "$C/Dockerfile" && grep -q '^USER node$' "$C/Dockerfile"; then
    ok "ARM 3: a package.json makes the runtime node, run as the image's non-root user"
else
    bad "ARM 3: $(grep -m1 '^FROM' "$C/Dockerfile" 2>/dev/null)"
fi

# ARM 4
D="$W/d"; mkdir -p "$D"
err="$(bash "$S" --dir "$D" --name D --summary s --stack flutter --deploy gcp-buildpacks 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && [ -z "$(ls -A "$D")" ] && grep -q 'gcp-dockerfile' <<<"$err"; then
    ok "ARM 4: buildpacks for a Flutter web app exits 3, names the Dockerfile option, creates nothing"
else
    bad "ARM 4: rc=$rc files='$(ls -A "$D" | tr '\n' ' ')'"
fi

# ARM 5
printf 'FROM scratch\n' > "$W/mine"
E="$W/e"; mkdir -p "$E"; cp "$W/mine" "$E/Dockerfile"
bash "$S" --dir "$E" --name E --summary s --deploy gcp-dockerfile --runtime go --no-specs >/dev/null 2>&1
out2="$(bash "$S" --dir "$E" --name E --summary s --deploy gcp-dockerfile --runtime go --no-specs 2>&1)"
if cmp -s "$E/Dockerfile" "$W/mine" && grep -qx 'ok:scaffold:0' <<<"$out2" && [ -f "$E/service.yaml" ]; then
    ok "ARM 5: the user's own Dockerfile is kept and a second run creates nothing"
else
    bad "ARM 5: Dockerfile overwritten or rerun created files: '$(tail -1 <<<"$out2")'"
fi

# ARM 6
if grep -q 'needs a billing account' "$SKILL/SKILL.md" \
    && grep -q 'needs a billing account' "$SKILL/deploy-google-cloud.md" \
    && ! grep -qE '^[^#]*\bgcloud\b' "$S"; then
    ok "ARM 6: the skill and its note state the billing requirement; the scaffold runs no gcloud"
else
    bad "ARM 6: billing line missing or the scaffold calls gcloud"
fi

if [ "$failed" -eq 0 ]; then
    echo "ok:start-a-new-project-gcp:$pass"
else
    exit 1
fi
