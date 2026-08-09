#!/usr/bin/env bash
# @trace spec:git-mirror-service
# Order-579 functional regression: upgrade a permissive pre-existing mirror,
# restart idempotently, then prove branch rewind plus branch/tag/custom/mixed
# deletion is rejected before relay while an ordinary fast-forward converges.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$ROOT/images/git/entrypoint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export HOME="$WORK/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_ALLOW_PROTOCOL=ext:file
mkdir -p "$HOME"
: > "$GIT_CONFIG_GLOBAL"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

snapshot_refs() {
    git -C "$1" for-each-ref --format='%(refname) %(objectname)' | LC_ALL=C sort
}

assert_hardened_config() {
    local repo="$1"
    [ "$(git -C "$repo" config --get receive.denyNonFastForwards)" = "true" ] \
        || fail "receive.denyNonFastForwards was not true after startup"
    [ "$(git -C "$repo" config --get receive.denyDeletes)" = "true" ] \
        || fail "receive.denyDeletes was not true after startup"
    [ "$(git -C "$repo" config --get receive.fsckObjects)" = "true" ] \
        || fail "receive.fsckObjects was not true after startup"
}

UPSTREAM="$WORK/upstream.git"
SERVICE_ROOT="$WORK/existing-volume"
MIRROR="$SERVICE_ROOT/project"
CLIENT="$WORK/client"
mkdir -p "$SERVICE_ROOT"
git init -q --bare "$UPSTREAM"
git init -q --bare "$MIRROR"
git init -q "$CLIENT"
git -C "$CLIENT" config core.hooksPath ""
git -C "$CLIENT" remote add mirror "$MIRROR"

echo base > "$CLIENT/file"
git -C "$CLIENT" add file
git -C "$CLIENT" commit -qm base
git -C "$CLIENT" branch -M main
git -C "$CLIENT" tag v-existing
BASE_SHA="$(git -C "$CLIENT" rev-parse HEAD)"
git -C "$CLIENT" push -q "$UPSTREAM" HEAD:refs/heads/main
git -C "$CLIENT" push -q "$UPSTREAM" refs/tags/v-existing
git -C "$CLIENT" push -q "$UPSTREAM" HEAD:refs/meta/existing
git -C "$MIRROR" fetch -q "$UPSTREAM" refs/heads/main:refs/heads/main
git -C "$MIRROR" fetch -q "$UPSTREAM" refs/tags/v-existing:refs/tags/v-existing
git -C "$MIRROR" fetch -q "$UPSTREAM" refs/meta/existing:refs/meta/existing
git -C "$MIRROR" symbolic-ref HEAD refs/heads/main
git -C "$MIRROR" config core.hooksPath "$MIRROR/hooks"

# Reproduce a volume created by the old image: permissive receive settings and
# no fsck policy. The upstream stays permissive so a relay-before-reject bug is
# observable as real upstream mutation rather than masked by the fixture.
git -C "$MIRROR" config receive.denyNonFastForwards false
git -C "$MIRROR" config receive.denyDeletes false
git -C "$MIRROR" config --unset-all receive.fsckObjects 2>/dev/null || true
git -C "$UPSTREAM" config receive.denyNonFastForwards false
git -C "$UPSTREAM" config receive.denyDeletes false

# Local receive-pack inherits quarantine variables into a direct filesystem
# transport. The ext boundary sanitizes them like production HTTPS/SSH does.
UPSTREAM_EXT="ext::env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES %S $UPSTREAM"

start_existing_volume() {
    local log="$1"
    env \
        PROJECT=project \
        TILLANDSIAS_PROJECT_DEFAULT_BRANCH=main \
        TILLANDSIAS_PROJECT_REMOTE_URL="$UPSTREAM_EXT" \
        TILLANDSIAS_GIT_SERVICE_ROOT="$SERVICE_ROOT" \
        TILLANDSIAS_GIT_SERVICE_SHARE="$ROOT/images/git" \
        TILLANDSIAS_GIT_SERVICE_SETUP_ONLY=1 \
        bash "$ENTRYPOINT" >"$log" 2>&1
}

MIRROR_BEFORE_START="$(snapshot_refs "$MIRROR")"
UPSTREAM_BEFORE_START="$(snapshot_refs "$UPSTREAM")"
start_existing_volume "$WORK/start-1.log"
assert_hardened_config "$MIRROR"
[ "$(snapshot_refs "$MIRROR")" = "$MIRROR_BEFORE_START" ] \
    || fail "first existing-volume startup changed mirror refs"
