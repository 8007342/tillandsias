#!/usr/bin/env bash
# @trace spec:git-mirror-service
#
# test-mirror-receive-wrapper.sh — order 749-2fqj (design T6+T7,
# plan/issues/ssh-ca-forge-mirror-push-design-2026-07-31.md).
#
# Proves the packet's four exit criteria:
#
#   1. §4a row M5 (in the REAL images/git container, real sshd, real certs):
#      a push whose SSH_ORIGINAL_COMMAND names project B's repo path still
#      lands in project A's FIXED repository, and B's path is never created.
#   2. T7 upgrade closure: hardening reaches a PRE-EXISTING volume via the
#      entrypoint's every-start migration, and a force push (branch rewind)
#      is refused on that upgraded volume. (Primary evidence for the relay
#      half lives in scripts/test-git-mirror-existing-volume-hardening.sh —
#      the order-579 suite; this scenario pins the receive-config half.)
#   3. receive.fsckObjects=true is EFFECTIVE on the upgraded volume: a
#      malformed commit object is refused, and the same push is accepted by
#      an otherwise-identical copy with fsckObjects=false — the config gate,
#      not something else, is the deciding control.
#   4. The four TILLANDSIAS_PUSH_* variables are exported with the values
#      parsed from the authenticating certificate — asserted offline via a
#      PATH-interposed recorder AND in-container via a pre-receive hook dump.
#
# Hermetic: certs via a fixture ssh-keygen CA (the 722-uern live matrix is out
# of scope); the container lane reuses the 749-54pv posture (--read-only,
# --cap-drop=ALL, --user 1000, /tmp tmpfs, SELinux :z on single-file mounts).
#
# GRAMMAR — exactly one final line per mode:
#   ok:receive-fixture:<what> | fail:receive-fixture:<cause>
# `all` ends with: 'ok: all mirror-receive scenarios passed'

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

MODE="${1:-all}"
IMAGE_TAG="localhost/tillandsias-git:latest"
MID="fixt0mirror0id0abcd"
WRAPPER="$ROOT/images/git/tillandsias-receive.sh"

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_NOSYSTEM=1

fail() { echo "fail:receive-fixture:$1"; return 1; }

# ── Offline helpers ─────────────────────────────────────────────────────────
# Build a client certificate + SSH_USER_AUTH file the way sshd's
# ExposeAuthInfo writes it: `publickey <cert-type> <base64>`.
make_cert_authinfo() {
    # $1 = dir; sets CERT_PUB, AUTH_FILE, WANT_FP globals
    ssh-keygen -q -N '' -t ed25519 -f "$1/client_ca"
    ssh-keygen -q -N '' -t ed25519 -f "$1/key"
    ssh-keygen -q -s "$1/client_ca" -I "token-fixture-keyid" \
        -n "til:forge-push:$MID" -z 42 "$1/key.pub"
    CERT_PUB="$1/key-cert.pub"
    WANT_FP="$(ssh-keygen -l -f "$CERT_PUB" | awk '{print $2}')"
    AUTH_FILE="$1/auth-info"
    printf 'publickey %s\n' "$(cat "$CERT_PUB")" > "$AUTH_FILE"
}

