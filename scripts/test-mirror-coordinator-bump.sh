#!/usr/bin/env bash
# @trace order:1827-3rj4
# Litmus: after a push the git mirror's post-receive hook sends the fleet
# coordinator ONE bump (POST /v1/op {op: bump, ns, head_sha}) with the
# Access service token from vault, and a down or unconfigured coordinator
# never affects the push. The token never appears in a log.
#
# Runs THIS checkout's images/git/post-receive-hook.sh inside the git-mirror
# image (for its git, curl, socat and busybox), against a bare repo, a stub
# vault-cli and a socat stub coordinator on loopback. --network none.
# Exit: 0 pass, 1 fail, 3 could-not-run (no podman, or no git-mirror image).
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${TILLANDSIAS_TEST_GIT_IMAGE:-localhost/tillandsias-git:v$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")}"
command -v podman >/dev/null 2>&1 || { echo "could-not-run:mirror-coordinator-bump:no-podman"; exit 3; }
podman image exists "$IMAGE" || { echo "could-not-run:mirror-coordinator-bump:no-image:$IMAGE (scripts/build-image.sh git)"; exit 3; }

work="$(mktemp -d "${TMPDIR:-/tmp}/mirror-coord.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$PROJECT_ROOT/images/git/post-receive-hook.sh" "$work/post-receive"
cat > "$work/inner.sh" <<'INNER'
#!/bin/sh
# Inside the git-mirror image. $1 = case: up | down | unconfigured
set -u
CASE="$1"
SECRET="s3cr3t-coord-token-$$"
mkdir -p /w/bin && cd /w || exit 2
cat > /w/bin/vault-cli <<VC
#!/bin/sh
[ "$CASE" = unconfigured ] && exit 2
case "\$*" in
  *-field=client_id*) echo "client-id-for-test" ;;
  *-field=client_secret*) echo "$SECRET" ;;
  *-field=url*) echo "http://127.0.0.1:18787" ;;
  *) exit 4 ;;
esac
VC
chmod 755 /w/bin/vault-cli
export PATH="/w/bin:$PATH" HOME=/w
git config --global user.email t@t.invalid; git config --global user.name t; git config --global init.defaultBranch main
git init -q --bare /w/mirror.git
git -C /w/mirror.git remote add origin https://github.com/Owner/Repo.git
cp /hook/post-receive /w/mirror.git/hooks/post-receive && chmod 755 /w/mirror.git/hooks/post-receive
git clone -q /w/mirror.git /w/clone 2>/dev/null
if [ "$CASE" = up ]; then
  # Every request is appended whole to request.txt; each gets a bare 200.
  cat > /w/respond.sh <<'RS'
#!/bin/sh
timeout 1 cat >> /w/request.txt
printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}'
sleep 0.5
RS
  chmod 755 /w/respond.sh
  socat TCP-LISTEN:18787,bind=127.0.0.1,reuseaddr,fork EXEC:/w/respond.sh &
  sleep 0.5
fi
cd /w/clone && echo one > f && git add f && git commit -q -m one
git push -q origin main > /w/push.out 2>&1; echo "push_rc=$?"
sleep 3
echo "head=$(git -C /w/mirror.git rev-parse HEAD)"
echo "--- log"
cat /tmp/git-push.log $HOME/.cache/tillandsias/git-push.log /var/log/tillandsias/git-push.log 2>/dev/null | grep 'coordinator:'
echo "--- request"
[ -f /w/request.txt ] && tr -d '\r' < /w/request.txt
echo "--- leak"
if cat /w/push.out /tmp/git-push.log $HOME/.cache/tillandsias/git-push.log /var/log/tillandsias/git-push.log 2>/dev/null | grep -q "$SECRET"; then echo leaked; else echo clean; fi
INNER
run_case() {
  podman run --rm --network none --entrypoint sh --tmpfs /w:rw,exec,mode=1777 --tmpfs /tmp:rw,mode=1777 \
    -v "$work/post-receive:/hook/post-receive:ro,Z" -v "$work/inner.sh:/inner.sh:ro,Z" \
    "$IMAGE" /inner.sh "$1" 2>&1
}
fail=0
up="$(run_case up)"; down="$(run_case down)"; unconf="$(run_case unconfigured)"
printf '=== up\n%s\n=== down\n%s\n=== unconfigured\n%s\n' "$up" "$down" "$unconf"

head=$(sed -n 's/^head=//p' <<<"$up")
req=$(sed -n '/^--- request$/,/^--- leak$/p' <<<"$up")
grep -q '^push_rc=0$' <<<"$up" || { echo "FAIL(up): the push failed"; fail=1; }
n=$(grep -c '^POST /v1/op ' <<<"$req")
[ "$n" -eq 1 ] || { echo "FAIL(up): expected exactly one POST /v1/op, saw $n"; fail=1; }
grep -q "\"op\":\"bump\",\"ns\":\"owner/repo\",\"head_sha\":\"$head\"" <<<"$req" \
  || { echo "FAIL(up): the body is not the bump for owner/repo at the new head"; fail=1; }
grep -qi '^CF-Access-Client-Id: client-id-for-test$' <<<"$req" && grep -qi '^CF-Access-Client-Secret: s3cr3t-coord-token-' <<<"$req" \
  || { echo "FAIL(up): the Access service-token headers are missing"; fail=1; }
grep -q 'coordinator: bumped owner/repo head=' <<<"$up" || { echo "FAIL(up): no bumped log line"; fail=1; }
grep -q '^clean$' <<<"$up" || { echo "FAIL(up): the token reached a log"; fail=1; }

grep -q '^push_rc=0$' <<<"$down" || { echo "FAIL(down): a down coordinator failed the push"; fail=1; }
[ "$(grep -c 'coordinator: unreachable' <<<"$down")" -eq 1 ] || { echo "FAIL(down): expected one coordinator-unreachable line"; fail=1; }
grep -q '^clean$' <<<"$down" || { echo "FAIL(down): the token reached a log"; fail=1; }

grep -q '^push_rc=0$' <<<"$unconf" || { echo "FAIL(unconfigured): the push failed"; fail=1; }
[ "$(grep -c 'coordinator: not configured' <<<"$unconf")" -eq 1 ] || { echo "FAIL(unconfigured): expected one not-configured line"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: one coordinator bump per push, never blocks it, token never logged"
exit "$fail"