[ "$(snapshot_refs "$UPSTREAM")" = "$UPSTREAM_BEFORE_START" ] \
    || fail "first existing-volume startup changed upstream refs"

start_existing_volume "$WORK/start-2.log"
assert_hardened_config "$MIRROR"
[ "$(snapshot_refs "$MIRROR")" = "$MIRROR_BEFORE_START" ] \
    || fail "second existing-volume startup changed mirror refs"
[ "$(snapshot_refs "$UPSTREAM")" = "$UPSTREAM_BEFORE_START" ] \
    || fail "second existing-volume startup changed upstream refs"
grep -Fq "setup-only startup complete" "$WORK/start-2.log" \
    || fail "entrypoint setup-only fixture seam did not complete"
echo "case 1 ok: existing permissive volume hardened on two idempotent starts"

# Wrap the production relay helper only to count invocations. The wrapper then
# execs the exact helper installed by entrypoint, so accepted-path behavior is
# unchanged and rejected paths prove they stop before privileged relay.
mv "$MIRROR/hooks/tillandsias-relay-refs" "$MIRROR/hooks/tillandsias-relay-refs.real"
cat > "$MIRROR/hooks/tillandsias-relay-refs" <<'WRAPPER'
#!/bin/sh
: "${TILLANDSIAS_RELAY_MARKER:?missing relay marker}"
printf 'invoked\n' >> "$TILLANDSIAS_RELAY_MARKER"
exec "$(dirname "$0")/tillandsias-relay-refs.real"
WRAPPER
chmod +x "$MIRROR/hooks/tillandsias-relay-refs"
export TILLANDSIAS_RELAY_MARKER="$WORK/relay-invocations"
OID_SAMPLE="$(git -C "$MIRROR" hash-object --stdin </dev/null)"
ZERO_SHA="$(printf '%*s' "${#OID_SAMPLE}" '' | tr ' ' '0')"

echo fast-forward >> "$CLIENT/file"
git -C "$CLIENT" commit -qam fast-forward
FAST_FORWARD_SHA="$(git -C "$CLIENT" rev-parse HEAD)"
: > "$TILLANDSIAS_RELAY_MARKER"
git -C "$CLIENT" push mirror HEAD:refs/heads/main >"$WORK/fast-forward.log" 2>&1 \
    || { sed -n '1,120p' "$WORK/fast-forward.log" >&2; fail "allowed fast-forward was rejected"; }
[ "$(wc -l < "$TILLANDSIAS_RELAY_MARKER")" -eq 1 ] \
    || fail "allowed fast-forward did not invoke relay exactly once"
[ "$(git -C "$MIRROR" rev-parse refs/heads/main)" = "$FAST_FORWARD_SHA" ] \
    || fail "mirror did not accept fast-forward"
[ "$(git -C "$UPSTREAM" rev-parse refs/heads/main)" = "$FAST_FORWARD_SHA" ] \
    || fail "upstream did not converge after fast-forward"
echo "case 2 ok: allowed fast-forward relayed once and converged both repositories"

MIRROR_BEFORE_DELETE="$(snapshot_refs "$MIRROR")"
UPSTREAM_BEFORE_DELETE="$(snapshot_refs "$UPSTREAM")"
: > "$TILLANDSIAS_RELAY_MARKER"
if git -C "$CLIENT" push mirror :refs/heads/main >"$WORK/delete.log" 2>&1; then
    fail "branch deletion unexpectedly succeeded"
fi
grep -Fq "ref deletion is disabled: refs/heads/main" "$WORK/delete.log" \
    || fail "branch deletion rejection did not name the receive policy and ref"
[ ! -s "$TILLANDSIAS_RELAY_MARKER" ] \
    || fail "branch deletion reached the privileged relay"
[ "$(snapshot_refs "$MIRROR")" = "$MIRROR_BEFORE_DELETE" ] \
    || fail "rejected branch deletion changed mirror refs"
[ "$(snapshot_refs "$UPSTREAM")" = "$UPSTREAM_BEFORE_DELETE" ] \
    || fail "rejected branch deletion changed upstream refs"
echo "case 3 ok: branch deletion rejected before relay; both ref sets byte-identical"

MIRROR_BEFORE_REWIND="$(snapshot_refs "$MIRROR")"
UPSTREAM_BEFORE_REWIND="$(snapshot_refs "$UPSTREAM")"
: > "$TILLANDSIAS_RELAY_MARKER"
if git -C "$CLIENT" push --force mirror "$BASE_SHA:refs/heads/main" >"$WORK/rewind.log" 2>&1; then
    fail "non-fast-forward branch rewind unexpectedly succeeded"
fi
grep -Fq "non-fast-forward branch update is disabled" "$WORK/rewind.log" \
    || fail "branch rewind rejection did not name the receive policy"
[ ! -s "$TILLANDSIAS_RELAY_MARKER" ] \
    || fail "branch rewind reached the privileged relay"
[ "$(snapshot_refs "$MIRROR")" = "$MIRROR_BEFORE_REWIND" ] \
    || fail "rejected branch rewind changed mirror refs"
[ "$(snapshot_refs "$UPSTREAM")" = "$UPSTREAM_BEFORE_REWIND" ] \
    || fail "rejected branch rewind changed upstream refs"
git -C "$MIRROR" fsck --full --strict >/dev/null
git -C "$UPSTREAM" fsck --full --strict >/dev/null
echo "case 4 ok: branch rewind rejected before relay; both ref sets byte-identical"

# Pre-receive must validate the transaction Git will apply after the hook. A
# stale/fabricated old value that is nevertheless an ancestor used to pass the
# fast-forward test, relay upstream, and only then fail local receive-pack.
MIRROR_BEFORE_STALE="$(snapshot_refs "$MIRROR")"
UPSTREAM_BEFORE_STALE="$(snapshot_refs "$UPSTREAM")"
: > "$TILLANDSIAS_RELAY_MARKER"
if printf '%s %s %s\n' "$BASE_SHA" "$FAST_FORWARD_SHA" refs/heads/main \
    | (cd "$MIRROR" && hooks/pre-receive) >"$WORK/stale-old.log" 2>&1; then
    fail "fabricated stale old object ID unexpectedly passed pre-receive"
fi
grep -Fq "stale old object ID" "$WORK/stale-old.log" \
    || fail "stale old object ID rejection was not explicit"
[ ! -s "$TILLANDSIAS_RELAY_MARKER" ] \
    || fail "stale old object ID reached relay"
[ "$(snapshot_refs "$MIRROR")" = "$MIRROR_BEFORE_STALE" ] \
    || fail "stale old object ID changed mirror refs"
[ "$(snapshot_refs "$UPSTREAM")" = "$UPSTREAM_BEFORE_STALE" ] \
    || fail "stale old object ID changed upstream refs"

MIRROR_BEFORE_INVALID="$(snapshot_refs "$MIRROR")"
UPSTREAM_BEFORE_INVALID="$(snapshot_refs "$UPSTREAM")"
: > "$TILLANDSIAS_RELAY_MARKER"
if printf '%s %s %s\n' "$ZERO_SHA" "$FAST_FORWARD_SHA" refs/heads/invalid..name \
    | (cd "$MIRROR" && hooks/pre-receive) >"$WORK/invalid-ref.log" 2>&1; then
    fail "invalid refname unexpectedly passed pre-receive"
fi
grep -Fq "invalid refname" "$WORK/invalid-ref.log" \
    || fail "invalid refname rejection was not explicit"
[ ! -s "$TILLANDSIAS_RELAY_MARKER" ] \
    || fail "invalid refname reached relay"
[ "$(snapshot_refs "$MIRROR")" = "$MIRROR_BEFORE_INVALID" ] \
    || fail "invalid refname changed mirror refs"
[ "$(snapshot_refs "$UPSTREAM")" = "$UPSTREAM_BEFORE_INVALID" ] \
    || fail "invalid refname changed upstream refs"

: > "$TILLANDSIAS_RELAY_MARKER"
if printf '%s %s %s\n' "$ZERO_SHA" "$FAST_FORWARD_SHA" foo/bar \
    | (cd "$MIRROR" && hooks/pre-receive) >"$WORK/short-ref.log" 2>&1; then
    fail "non-refs/* refname unexpectedly passed pre-receive"
fi
grep -Fq "outside refs/*" "$WORK/short-ref.log" \
    || fail "non-refs/* rejection was not explicit"
[ ! -s "$TILLANDSIAS_RELAY_MARKER" ] \
    || fail "non-refs/* refname reached relay"

BLOB_SHA="$(printf 'not-a-commit\n' | git -C "$MIRROR" hash-object -w --stdin)"
TAG_OBJECT_SHA="$(
    printf 'object %s\ntype commit\ntag annotated-probe\ntagger Fixture <fixture@example.invalid> 1 +0000\n\nprobe\n' \
        "$FAST_FORWARD_SHA" \
        | git -C "$MIRROR" hash-object -t tag -w --stdin
)"
: > "$TILLANDSIAS_RELAY_MARKER"
if printf '%s %s %s\n' "$ZERO_SHA" "$BLOB_SHA" refs/heads/blob-tip \
    | (cd "$MIRROR" && hooks/pre-receive) >"$WORK/blob-tip.log" 2>&1; then
    fail "non-commit branch tip unexpectedly passed pre-receive"
