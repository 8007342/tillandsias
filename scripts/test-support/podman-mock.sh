#!/usr/bin/env bash
set -euo pipefail
# freshness: auditor=linux-forge-20260718T0334Z date=2026-07-18 verdict=refreshed scope=re-validated; still used by run-litmus-test.sh and remote_projects.rs command-shape litmus; verdict from 2026-07-17 (exec branch no longer fabricates vault handover) still holds; keychain isolation ask still open

# Minimal Podman test backend for command-shape litmus runs.
# It records the invocation and returns canned success outputs for the
# subcommands Tillandsias uses in build/litmus command-contract tests.

subcommand="${1:-}"
if [[ -n "${LITMUS_PODMAN_STATE_DIR:-}" ]]; then
    state_dir="$LITMUS_PODMAN_STATE_DIR"
else
    calls_file="${LITMUS_PODMAN_CALLS_FILE:-/tmp/litmus-podman-calls.log}"
    state_dir="$(dirname "$calls_file")/.fake-podman-state"
fi
secret_dir="$state_dir/secrets"
image_dir="$state_dir/images"
mkdir -p "$secret_dir"
mkdir -p "$image_dir"

image_key() {
    printf '%s' "$1" | sed 's|/|__slash__|g; s|:|__colon__|g'
}

image_path() {
    printf '%s/%s' "$image_dir" "$(image_key "$1")"
}

stateful_images_enabled() {
    [[ "${LITMUS_PODMAN_STATEFUL_IMAGES:-0}" == "1" ]]
}

