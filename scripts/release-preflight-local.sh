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

step "Refresh tracked release evidence (docs/convergence dashboards)"
# Order 495 (preflight-evidence-dirties-forge-gate): the local CI gate above
# routes its own dashboard regeneration under target/ so the post-build forge
# gate always starts from a clean worktree. The TRACKED docs/convergence
# projection — committed release evidence per docs/RELEASING.md step 4 — is
# regenerated HERE, after the gate, so generated dirt never sits between
# generation and the forge gate. As a bonus this render includes the
# signature record the gate just appended (previously the committed
# dashboards lagged one CI run).
bash scripts/update-convergence-dashboard.sh

if [[ "$run_nix_probe" == "1" ]]; then
    step "Probe Linux release Nix targets locally"
    # TOOLBOX-FIRST (methodology multi_host_development.toolbox_first_scripts,
    # order 777-amku). This probe used to require a host `nix` AND, implicitly,
    # a live nix-daemon: bare `nix build` addresses the daemon socket, so on a
    # host with the binary but the socket down it failed with "cannot connect
    # to socket" and the standing remedy was `sudo systemctl enable --now
    # nix-daemon.socket` — the host-daemon ask the operator withdrew on
    # 2026-08-16 (606-um5s). scripts/nix-toolbox.sh resolves a usable nix
    # WITHOUT one: the live daemon if there is one, else a rootless chroot
    # store under $HOME, else nix inside the tillandsias-nix toolbox. The three
    # other nix consumers (check-nix-deps-stability.sh, nix-deps-drv-paths.sh,
    # build-guest-binaries.sh) already take their flags this way; this was the
    # last one that did not.
    nix_rung="$(bash "$ROOT/scripts/nix-toolbox.sh" ensure)" || {
        printf '%s\n' "$nix_rung" >&2
        echo "--nix-probe: no usable nix lane; see scripts/nix-toolbox.sh" >&2
        exit 2
    }
    echo "  nix lane: $nix_rung"

    # `nix-args` covers the daemon and chroot rungs. It refuses the toolbox
    # rung on purpose — flake outputs are addressed by CHECKOUT path, which a
    # container does not share — so say that plainly instead of running a
    # `nix` that is not there.
    nix_args=()
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            nix_args+=("$line")
        fi
    done < <(bash "$ROOT/scripts/nix-toolbox.sh" nix-args 2>/dev/null)
    if [[ ${#nix_args[@]} -eq 0 ]]; then
        echo "--nix-probe: rung '$nix_rung' exposes no host nix flags" >&2
        echo "  the toolbox rung cannot address flake outputs by checkout path;" >&2
        echo "  run --nix-probe on a host with nix, or extend scripts/nix-toolbox.sh." >&2
        exit 2
    fi

    # ${arr[0]+"${arr[@]}"} — bash 3.2 raises "unbound variable" on a bare
    # "${arr[@]}" for an empty array under set -u (macOS system bash is the
    # floor here). The guard is redundant after the count check above and kept
    # anyway so a later edit cannot reintroduce the 3.2 trap.
    _probe_nix() {
        nix ${nix_args[0]+"${nix_args[@]}"} "$@"
    }
    _probe_nix build -L .#tillandsias-x86_64-musl           --no-link
    _probe_nix build -L .#tillandsias-headless-x86_64-musl  --no-link
    _probe_nix build -L .#tillandsias-headless-aarch64-musl --no-link
fi

step "Release preflight complete"
evidence_dirt="$(git status --porcelain -- TRACES.md 'openspec/specs/*/TRACES.md' docs/convergence || true)"
if [[ -n "$evidence_dirt" ]]; then
    printf 'Generated release evidence awaiting commit (docs/RELEASING.md step 4):\n%s\n\n' "$evidence_dirt"
fi
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