fi
grep -Fq "branch tip is not a commit" "$WORK/blob-tip.log" \
    || fail "non-commit branch rejection was not explicit"
[ ! -s "$TILLANDSIAS_RELAY_MARKER" ] \
    || fail "non-commit branch tip reached relay"
: > "$TILLANDSIAS_RELAY_MARKER"
if printf '%s %s %s\n' "$ZERO_SHA" "$TAG_OBJECT_SHA" refs/heads/tag-object-tip \
    | (cd "$MIRROR" && hooks/pre-receive) >"$WORK/tag-object-tip.log" 2>&1; then
    fail "annotated-tag object unexpectedly passed as a branch tip"
fi
grep -Fq "branch tip is not a commit" "$WORK/tag-object-tip.log" \
    || fail "annotated-tag branch rejection was not explicit"
[ ! -s "$TILLANDSIAS_RELAY_MARKER" ] \
    || fail "annotated-tag branch tip reached relay"
[ "$(snapshot_refs "$MIRROR")" = "$MIRROR_BEFORE_INVALID" ] \
    || fail "malformed transaction checks changed mirror refs"
[ "$(snapshot_refs "$UPSTREAM")" = "$UPSTREAM_BEFORE_INVALID" ] \
    || fail "malformed transaction checks changed upstream refs"
