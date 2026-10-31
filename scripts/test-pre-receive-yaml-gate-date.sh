#!/usr/bin/env bash
# @trace spec:git-mirror-service, order:1863-mqiw
# Litmus: the mirror's pre-receive YAML gate accepts the plain date that
# `openspec new change` writes (`created: 2026-10-25`), and agrees with yq.
#
# The git image ships ruby and no tillandsias-policy, so production validates
# with ruby. Psych 4 (Ruby 3.1+) makes YAML.load_file a safe load that refuses
# Date, so the whole push was rejected. The sibling test-pre-receive-yaml-gate.sh
# puts tillandsias-policy on PATH and so never reaches the ruby branch; this one
# runs the hook INSIDE the git image, where ruby is the validator.
#
# Exit: 0 pass, 1 fail, 3 could-not-run (no git image or no podman).
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_IMAGE="${TILLANDSIAS_TEST_GIT_IMAGE:-localhost/tillandsias-git:v$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")}"
YQ_IMAGE="${TILLANDSIAS_TEST_YQ_IMAGE:-docker.io/mikefarah/yq:4.44.3}"

command -v podman >/dev/null 2>&1 || { echo "could-not-run:pre-receive-date:no-podman"; exit 3; }
podman image exists "$GIT_IMAGE" || { echo "could-not-run:pre-receive-date:no-git-image:$GIT_IMAGE"; exit 3; }

DOC='created: 2026-10-25
schema: spec-driven
'

# The push, run as the image's git user with the checkout's hook mounted read-only.
push_out="$(podman run --rm --network none --user git --entrypoint bash \
    -v "$PROJECT_ROOT/images/git/pre-receive-hook.sh:/hook/pre-receive:ro,z" \
    -v "$PROJECT_ROOT/images/git/relay-refs.sh:/hook/tillandsias-relay-refs:ro,z" \
    -e DOC="$DOC" "$GIT_IMAGE" -c '
set -e
cd /tmp
git init -q --bare m.git
mkdir -p m.git/hooks
cp /hook/pre-receive m.git/hooks/pre-receive
cp /hook/tillandsias-relay-refs m.git/hooks/tillandsias-relay-refs
chmod +x m.git/hooks/pre-receive m.git/hooks/tillandsias-relay-refs
git init -q w
mkdir -p w/openspec/changes/demo
printf "%s" "$DOC" > w/openspec/changes/demo/.openspec.yaml
cp w/openspec/changes/demo/.openspec.yaml w/openspec/changes/demo/change.yaml
git -C w add -A
git -C w -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -m "openspec new change"
echo "validator=$(command -v tillandsias-policy >/dev/null && echo tillandsias-policy || echo ruby)"
if git -C w push -q /tmp/m.git HEAD:refs/heads/main 2>/tmp/push.err; then echo push=accepted; else echo push=rejected; cat /tmp/push.err; fi
printf "broken: [[[\n" > w/openspec/changes/demo/change.yaml
git -C w -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -am "broken"
if git -C w push -q /tmp/m.git HEAD:refs/heads/broken 2>/dev/null; then echo broken=accepted; else echo broken=rejected; fi
' 2>&1)" || true
echo "$push_out"

podman image exists "$YQ_IMAGE" || podman pull -q "$YQ_IMAGE" >/dev/null 2>&1 || { echo "could-not-run:pre-receive-date:no-yq-image:$YQ_IMAGE"; exit 3; }
yq_rc=0
yq_out="$(printf '%s' "$DOC" | podman run --rm -i --network none "$YQ_IMAGE" '.created' 2>/dev/null)" || yq_rc=$?
echo "yq=$yq_out rc=$yq_rc"

fail=0
grep -qx 'validator=ruby' <<<"$push_out" || { echo "FAIL: the hook did not validate with ruby, so this arm tested nothing"; fail=1; }
grep -qx 'push=accepted' <<<"$push_out" || { echo "FAIL: the mirror rejected a push openspec itself writes"; fail=1; }
grep -qx 'broken=rejected' <<<"$push_out" || { echo "FAIL: broken YAML passed the gate, so the gate no longer gates"; fail=1; }
[ "$yq_rc" -eq 0 ] && [ "$yq_out" = "2026-10-25" ] || { echo "FAIL: yq did not load the same document"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: pre-receive (ruby) and yq agree on created: 2026-10-25"
exit "$fail"
