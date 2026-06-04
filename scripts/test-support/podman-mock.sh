#!/usr/bin/env bash
set -euo pipefail

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
mkdir -p "$secret_dir"

case "$subcommand" in
    build)
        printf 'mock-build-id\n'
        ;;
    image)
        case "${2:-}" in
            exists)
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
        # Intentionally emit no existing tags so stale-image cleanup is a no-op.
        exit 0
        ;;
    inspect)
        printf '{"Secrets":["tillandsias-github-token","tillandsias-ca-cert","tillandsias-ca-key"]}\n'
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