echo "case 5 ok: stale OID, invalid/short ref, and non-commit branches fail before relay"

for delete_ref in refs/tags/v-existing refs/meta/existing; do
    MIRROR_BEFORE_OTHER_DELETE="$(snapshot_refs "$MIRROR")"
    UPSTREAM_BEFORE_OTHER_DELETE="$(snapshot_refs "$UPSTREAM")"
    : > "$TILLANDSIAS_RELAY_MARKER"
    DELETE_LABEL="$(echo "$delete_ref" | tr '/' '-')"
    if git -C "$CLIENT" push mirror ":$delete_ref" >"$WORK/delete-$DELETE_LABEL.log" 2>&1; then
        fail "$delete_ref deletion unexpectedly succeeded"
    fi
    grep -Fq "ref deletion is disabled: $delete_ref" "$WORK/delete-$DELETE_LABEL.log" \
        || fail "$delete_ref rejection did not name the receive policy and ref"
    [ ! -s "$TILLANDSIAS_RELAY_MARKER" ] \
        || fail "$delete_ref deletion reached the privileged relay"
    [ "$(snapshot_refs "$MIRROR")" = "$MIRROR_BEFORE_OTHER_DELETE" ] \
        || fail "rejected $delete_ref deletion changed mirror refs"
    [ "$(snapshot_refs "$UPSTREAM")" = "$UPSTREAM_BEFORE_OTHER_DELETE" ] \
        || fail "rejected $delete_ref deletion changed upstream refs"
done
echo "case 6 ok: tag and custom-ref deletions stop before relay with byte-identical refs"

# A transaction containing one valid fast-forward and one deletion must reject
# atomically before relay; the allowed member cannot leak through by itself.
echo mixed-transaction >> "$CLIENT/file"
git -C "$CLIENT" commit -qam mixed-transaction
MIRROR_BEFORE_MIXED="$(snapshot_refs "$MIRROR")"
UPSTREAM_BEFORE_MIXED="$(snapshot_refs "$UPSTREAM")"
: > "$TILLANDSIAS_RELAY_MARKER"
if git -C "$CLIENT" push --atomic mirror \
    HEAD:refs/heads/main :refs/tags/v-existing >"$WORK/mixed.log" 2>&1; then
    fail "mixed fast-forward/deletion transaction unexpectedly succeeded"
