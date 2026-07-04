#!/usr/bin/env bash
# release-preflight-local.sh -- local release gate before spending hosted minutes
# @trace spec:observability-convergence, spec:ci-release, spec:spec-traceability
#
# Runs checks that do not require GitHub-hosted platform runners, OIDC signing,
# or release publication. The hosted release workflow should be dispatched only
# after this script passes on the release candidate checkout.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run_local_ci=1
run_nix_probe=0
local_ci_args=()

usage() {
    cat <<'EOF'
Usage: scripts/release-preflight-local.sh [--fast] [--nix-probe] [--skip-local-ci] [-- LOCAL_CI_ARGS...]

Local release gate:
  1. fetches release tags for version monotonicity checks
  2. verifies VERSION is monotonic
  3. runs scripts/local-ci.sh locally (cargo checks, litmus, dashboards)
  4. optionally probes the Linux Nix release targets without publishing

Options:
  --fast           pass --fast to scripts/local-ci.sh
  --nix-probe      run local nix build --no-link for release targets
  --skip-local-ci  skip scripts/local-ci.sh, useful after an already logged pass
  --help           show this help

Everything after -- is passed to scripts/local-ci.sh.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fast)
            local_ci_args+=(--fast)
            shift
            ;;
        --nix-probe)
            run_nix_probe=1
            shift
            ;;
        --skip-local-ci)
            run_local_ci=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            local_ci_args+=("$@")
            break
            ;;
        *)
            local_ci_args+=("$1")
            shift
            ;;
    esac
done

step() {
    printf '\n==> %s\n' "$1"
}

step "Fetch release refs"
if git remote get-url origin >/dev/null 2>&1; then
    git fetch --prune origin
    git fetch --force --tags origin
else
    echo "No origin remote configured; skipping fetch."
fi

step "Verify version monotonicity"
bash scripts/verify-version-monotonic.sh

if [[ "$run_local_ci" == "1" ]]; then
    step "Run local CI gate"
    bash scripts/local-ci.sh "${local_ci_args[@]}"
else
    step "Skip local CI gate"
fi

if [[ "$run_nix_probe" == "1" ]]; then
    step "Probe Linux release Nix targets locally"
    if ! command -v nix >/dev/null 2>&1; then
        echo "nix is required for --nix-probe" >&2
        exit 2
    fi
    nix build -L .#tillandsias-x86_64-musl           --no-link
    nix build -L .#tillandsias-headless-x86_64-musl  --no-link
    nix build -L .#tillandsias-headless-aarch64-musl --no-link
fi

step "Release preflight complete"
version="$(tr -d '[:space:]' < VERSION)"
release_ref="$(git branch --show-current 2>/dev/null || true)"
if [[ -z "$release_ref" ]]; then
    release_ref="$(git rev-parse --short=12 HEAD)"
fi
cat <<EOF
Next release steps:
  git status --short
  git push origin HEAD
  gh workflow run release.yml --ref ${release_ref} -f version=${version}

Dispatch the hosted release only after the local release-preflight changes,
including regenerated dashboards under docs/convergence/, are committed and
pushed to the release ref.
EOF
