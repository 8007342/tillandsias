#!/usr/bin/env bash
# @trace order:1235-rfub, spec:ci-release
#
# attest-native-lint.sh — lint the cfg-gated platform crates NATIVELY, and only
# on success record that as a `Native-Lint:` trailer on an empty commit.
#
# The ONLY writer of the attestation scripts/check-native-lint-attested.sh
# requires at relay time (1235-rfub). Hand-writing the trailer is possible, and
# is exactly the claim-without-a-run the ruling warned about; this script
# exists so nobody has to. It binds the attestation to the LINTED CONTENT (the
# crate's subtree sha), so a later edit makes it stale rather than silently
# carrying it forward.
#
# Run on the crate's own platform, on a clean, committed tree:
#   scripts/attest-native-lint.sh
#
#   ok:attest-native-lint:<pkg>=<tree>[ ...]           commit added with trailers
#   ok:attest-native-lint:nothing-to-attest            no gated crate for this platform
#   refused:attest-native-lint:dirty-tree              (rc 2) lint what is committed
#   refused:attest-native-lint:no-host                 (rc 2) no host name; NO commit
#   failed:attest-native-lint:<pkg>:rc=<n>             (rc 1) clippy failed; NO commit
#
# CARGO overrides the cargo binary (the fixture stubs it).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
CARGO="${CARGO:-cargo}"

case "$(uname -s)" in
    Darwin) platform=darwin ;;
    Linux) platform=linux ;;
    MINGW*|MSYS*|CYGWIN*) platform=windows ;;
    *) platform="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
esac
platform="${TILLANDSIAS_NATIVE_LINT_PLATFORM:-$platform}"

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "refused:attest-native-lint:dirty-tree"
    echo "  why: the attestation names committed content, and this tree has uncommitted changes" >&2
    echo "  remedy: commit (or stash) them, then re-run scripts/attest-native-lint.sh" >&2
    exit 2
fi

host="$(bash scripts/agent-identity.sh node-name 2>/dev/null)" || host=""
[ -n "$host" ] || host="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
# Git Bash rejects `hostname -s` and the WSL builder has no hostname at all;
# uname -n is POSIX. An empty host shifts every trailer field and the check
# can never match it, so refuse rather than write one.
[ -n "$host" ] || host="$(uname -n 2>/dev/null | cut -d. -f1 | tr '[:upper:]' '[:lower:]')"
case "$host" in
    "" | *[[:space:]]*)
        echo "refused:attest-native-lint:no-host"
        echo "  why: no host name from agent-identity.sh, hostname -s or uname -n, and a trailer with an empty or split host field never matches its check" >&2
        echo "  remedy: make scripts/agent-identity.sh node-name answer on this host, then re-run scripts/attest-native-lint.sh" >&2
        exit 2
        ;;
esac

trailers=(); done_list=""
for entry in $(bash scripts/check-native-lint-attested.sh --list); do
    path="${entry%%:*}"; rest="${entry#*:}"; pkg="${rest%%:*}"; want="${rest#*:}"
    [ "$want" = "$platform" ] || continue
    tree="$(git rev-parse --verify --quiet "HEAD:$path")" || continue
    echo "attest-native-lint: $CARGO clippy -p $pkg --all-targets -- -D warnings" >&2
    "$CARGO" clippy -p "$pkg" --all-targets -- -D warnings
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "failed:attest-native-lint:$pkg:rc=$rc"
        exit 1
    fi
    trailers+=(--trailer "Native-Lint: $host $platform $path=$tree clippy-all-targets-D-warnings")
    done_list="${done_list:+$done_list }$pkg=$tree"
done

if [ -z "$done_list" ]; then
    echo "ok:attest-native-lint:nothing-to-attest"
    exit 0
fi
git commit -q --allow-empty -m "native-lint: $platform clippy --all-targets -D warnings ok ($host)" "${trailers[@]}" || {
    echo "failed:attest-native-lint:commit"
    exit 1
}
echo "ok:attest-native-lint:$done_list"