fi
grep -Fq "ref deletion is disabled: refs/tags/v-existing" "$WORK/mixed.log" \
    || fail "mixed transaction did not name its forbidden deletion"
[ ! -s "$TILLANDSIAS_RELAY_MARKER" ] \
    || fail "mixed fast-forward/deletion transaction reached relay"
[ "$(snapshot_refs "$MIRROR")" = "$MIRROR_BEFORE_MIXED" ] \
    || fail "rejected mixed transaction changed mirror refs"
[ "$(snapshot_refs "$UPSTREAM")" = "$UPSTREAM_BEFORE_MIXED" ] \
    || fail "rejected mixed transaction changed upstream refs"
echo "case 7 ok: mixed fast-forward/deletion rejects atomically before relay"

# The relay helper is also fail-closed when invoked directly, so a future
# alternate caller cannot bypass pre-receive and borrow the service credential.
MIRROR_BEFORE_DIRECT="$(snapshot_refs "$MIRROR")"
UPSTREAM_BEFORE_DIRECT="$(snapshot_refs "$UPSTREAM")"
TAG_SHA="$(git -C "$MIRROR" rev-parse refs/tags/v-existing)"
if printf '%s %s %s\n' "$TAG_SHA" "$ZERO_SHA" refs/tags/v-existing \
    | (cd "$MIRROR" && hooks/tillandsias-relay-refs.real) >"$WORK/direct-relay-delete.log" 2>&1; then
    fail "direct relay helper accepted a deletion"
fi
grep -Fq "upstream ref deletion" "$WORK/direct-relay-delete.log" \
    || fail "direct relay deletion refusal was not explicit"
[ "$(snapshot_refs "$MIRROR")" = "$MIRROR_BEFORE_DIRECT" ] \
    || fail "direct relay deletion refusal changed mirror refs"
[ "$(snapshot_refs "$UPSTREAM")" = "$UPSTREAM_BEFORE_DIRECT" ] \
    || fail "direct relay deletion refusal changed upstream refs"

# Exact-three-field parsing and safely quoted argv construction close the
# concrete smuggling primitive where EXTRA was absorbed into REFNAME and then
# unquoted word splitting turned it into `:victim` or `--force` push argv.
if printf '%s %s %s %s\n' "$ZERO_SHA" "$FAST_FORWARD_SHA" \
    refs/heads/smuggled :refs/tags/v-existing \
    | (cd "$MIRROR" && hooks/tillandsias-relay-refs.real) >"$WORK/direct-smuggled-delete.log" 2>&1; then
    fail "direct relay accepted a whitespace-smuggled delete refspec"
fi
grep -Fq "malformed receive transaction" "$WORK/direct-smuggled-delete.log" \
    || fail "whitespace-smuggled deletion was not rejected as malformed"

if printf '%s %s %s %s\n' "$FAST_FORWARD_SHA" "$BASE_SHA" \
    refs/heads/main --force \
    | (cd "$MIRROR" && hooks/tillandsias-relay-refs.real) >"$WORK/direct-smuggled-force.log" 2>&1; then
    fail "direct relay accepted a whitespace-smuggled --force option"
fi
grep -Fq "malformed receive transaction" "$WORK/direct-smuggled-force.log" \
    || fail "whitespace-smuggled --force was not rejected as malformed"

if printf '%s %s %s\n' "$ZERO_SHA" "$FAST_FORWARD_SHA" foo/bar \
    | (cd "$MIRROR" && hooks/tillandsias-relay-refs.real) >"$WORK/direct-short-ref.log" 2>&1; then
    fail "direct relay accepted a ref outside refs/*"
fi
grep -Fq "outside refs/*" "$WORK/direct-short-ref.log" \
    || fail "direct relay did not explicitly reject a ref outside refs/*"

if printf '%s %s %s\n' "$ZERO_SHA" "$BLOB_SHA" refs/heads/blob-direct \
    | (cd "$MIRROR" && hooks/tillandsias-relay-refs.real) >"$WORK/direct-blob-tip.log" 2>&1; then
    fail "direct relay accepted a non-commit branch tip"
fi
grep -Fq "branch tip is not a commit" "$WORK/direct-blob-tip.log" \
    || fail "direct relay did not explicitly reject a non-commit branch tip"