mode_vars_exported() {
    d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
    make_cert_authinfo "$d"
    mkdir -p "$d/root/projecta"
    git init -q --bare "$d/root/projecta"
    cat > "$d/recorder" <<EOF
#!/bin/sh
{ echo "argv1=\$1"
  echo "fp=\$TILLANDSIAS_PUSH_KEY_FP"
  echo "principal=\$TILLANDSIAS_PUSH_PRINCIPAL"
  echo "serial=\$TILLANDSIAS_PUSH_SERIAL"
  echo "keyid=\$TILLANDSIAS_PUSH_KEY_ID"; } > "$d/record"
EOF
    chmod +x "$d/recorder"
    out="$(TILLANDSIAS_RECEIVE_ROOT="$d/root" TILLANDSIAS_RECEIVE_PROJECT=projecta \
        SSH_USER_AUTH="$AUTH_FILE" SSH_ORIGINAL_COMMAND="git-receive-pack '/projectB'" \
        TILLANDSIAS_GIT_RECEIVE_PACK="$d/recorder" \
        sh "$WRAPPER" 2>&1)" || { echo "$out" >&2; fail wrapper-refused-valid-session; return 1; }
    [ -f "$d/record" ] || { fail recorder-never-ran; return 1; }
    grep -qxF "argv1=$d/root/projecta" "$d/record" || { cat "$d/record" >&2; fail wrong-repo-path; return 1; }
    grep -qxF "fp=$WANT_FP" "$d/record" || { cat "$d/record" >&2; fail fp-mismatch; return 1; }
    grep -qxF "principal=til:forge-push:$MID" "$d/record" || { cat "$d/record" >&2; fail principal-mismatch; return 1; }
    grep -qxF "serial=42" "$d/record" || { cat "$d/record" >&2; fail serial-mismatch; return 1; }
    grep -qxF "keyid=token-fixture-keyid" "$d/record" || { cat "$d/record" >&2; fail keyid-mismatch; return 1; }
    echo "ok:receive-fixture:push-vars-exported-from-cert"
}

mode_refusals() {
    d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
    make_cert_authinfo "$d"
    mkdir -p "$d/root/projecta"; git init -q --bare "$d/root/projecta"
    common=(env TILLANDSIAS_RECEIVE_ROOT="$d/root" TILLANDSIAS_RECEIVE_PROJECT=projecta
        TILLANDSIAS_GIT_RECEIVE_PACK=/bin/false)
    # a) non-receive verb refused
    out="$("${common[@]}" SSH_USER_AUTH="$AUTH_FILE" SSH_ORIGINAL_COMMAND="ls -la" sh "$WRAPPER" 2>&1)" \
        && { fail non-receive-accepted; return 1; }
    printf '%s\n' "$out" | grep -qx 'fail:tillandsias-receive:not-receive-pack' \
        || { echo "$out" >&2; fail non-receive-wrong-cause; return 1; }
    # b) missing auth info refused
    out="$("${common[@]}" SSH_ORIGINAL_COMMAND="git-receive-pack 'x'" sh "$WRAPPER" 2>&1)" \
        && { fail no-auth-accepted; return 1; }
    printf '%s\n' "$out" | grep -qx 'fail:tillandsias-receive:no-auth-info' \
        || { echo "$out" >&2; fail no-auth-wrong-cause; return 1; }
    # c) plain (non-cert) auth info refused
    printf 'publickey ssh-ed25519 %s\n' "$(awk '{print $2}' "$d/key.pub")" > "$d/plain-auth"
    out="$("${common[@]}" SSH_USER_AUTH="$d/plain-auth" SSH_ORIGINAL_COMMAND="git-receive-pack 'x'" sh "$WRAPPER" 2>&1)" \
        && { fail plain-key-accepted; return 1; }
    printf '%s\n' "$out" | grep -qx 'fail:tillandsias-receive:no-cert-in-auth-info' \
        || { echo "$out" >&2; fail plain-key-wrong-cause; return 1; }
    # d) missing project refused
    out="$(env TILLANDSIAS_RECEIVE_ROOT="$d/root" TILLANDSIAS_RECEIVE_PROJECT= \
        SSH_USER_AUTH="$AUTH_FILE" SSH_ORIGINAL_COMMAND="git-receive-pack 'x'" sh "$WRAPPER" 2>&1)" \
        && { fail no-project-accepted; return 1; }
    printf '%s\n' "$out" | grep -qx 'fail:tillandsias-receive:no-project' \
        || { echo "$out" >&2; fail no-project-wrong-cause; return 1; }
    echo "ok:receive-fixture:refusals-loud-and-named"
}