case "$subcommand" in
    build)
        if stateful_images_enabled; then
            tag=""
            previous=""
            for arg in "$@"; do
                if [[ "$previous" == "--tag" || "$previous" == "-t" ]]; then
                    tag="$arg"
                    break
                fi
                previous="$arg"
            done
            if [[ -n "$tag" ]]; then
                printf 'mock-build-id\n' >"$(image_path "$tag")"
            fi
        fi
        printf 'mock-build-id\n'
        ;;
    image)
        case "${2:-}" in
            exists)
                if stateful_images_enabled; then
                    [[ -f "$(image_path "${3:-}")" ]]
                    exit $?
                fi
                exit 0
                ;;
            inspect)
                for arg in "$@"; do
                    if [[ "$arg" == "--format" ]]; then
                        printf '0\n'
                        exit 0
                    fi
                done
                if [[ "${3:-}" == "--format" ]]; then
                    printf '0\n'
                fi
                ;;
            prune)
                exit 0
                ;;
        esac
        ;;
    images)
        if stateful_images_enabled; then
            for image in "$image_dir"/*; do
                [[ -e "$image" ]] || continue
                basename "$image" | sed 's|__slash__|/|g; s|__colon__|:|g'
            done
            exit 0
        fi
        # Intentionally emit no existing tags so stale-image cleanup is a no-op.
        exit 0
        ;;
    tag)
        if stateful_images_enabled; then
            source_tag="${2:-}"
            dest_tag="${3:-}"
            if [[ -z "$source_tag" || -z "$dest_tag" ]]; then
                exit 1
            fi
            if [[ ! -f "$(image_path "$source_tag")" ]]; then
                exit 1
            fi
            cp "$(image_path "$source_tag")" "$(image_path "$dest_tag")"
        fi
        exit 0
        ;;
    rmi)
        if stateful_images_enabled; then
            for arg in "$@"; do
                [[ "$arg" == "rmi" || "$arg" == "-f" ]] && continue
                rm -f "$(image_path "$arg")"
            done
        fi
        exit 0
        ;;
    inspect)
        printf '{"Secrets":["vault-token","tillandsias-ca-cert","tillandsias-ca-key"]}\n'
        ;;
    info)
        printf '{}\n'
        ;;
    run|create)
        if [[ "$subcommand" == "run" ]]; then
            cmd_string="$*"
            if [[ "$cmd_string" == *"status-check"* ]]; then
                printf '[status-check] running inside forge container\n'
                printf '[status-check] proxy online\n'
                printf '[status-check] git online\n'
                printf '[status-check] inference online\n'
                printf '[status-check] forge online\n'
                exit 0
            fi
            if [[ "$cmd_string" == *"gh api user/repos"* ]]; then
                printf '[{"name":"forge","owner":{"login":"8007342"},"description":"Mock repo","url":"https://github.com/8007342/forge","archived":false}]\n'
                exit 0
            fi
            if [[ "$cmd_string" == *"gh repo clone"* ]]; then
                target_path="${@: -1}"
                # Tail args after the "gh" sentinel are the positional
                # `gh repo clone <repo> <target>` arguments. The two
                # immediately before $target_path are the repo identifier.
                repo_arg="${@: -2:1}"
                printf '%s\n' "$repo_arg" >"$state_dir/last_clone_repo_arg"
                printf '%s\n' "$target_path" >"$state_dir/last_clone_target_arg"
                # Record the full arg vector (one per line) so tests can
                # assert on bind-mount and security flags. Each line is one
                # argument verbatim — preserves spaces inside values.
                : >"$state_dir/last_clone_run_args"
                for a in "$@"; do
                    printf '%s\n' "$a" >>"$state_dir/last_clone_run_args"
                done
                mkdir -p "$target_path/.git"
                printf 'mock-clone-ok\n'
                exit 0
            fi
            if [[ "$cmd_string" == *"/run/secrets/"* ]]; then
                for arg in "$@"; do
                    case "$arg" in
                        /run/secrets/*)
                            secret_name="${arg##*/run/secrets/}"
                            if [[ -f "$secret_dir/$secret_name" ]]; then
                                cat "$secret_dir/$secret_name"
                                exit 0
                            fi
                            ;;
                    esac
                done
            fi
        fi
        printf 'mock-container-id\n'
        ;;
    secret)
        case "${2:-}" in
            create)
                secret_name=""
                for arg in "$@"; do
                    if [[ "$secret_name" == "__next__" ]]; then
                        secret_name="$arg"
                        break
                    fi
                    [[ "$arg" == "create" ]] && secret_name="__next__"
                done
                secret_name="${secret_name#__next__}"
                if [[ -z "$secret_name" ]]; then
                    secret_name="${@: -2:1}"
                fi
                secret_value="$(cat)"
                printf '%s' "$secret_value" >"$secret_dir/$secret_name"
                printf 'mock-secret-id\n'
                ;;
            rm)
                secret_name="${2:-}"
                rm -f "$secret_dir/$secret_name"
                exit 0
                ;;
            inspect)
                secret_name="${2:-}"
                if [[ -f "$secret_dir/$secret_name" ]]; then
                    printf '{"Name":"%s"}\n' "$secret_name"
                    exit 0
                fi
                exit 1
                ;;
            ls)
                for f in "$secret_dir"/*; do
                    [[ -e "$f" ]] || continue
                    printf '%s\n' "$(basename "$f")"
                done
                exit 0
                ;;
        esac
        ;;
    exec)
        if [[ "$*" == *"gh auth login"* ]]; then
            exit 0
        fi
        if [[ "$*" == *"gh auth status"* ]]; then
            printf 'github.com: authenticated\n'
            exit 0
        fi
        if [[ "$*" == *"gh auth token"* ]]; then
            printf '%s\n' "${LITMUS_FAKE_GITHUB_TOKEN:-mock-github-token}"
            exit 0
        fi
        if [[ "$*" == *"gh api user"* ]]; then
            printf '%s\n' "${LITMUS_FAKE_GITHUB_USER:-mock-user}"
            exit 0
        fi
        # Never fabricate a vault first-boot handover: answering
        # `cat /run/vault-handover/*` with canned output made the real
        # binary persist `mock-exec-output` over the operator's REAL
        # keychain credentials (order 383 root cause, 2026-07-17 —
        # plan/issues/litmus-mock-podman-keychain-pollution-2026-07-17.md).
        # A mocked vault container has no handover files; behave like it.
        if [[ "$*" == *"/run/vault-handover/"* ]]; then
            exit 1
        fi
        printf 'mock-exec-output\n'
        ;;
    version)
        printf 'podman version 5.0.0-mock\n'
        ;;
    stop|rm|network|compose|system)
        exit 0
        ;;
esac

exit 0