if printf '%s %s %s\n' "$ZERO_SHA" "$TAG_OBJECT_SHA" refs/heads/tag-object-direct \
    | (cd "$MIRROR" && hooks/tillandsias-relay-refs.real) >"$WORK/direct-tag-object-tip.log" 2>&1; then
    fail "direct relay accepted an annotated-tag object as a branch tip"
fi
grep -Fq "branch tip is not a commit" "$WORK/direct-tag-object-tip.log" \
    || fail "direct relay did not reject annotated-tag branch tip exactly"
[ "$(snapshot_refs "$MIRROR")" = "$MIRROR_BEFORE_DIRECT" ] \
    || fail "direct relay adversarial inputs changed mirror refs"
[ "$(snapshot_refs "$UPSTREAM")" = "$UPSTREAM_BEFORE_DIRECT" ] \
    || fail "direct relay adversarial inputs changed upstream refs"
echo "case 8 ok: relay refuses deletion, parser smuggling, short refs, and non-commit branches"

# SHA-256 repositories use a 64-hex zero object ID. Exercise the exact hook in
# that format so a future hardcoded SHA-1 zero cannot turn deletion into an
# apparent update and leak it to relay.
SHA256_REPO="$WORK/sha256.git"
SHA256_CLIENT="$WORK/sha256-client"
git init -q --bare --object-format=sha256 "$SHA256_REPO" \
    || fail "host Git cannot initialize the required SHA-256 regression repo"
git init -q --object-format=sha256 "$SHA256_CLIENT"
git -C "$SHA256_CLIENT" config core.hooksPath ""
git -C "$SHA256_CLIENT" commit --allow-empty -qm sha256-base
git -C "$SHA256_CLIENT" branch -M main
git -C "$SHA256_CLIENT" push -q "$SHA256_REPO" HEAD:refs/heads/main
git -C "$SHA256_REPO" config core.hooksPath "$SHA256_REPO/hooks"
cp "$ROOT/images/git/pre-receive-hook.sh" "$SHA256_REPO/hooks/pre-receive"
cat > "$SHA256_REPO/hooks/tillandsias-relay-refs" <<'SHA256_RELAY'
#!/bin/sh
: "${TILLANDSIAS_SHA256_RELAY_MARKER:?missing sha256 relay marker}"
printf 'invoked\n' >> "$TILLANDSIAS_SHA256_RELAY_MARKER"
exit 0
SHA256_RELAY
chmod +x "$SHA256_REPO/hooks/pre-receive" "$SHA256_REPO/hooks/tillandsias-relay-refs"
export TILLANDSIAS_SHA256_RELAY_MARKER="$WORK/sha256-relay-invocations"
: > "$TILLANDSIAS_SHA256_RELAY_MARKER"
SHA256_HEAD="$(git -C "$SHA256_REPO" rev-parse refs/heads/main)"
SHA256_SAMPLE="$(git -C "$SHA256_REPO" hash-object --stdin </dev/null)"
SHA256_ZERO="$(printf '%*s' "${#SHA256_SAMPLE}" '' | tr ' ' '0')"
[ "${#SHA256_ZERO}" -eq 64 ] || fail "SHA-256 fixture did not derive a 64-hex zero OID"
if printf '%s %s %s\n' "$SHA256_HEAD" "$SHA256_ZERO" refs/heads/main \
    | (cd "$SHA256_REPO" && hooks/pre-receive) >"$WORK/sha256-delete.log" 2>&1; then
    fail "SHA-256 deletion unexpectedly passed pre-receive"
fi
grep -Fq "ref deletion is disabled" "$WORK/sha256-delete.log" \
    || fail "SHA-256 deletion rejection was not explicit"
[ ! -s "$TILLANDSIAS_SHA256_RELAY_MARKER" ] \
    || fail "SHA-256 deletion reached relay"
[ "$(git -C "$SHA256_REPO" rev-parse refs/heads/main)" = "$SHA256_HEAD" ] \
    || fail "SHA-256 deletion changed the repository ref"
echo "case 9 ok: SHA-256 zero OID is derived and deletion stops before relay"

git -C "$MIRROR" fsck --full --strict >/dev/null
git -C "$UPSTREAM" fsck --full --strict >/dev/null
git -C "$SHA256_REPO" fsck --full --strict >/dev/null

echo "PASS: git mirror existing-volume receive hardening fixture (order 579)"