# Shared T7 scaffolding: a PRE-EXISTING permissive volume upgraded by the real
# entrypoint's setup-only seam (the same every-start migration a container
# restart runs), hooks then stubbed inert — receive config, not hook policy,
# is the subject here; the hook path is the 579 suite's subject.
setup_upgraded_volume() {
    # $1 = workdir; sets MIRROR, CLIENT globals
    local w="$1"
    export HOME="$w/home"; mkdir -p "$HOME"
    export GIT_CONFIG_GLOBAL="$w/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
    MIRROR="$w/existing-volume/project"
    CLIENT="$w/client"
    mkdir -p "$w/existing-volume"
    git init -q --bare "$MIRROR"
    # Born permissive — the pre-hardening state an old volume carries.
    git -C "$MIRROR" config receive.denyNonFastForwards false
    git -C "$MIRROR" config receive.denyDeletes false
    git -C "$MIRROR" config receive.fsckObjects false
    git init -q "$CLIENT"
    echo base > "$CLIENT/file"; git -C "$CLIENT" add file; git -C "$CLIENT" commit -qm base
    git -C "$CLIENT" branch -M main
    git -C "$CLIENT" push -q "$MIRROR" main
    # The upgrade: the REAL entrypoint, setup-only, against the existing volume.
    out="$(PROJECT=project TILLANDSIAS_GIT_SERVICE_ROOT="$w/existing-volume" \
        TILLANDSIAS_GIT_SERVICE_SHARE="$ROOT/images/git" \
        TILLANDSIAS_GIT_SERVICE_SETUP_ONLY=1 TILLANDSIAS_PROJECT_DEFAULT_BRANCH=main \
        bash "$ROOT/images/git/entrypoint.sh" 2>&1)" \
        || { echo "$out" >&2; fail entrypoint-setup-failed; return 1; }
    [ "$(git -C "$MIRROR" config --get receive.fsckObjects)" = "true" ] \
        || { fail hardening-not-applied-to-existing-volume; return 1; }
    [ "$(git -C "$MIRROR" config --get receive.denyNonFastForwards)" = "true" ] \
        || { fail denynonff-not-applied; return 1; }
    # Inert hooks: this fixture pins receive CONFIG effectiveness.
    printf '#!/bin/sh\nexit 0\n' > "$MIRROR/hooks/pre-receive"
    printf '#!/bin/sh\nexit 0\n' > "$MIRROR/hooks/post-receive"
    chmod +x "$MIRROR/hooks/pre-receive" "$MIRROR/hooks/post-receive"
}

# Both upgraded-volume modes run in SUBSHELLS: setup_upgraded_volume exports
# HOME into a temp dir the cleanup trap deletes, and a leaked deleted HOME
# breaks rootless podman for every later scenario (build_image's
# require_podman fails 127 with no podman problem at all).
mode_force_push_upgraded() (
    w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
    setup_upgraded_volume "$w" || exit 1
    git -C "$CLIENT" commit -q --amend -m rewritten
    if git -C "$CLIENT" push -q --force "$MIRROR" main 2>"$w/force.err"; then
        fail force-push-accepted-on-upgraded-volume; return 1
    fi
    grep -qiE 'non-fast-forward|denying non-fast-forward' "$w/force.err" \
        || { cat "$w/force.err" >&2; fail force-push-wrong-cause; return 1; }
    if git -C "$CLIENT" push -q "$MIRROR" :main 2>"$w/del.err"; then
        fail deletion-accepted-on-upgraded-volume; return 1
    fi
    grep -qiE 'deny deleting|deletion.*denied|denying ref deletion' "$w/del.err" \
        || { cat "$w/del.err" >&2; fail deletion-wrong-cause; return 1; }
    echo "ok:receive-fixture:force-and-delete-refused-on-upgraded-volume"
)

