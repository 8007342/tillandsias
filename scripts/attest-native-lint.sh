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
#
# REF MODE (order 2112-nlrf). `--ref` writes the attestation as a ref instead of
# a commit on the branch:
#     refs/attest/native-lint/<tree-sha>
# pointing at a parentless commit WHOSE TREE IS the linted crate subtree, with
# the same `Native-Lint:` line in its message. So the ref verifies itself
# (`<ref>^{tree}` must equal its name), survives a rebase or squash of the
# branch, and needs no new commit on a PR. `--push` also pushes the ref(s) to
# origin. `--at <commit>` lints THAT commit's content (single checkout: switch
# --detach, lint, switch back), which is how a darwin host services a land-queue
# HOLD naming a merged subtree (check-native-lint-attested.sh --hold).
#   ok:attest-native-lint:ref:<pkg>=<tree>[ ...]        ref(s) written (and pushed)
#   ok:attest-native-lint:ref-exists:<pkg>=<tree>       already attested; no clippy run
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
CARGO="${CARGO:-cargo}"

MODE=commit; PUSH=0; AT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ref) MODE=ref ;;
        --push) PUSH=1 ;;
        --at) AT="${2:?--at needs a commit}"; shift ;;
        *) echo "refused:attest-native-lint:unknown-arg:$1"
           echo "  why: an unknown argument would otherwise be ignored, and a mistyped --ref would write a commit instead" >&2
           echo "  remedy: use only --ref, --push and --at <commit> (see the header of scripts/attest-native-lint.sh)" >&2
           exit 2 ;;
    esac
    shift
done
if [ -n "$AT" ] && [ "$MODE" != ref ]; then
    echo "refused:attest-native-lint:at-needs-ref"
    echo "  why: --at lints another commit's content; only a ref can record that without a commit on this branch" >&2
    echo "  remedy: add --ref: scripts/attest-native-lint.sh --ref --push --at <commit>" >&2
    exit 2
fi

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

# --at: lint another commit's content in THIS checkout, and always come back.
if [ -n "$AT" ]; then
    if ! git rev-parse --verify --quiet "$AT^{commit}" >/dev/null; then
        echo "refused:attest-native-lint:at-unknown:$AT"
        echo "  why: --at names no commit in this repository, so there is no content to lint" >&2
        echo "  remedy: fetch it first (git fetch origin <branch>), then pass the commit or origin/<branch>" >&2
        exit 2
    fi
    _back="$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)"
    if ! git switch -q --detach "$AT"; then
        echo "refused:attest-native-lint:at-switch-failed:$AT"
        echo "  why: this checkout could not switch to $AT to lint its content (git's message is above)" >&2
        echo "  remedy: resolve what git names (usually an untracked file in the way), then re-run" >&2
        exit 2
    fi
    trap 'git switch -q "$_back" 2>/dev/null || git switch -q --detach "$_back"' EXIT
fi

# A ref is valid only if its commit's tree IS the subtree it is named for and
# its message carries this platform's Native-Lint line for this path.
ref_valid() { # ref_valid <path> <tree>
    local r="refs/attest/native-lint/$2"
    [ "$(git rev-parse --verify --quiet "$r^{tree}" 2>/dev/null)" = "$2" ] || return 1
    git log -1 --format=%B "$r" 2>/dev/null | grep -q "^Native-Lint: [^ ]* $platform $1=$2 "
}

trailers=(); done_list=""; refs=(); exists_list=""
for entry in $(bash scripts/check-native-lint-attested.sh --list); do
    path="${entry%%:*}"; rest="${entry#*:}"; pkg="${rest%%:*}"; want="${rest#*:}"
    [ "$want" = "$platform" ] || continue
    tree="$(git rev-parse --verify --quiet "HEAD:$path")" || continue
    if [ "$MODE" = ref ] && ref_valid "$path" "$tree"; then
        refs+=("refs/attest/native-lint/$tree")
        exists_list="${exists_list:+$exists_list }$pkg=$tree"
        continue
    fi
    echo "attest-native-lint: $CARGO clippy -p $pkg --all-targets -- -D warnings" >&2
    "$CARGO" clippy -p "$pkg" --all-targets -- -D warnings
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "failed:attest-native-lint:$pkg:rc=$rc"
        exit 1
    fi
    line="Native-Lint: $host $platform $path=$tree clippy-all-targets-D-warnings"
    if [ "$MODE" = ref ]; then
        c="$(printf 'native-lint: %s clippy --all-targets -D warnings ok (%s)\n\n%s\n' "$platform" "$host" "$line" \
             | git commit-tree "$tree")" || { echo "failed:attest-native-lint:commit-tree"; exit 1; }
        git update-ref "refs/attest/native-lint/$tree" "$c" || { echo "failed:attest-native-lint:update-ref"; exit 1; }
        refs+=("refs/attest/native-lint/$tree")
    else
        trailers+=(--trailer "$line")
    fi
    done_list="${done_list:+$done_list }$pkg=$tree"
done

if [ "$MODE" = ref ]; then
    if [ "$PUSH" -eq 1 ] && [ "${#refs[@]}" -gt 0 ]; then
        _pspecs=()
        for r in "${refs[@]}"; do _pspecs+=("$r:$r"); done
        git push -q origin "${_pspecs[@]}" || { echo "failed:attest-native-lint:push"; exit 1; }
    fi
    [ -n "$done_list" ] && echo "ok:attest-native-lint:ref:$done_list"
    [ -n "$exists_list" ] && echo "ok:attest-native-lint:ref-exists:$exists_list"
    [ -z "$done_list$exists_list" ] && echo "ok:attest-native-lint:nothing-to-attest"
    exit 0
fi
if [ -z "$done_list" ]; then
    echo "ok:attest-native-lint:nothing-to-attest"
    exit 0
fi
git commit -q --allow-empty -m "native-lint: $platform clippy --all-targets -D warnings ok ($host)" "${trailers[@]}" || {
    echo "failed:attest-native-lint:commit"
    exit 1
}
echo "ok:attest-native-lint:$done_list"