mode_fsck_upgraded() (
    w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
    setup_upgraded_volume "$w" || exit 1
    # A commit whose committer line has no email brackets — an fsck ERROR
    # (missingEmail), built with --literally so the client repo will hold it.
    TREE="$(git -C "$CLIENT" rev-parse 'HEAD^{tree}')"
    BAD="$(printf 'tree %s\nauthor fixture <f@example.invalid> 1700000000 +0000\ncommitter broken 1700000000 +0000\n\nbad\n' "$TREE" \
        | git -C "$CLIENT" hash-object -t commit --literally -w --stdin)"
    git -C "$CLIENT" update-ref refs/heads/evil "$BAD"
    if git -C "$CLIENT" push -q "$MIRROR" refs/heads/evil 2>"$w/fsck.err"; then
        fail malformed-object-accepted; return 1
    fi
    grep -qiE 'missingEmail|fsck|bad object|invalid committer' "$w/fsck.err" \
        || { cat "$w/fsck.err" >&2; fail malformed-wrong-cause; return 1; }
    git -C "$MIRROR" rev-parse --quiet --verify refs/heads/evil >/dev/null \
        && { fail malformed-ref-created; return 1; }
    # Control: an otherwise-identical permissive copy ACCEPTS the same push —
    # fsckObjects is the deciding control, so 'true' is effective, not decor.
    cp -a "$MIRROR" "$w/permissive.git"
    git -C "$w/permissive.git" config receive.fsckObjects false
    git -C "$CLIENT" push -q "$w/permissive.git" refs/heads/evil 2>"$w/ctl.err" \
        || { cat "$w/ctl.err" >&2; fail control-push-refused; return 1; }
    echo "ok:receive-fixture:fsck-effective-on-upgraded-volume"
)

# ── Container M5 lane (criterion 1 + in-container criterion 4) ─────────────
build_image() {
    if ! scripts/build-image.sh git >/tmp/.receive-build.log 2>&1; then
        echo "fail:receive-fixture:image-build-failed (see /tmp/.receive-build.log)"
        exit 1
    fi
}

run_inner() {
    podman run --rm \
        --read-only --cap-drop=ALL --user 1000 \
        --tmpfs /tmp:rw,mode=1777 \
        -v "$ROOT/images/git/sshd-identity.sh:/usr/local/bin/sshd-identity.sh:ro,z" \
        -v "$ROOT/images/git/tillandsias-receive.sh:/usr/local/bin/tillandsias-receive:ro,z" \
        --entrypoint /bin/bash \
        "$IMAGE_TAG" -c "$1" 2>&1
}

INNER_M5='set -u
export TILLANDSIAS_MIRROR_ID='"$MID"'
mkdir -p /tmp/fx/ca /tmp/fx/client /tmp/fx/srv
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/ca/host_ca
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/ca/client_ca
cat > /tmp/fx/signer.sh <<'\''SEOF'\''
#!/bin/bash
pub="$1"; principal="$2"
d=$(mktemp -d); cp "$pub" "$d/k.pub"
ssh-keygen -q -s /tmp/fx/ca/host_ca -I fixture-host -h -n "$principal" -z 7 "$d/k.pub" || exit 1
cat "$d/k-cert.pub"
SEOF
chmod +x /tmp/fx/signer.sh
export TILLANDSIAS_SSH_SIGNER_CMD=/tmp/fx/signer.sh
export TILLANDSIAS_TRUSTED_USER_CA_FILE=/tmp/fx/ca/client_ca.pub
export TILLANDSIAS_RECEIVE_PROJECT=projecta
export TILLANDSIAS_RECEIVE_ROOT=/tmp/fx/srv
git init -q --bare /tmp/fx/srv/projecta
git -C /tmp/fx/srv/projecta symbolic-ref HEAD refs/heads/main
printf "#!/bin/sh\nprintenv | grep ^TILLANDSIAS_PUSH_ > /tmp/fx/receive-env\nexit 0\n" > /tmp/fx/srv/projecta/hooks/pre-receive
chmod +x /tmp/fx/srv/projecta/hooks/pre-receive
/usr/local/bin/sshd-identity.sh ensure | grep -q ok:sshd-identity:ready || { echo inner:ensure-failed; sed -n "1,8p" /tmp/tillandsias-sshd/sshd.err >&2; exit 90; }
grep -q "SetEnv .*TILLANDSIAS_RECEIVE_PROJECT=projecta" /tmp/tillandsias-sshd/sshd_config || { echo inner:setenv-not-rendered; exit 95; }
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/client/key
ssh-keygen -q -s /tmp/fx/ca/client_ca -I token-m5-keyid -n "til:forge-push:'"$MID"'" -z 99 /tmp/fx/client/key.pub
printf "@cert-authority git-'"$MID"' %s\n" "$(cat /tmp/fx/ca/host_ca.pub)" > /tmp/fx/kh
export HOME=/tmp/fx/client
git config --global user.email f@example.invalid
git config --global user.name fixture
git init -q /tmp/fx/client/repo
cd /tmp/fx/client/repo
echo m5 > file && git add file && git commit -qm m5 && git branch -M main
WANT_SHA="$(git rev-parse HEAD)"
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/fx/kh -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o HostKeyAlias=git-'"$MID"' -i /tmp/fx/client/key -p 2222"
git push -q ssh://git@127.0.0.1:2222/projectB main 2>/tmp/fx/push.err || { echo inner:push-failed; sed -n "1,8p" /tmp/fx/push.err >&2; exit 91; }
GOT_SHA="$(git -C /tmp/fx/srv/projecta rev-parse refs/heads/main 2>/dev/null || echo none)"
[ "$GOT_SHA" = "$WANT_SHA" ] || { echo "inner:landed-wrong:got=$GOT_SHA want=$WANT_SHA"; exit 92; }
[ -d /tmp/fx/srv/projectB ] && { echo inner:projectB-created; exit 93; }
grep -q "^TILLANDSIAS_PUSH_PRINCIPAL=til:forge-push:'"$MID"'$" /tmp/fx/receive-env || { echo inner:hook-missing-principal; cat /tmp/fx/receive-env >&2; exit 94; }
grep -q "^TILLANDSIAS_PUSH_SERIAL=99$" /tmp/fx/receive-env || { echo inner:hook-missing-serial; exit 96; }
grep -q "^TILLANDSIAS_PUSH_KEY_ID=token-m5-keyid$" /tmp/fx/receive-env || { echo inner:hook-missing-keyid; exit 97; }
grep -q "^TILLANDSIAS_PUSH_KEY_FP=SHA256:" /tmp/fx/receive-env || { echo inner:hook-missing-fp; exit 98; }
echo inner:m5-fixed-path-ok'

mode_m5_container() {
    build_image
    out="$(run_inner "$INNER_M5")"
    if printf '%s' "$out" | grep -q 'inner:m5-fixed-path-ok'; then
        echo "ok:receive-fixture:m5-wrong-path-lands-in-fixed-repo"
        return 0
    fi
    printf '%s\n' "$out" | tail -10 >&2
    fail m5-container
}

case "$MODE" in
    vars-exported)   mode_vars_exported ;;
    refusals)        mode_refusals ;;
    force-upgraded)  mode_force_push_upgraded ;;
    fsck-upgraded)   mode_fsck_upgraded ;;
    m5-container)    mode_m5_container ;;
    all)
        rc=0
        mode_vars_exported || rc=1
        mode_refusals || rc=1
        mode_force_push_upgraded || rc=1
        mode_fsck_upgraded || rc=1
        mode_m5_container || rc=1
        if [ $rc -eq 0 ]; then
            echo "ok: all mirror-receive scenarios passed"
        else
            echo "fail:receive-fixture:one-or-more-scenarios"
        fi
        exit $rc
        ;;
    *) echo "usage: $0 [vars-exported|refusals|force-upgraded|fsck-upgraded|m5-container|all]"; exit 2 ;;
esac
