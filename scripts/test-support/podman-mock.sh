#!/usr/bin/env bash
set -euo pipefail
# freshness: auditor=linux-macuahuitl-claude-20260818t030000z date=2026-08-18 verdict=updated scope=797-p2xa nested half: the top-level *) arm (97cb255a9) could not see three more fall-throughs one level down — image <unknown>, secret <unknown>, and image inspect without --format each left their arm with no output and landed on the trailing exit 0; all four sites now share mock_refuse() and exit 97, argv is captured before the global-flag skip so the diagnostic quotes what the caller actually ran; bounded by a FULL pre-build litmus at every size (before 309 PASS/6 FAIL/315 executed, after 311 PASS/5 FAIL/316 executed, and the refusal fired ZERO times in either run, so nothing depended on the permissive tail) plus a new fixture (scripts/test-podman-mock-refusal.sh, 12 scenarios) wired as litmus:podman-mock-refuses-unknown-invocations; a secret-arm argument-position defect found while auditing is filed as 813-frih, not fixed here
# freshness: auditor=linux-yoga-claude-20260816t185912z date=2026-08-16 verdict=updated scope=666-qbjd: run/create arm records --hostname/--network-alias (tracked-file lines 3+), inspect arm replays a real json array for TRACKED containers (State.Status, Config.Hostname, aliases) so inspect_container round-trips; untracked names keep the byte-identical Secrets fallback; full fixture set (1, 2a-2c, 3b) re-run green
# freshness: auditor=linux-macuahuitl-fable5-20260810t1910z date=2026-08-10 verdict=refreshed scope=closed the 2026-08-03 Windows audit's open ask: behavioral confirmation litmus:podman-build-command-shape EXECUTED on Linux substrate (podman-orchestration instant tier 4/4 PASS, 0 FAIL); all 6 consumers still live (run-litmus-test.sh, test-concurrent-forge-shared-stack.sh, remote_projects.rs, 3 litmus yamls); no stale arm found
# freshness: auditor=linux-mutable-root-codex-20260806t001750z date=2026-08-05 verdict=refreshed scope=top inventory finding audited on mutable Linux: all live callers re-enumerated; bash syntax passed; stateful run/create/inspect/ps/stop/rm behavior exercised end-to-end by scripts/test-concurrent-forge-shared-stack.sh (fixtures 1, 2a, 2b, 2c PASS); no stale arm found; inventory threshold/0%-rounding defect filed as order 606-vaua
# freshness: auditor=forge-tillandsias-codex-20260803t214004z date=2026-08-03 verdict=updated scope=re-validated syntax, vault-handover refusal, remote-project preflight, and stateful-container litmus consumers after order-443 tracking; corrected advisory age sorting in local-ci.sh
# freshness: auditor=windows-claude-fable-metaorch-20260803 date=2026-08-03 verdict=refreshed scope=structural re-validation from the Windows host: the ps --format json replay still matches PodmanClient's serde shape (client.rs:1795-1797 Names/State), and all 6 consumers are live (run-litmus-test.sh, test-concurrent-forge-shared-stack.sh, remote_projects.rs, 3 litmus yamls); behavioral confirmation via litmus:podman-build-command-shape was NOT reached on this host (corpus needs Linux substrate — see plan/issues/litmus-corpus-not-host-aware-windows-2026-08-03.md), next Linux cycle should run it; keychain isolation ask still open

# Minimal Podman test backend for command-shape litmus runs.
# It records the invocation and returns canned success outputs for the
# subcommands Tillandsias uses in build/litmus command-contract tests.

# Real podman accepts GLOBAL flags BEFORE the subcommand — `podman --remote
# --url <u> run ...` is what scripts/common.sh's wrapper branch generates, and
# TILLANDSIAS_PODMAN_REMOTE_URL in the environment makes the Rust launcher emit
# the same shape. Skip them so dispatch sees the subcommand rather than a flag.
#
# Order 797-p2xa. Without this the `case` below matched nothing for `--remote`
# and fell through to the final bare `exit 0`: success, no output, nothing
# done. Callers cannot see that as a mock failure, only as its consequences —
# four remote_projects tests reported `atomic rename failed: No such file or
# directory` (the temp checkout the mock never created) and `invalid gh JSON:
# EOF while parsing a value at line 1 column 0` (the array it never printed).
# Reproduces in one line: TILLANDSIAS_PODMAN_REMOTE_URL=unix:///x cargo test
# -p tillandsias-headless --bin tillandsias --features tray remote_projects.
#
# Captured BEFORE the skip loop so a refusal can quote the invocation the
# caller actually made. The landed `*)` arm printed the post-shift `$*`, which
# drops exactly the global flags the incident was about.
PODMAN_MOCK_ARGV=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote|--syslog|--noout)
            shift
            ;;
        --url|--connection|--identity|--root|--runroot|--tmpdir| \
        --storage-driver|--storage-opt|--log-level|--cgroup-manager| \
        --events-backend|--runtime|--conmon|--module)
            shift
            # Guard the value shift: `shift 2` with one argument left fails,
            # and this script runs under `set -e`.
            if [[ $# -gt 0 ]]; then
                shift
            fi
            ;;
        --*=*)
            shift
            ;;
        *)
            break
            ;;
    esac
done

subcommand="${1:-}"
if [[ -n "${LITMUS_PODMAN_STATE_DIR:-}" ]]; then
    state_dir="$LITMUS_PODMAN_STATE_DIR"
else
    calls_file="${LITMUS_PODMAN_CALLS_FILE:-/tmp/litmus-podman-calls.log}"
    state_dir="$(dirname "$calls_file")/.fake-podman-state"
fi
secret_dir="$state_dir/secrets"
image_dir="$state_dir/images"
container_dir="$state_dir/containers"
mkdir -p "$secret_dir"
mkdir -p "$image_dir"
mkdir -p "$container_dir"

image_key() {
    printf '%s' "$1" | sed 's|/|__slash__|g; s|:|__colon__|g'
}

image_path() {
    printf '%s/%s' "$image_dir" "$(image_key "$1")"
}

stateful_images_enabled() {
    [[ "${LITMUS_PODMAN_STATEFUL_IMAGES:-0}" == "1" ]]
}

# Stateful container tracking (order 443): mirrors the stateful-image gate.
# When LITMUS_PODMAN_STATEFUL_CONTAINERS=1, detached `run`/`create` record
# name+state+id under $container_dir (file per container: line 1 = state,
# line 2 = id), `stop` marks exited, `rm` untracks, and `ps` replays the
# tracked set in the exact `--format json` shape
# PodmanClient::list_containers parses ([{"Names":[...],"State":"..."}]).
# Foreground one-shots (--rm without --detach) are NOT tracked — they finish
# and self-remove before anything could list them.
# Deliberately permissive: a `run` against an existing name never errors
# ("name already in use"); it re-records with a FRESH id, so a launch path
# that wrongly re-runs a live shared container is observable as an id change
# (the order-443 bounce fixtures assert exactly that).
stateful_containers_enabled() {
    [[ "${LITMUS_PODMAN_STATEFUL_CONTAINERS:-0}" == "1" ]]
}

container_path() {
    printf '%s/%s' "$container_dir" "$1"
}

record_container() {
    # $1 = name, $2 = state
    printf '%s\nmock-id-%s-%s\n' "$2" "$$" "$RANDOM$RANDOM" >"$(container_path "$1")"
}

# ── refusal (order 797-p2xa) ────────────────────────────────────────────────
# ONE refusal, FOUR call sites. The top-level `*)` arm landed in 97cb255a9 and
# closed the outer hole. This function exists because the SAME fail-open tail
# stayed reachable from three more places that arm cannot see, each of them the
# identical defect one level down — an inner `case` that matches nothing,
# leaves its arm with no output, and lands on the file's trailing `exit 0`:
#
#   * `image <anything but exists|inspect|prune>`  (e.g. `podman image ls`)
#   * `secret <anything but create|rm|inspect|ls>`
#   * `image inspect <img>` with no --format
#
# All three answered SUCCESS with EMPTY output, which is the whole class this
# packet exists to close, not a smaller cousin of it.
#
# GRAMMAR — line 1 is the stable, typed, assertable part:
#   [podman-mock] REFUSED: unrecognized <kind>: <subject>
# <kind> is one of: subcommand | image subcommand | secret subcommand |
# image inspect form. (The landed arm wrote the same line without the colon;
# unifying it is what lets a caller assert on <kind> instead of on prose.)
#
# EXIT 97, matching the landed arm rather than inventing a second code:
# distinctive, greppable, and not confusable with a real podman status.
mock_refuse() {
    # mock_refuse <kind> <subject>
    printf '[podman-mock] REFUSED: unrecognized %s: %s\n' "$1" "${2:-<empty>}" >&2
    printf '[podman-mock] full argv: podman' >&2
    # bash 3.2 + `set -u`: an empty array is an unbound variable under "$@"
    # expansion, and `podman` with no arguments at all is one of the shapes
    # that must refuse rather than crash. The +alternate form is the 3.2-safe
    # way to expand a possibly-empty array.
    for _mr_arg in ${PODMAN_MOCK_ARGV[@]+"${PODMAN_MOCK_ARGV[@]}"}; do
        printf ' %s' "$_mr_arg" >&2
    done
    printf '\n' >&2
    printf '[podman-mock] This mock fails CLOSED. Add an explicit arm for this\n' >&2
    printf '[podman-mock] invocation (or to the deliberate no-op arm if doing\n' >&2
    printf '[podman-mock] nothing is genuinely correct) rather than restoring a\n' >&2
    printf '[podman-mock] permissive tail.\n' >&2
    exit 97
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
                # No --format anywhere in argv. This used to leave the arm
                # with NO output and land on the trailing `exit 0`: a caller
                # asking for an image's inspect payload got an empty string
                # and a success. The mock has no bare-form payload to replay,
                # so it says so instead of pretending.
                #
                # (The `if [[ "${3:-}" == "--format" ]]` that used to sit here
                # was dead: the loop above already matches --format in any
                # position, including position 3.)
                mock_refuse "image inspect form" "no --format in argv"
                ;;
            prune)
                exit 0
                ;;
            *)
                mock_refuse "image subcommand" "${2:-}"
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
        if stateful_containers_enabled; then
            wants_running_state=0
            for arg in "$@"; do
                if [[ "$arg" == "{{.State.Running}}" ]]; then
                    wants_running_state=1
                    break
                fi
            done
            if [[ "$wants_running_state" == 1 ]]; then
                # `inspect --format {{.State.Running}} <name>` is the
                # container_running probe the launch-path reuse guards branch
                # on — answer it from tracked state.
                inspect_name="${@: -1}"
                if [[ ! -f "$(container_path "$inspect_name")" ]]; then
                    exit 125
                fi
                if [[ "$(sed -n '1p' "$(container_path "$inspect_name")")" == "running" ]]; then
                    printf 'true\n'
                else
                    printf 'false\n'
                fi
                exit 0
            fi
            # Order 666-qbjd: `inspect <name> --format json` on a TRACKED
            # container replays a REAL inspect array (State.Status,
            # Config.Hostname, network aliases) so inspect_container's serde
            # parse round-trips and the upgrade-skew fixtures can seed
            # old-generation mirrors. Untracked names keep the byte-identical
            # Secrets fallback below — the router/other callers that .ok() the
            # parse failure see exactly what they saw before.
            wants_json=0
            previous=""
            for arg in "$@"; do
                if [[ "$previous" == "--format" && "$arg" == "json" ]]; then
                    wants_json=1
                fi
                previous="$arg"
            done
            inspect_name="${2:-}"
            if [[ "$wants_json" == 1 && -n "$inspect_name" && -f "$(container_path "$inspect_name")" ]]; then
                tracked_file="$(container_path "$inspect_name")"
                state_line="$(sed -n '1p' "$tracked_file")"
                hostname_line="$(grep '^hostname=' "$tracked_file" | head -1 | cut -d= -f2- || true)"
                aliases_json=""
                while IFS= read -r alias_line; do
                    alias_line="${alias_line#alias=}"
                    [[ -n "$alias_line" ]] || continue
                    if [[ -n "$aliases_json" ]]; then
                        aliases_json="${aliases_json},\"${alias_line}\""
                    else
                        aliases_json="\"${alias_line}\""
                    fi
                done < <(grep '^alias=' "$tracked_file" || true)
                printf '[{"State":{"Status":"%s"},"ImageName":"mock-image","Config":{"Hostname":"%s"},"NetworkSettings":{"Networks":{"tillandsias-enclave":{"Aliases":[%s]}}}}]\n' \
                    "$state_line" "$hostname_line" "$aliases_json"
                exit 0
            fi
        fi
        printf '{"Secrets":["vault-token","tillandsias-ca-cert","tillandsias-ca-key"]}\n'
        ;;
    info)
        printf '{}\n'
        ;;
    run|create)
        if stateful_containers_enabled; then
            container_name=""
            detached=0
            hostname_value=""
            alias_values=""
            previous=""
            for arg in "$@"; do
                if [[ "$previous" == "--name" ]]; then
                    container_name="$arg"
                fi
                if [[ "$arg" == --name=* ]]; then
                    container_name="${arg#--name=}"
                fi
                # Order 666-qbjd: track the DNS identity flags so the inspect
                # arm can replay Config.Hostname + network aliases.
                if [[ "$previous" == "--hostname" ]]; then
                    hostname_value="$arg"
                fi
                if [[ "$arg" == --hostname=* ]]; then
                    hostname_value="${arg#--hostname=}"
                fi
                if [[ "$previous" == "--network-alias" ]]; then
                    alias_values="${alias_values}${arg}"$'\n'
                fi
                if [[ "$arg" == --network-alias=* ]]; then
                    alias_values="${alias_values}${arg#--network-alias=}"$'\n'
                fi
                if [[ "$arg" == "--detach" || "$arg" == "-d" ]]; then
                    detached=1
                fi
                previous="$arg"
            done
            if [[ -n "$container_name" ]]; then
                if [[ "$subcommand" == "create" ]]; then
                    record_container "$container_name" "created"
                elif [[ "$detached" == 1 ]]; then
                    record_container "$container_name" "running"
                fi
                # Foreground runs stay untracked (see gate comment above).
                if [[ "$subcommand" == "create" || "$detached" == 1 ]]; then
                    # DNS identity rides on lines 3+ (line 1 = state, line 2 =
                    # id, which every existing sed -n '1p'/'2p' reader keeps).
                    {
                        printf 'hostname=%s\n' "$hostname_value"
                        while IFS= read -r alias_line; do
                            [[ -n "$alias_line" ]] || continue
                            printf 'alias=%s\n' "$alias_line"
                        done <<<"$alias_values"
                    } >>"$(container_path "$container_name")"
                    sed -n '2p' "$(container_path "$container_name")"
                    exit 0
                fi
            fi
        fi
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
            *)
                mock_refuse "secret subcommand" "${2:-}"
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
    version|--version|-v)
        # BOTH the subcommand and the FLAG forms. `podman --version` is the
        # probe require_podman uses, and it is not a global flag, so the skip
        # loop above leaves it as the subcommand. Before 797-p2xa's fail-closed
        # default it matched no arm and fell through to the bare `exit 0`:
        # success with NO OUTPUT, so every caller parsing a version string got
        # an empty one and carried on. Found by the default arm firing during
        # scripts/build-image.sh, which is the first thing it caught.
        printf 'podman version 5.0.0-mock\n'
        ;;
    ps)
        # Replay tracked containers for command-shape tests. The JSON branch
        # matches what PodmanClient::list_containers parses; the plain branch
        # emits one name per line like the default `podman ps` consumers
        # expect. `--filter name=^<prefix>` narrows by name prefix (the one
        # filter shape the Rust client issues).
        if stateful_containers_enabled; then
            filter_prefix=""
            format_json=0
            previous=""
            for arg in "$@"; do
                if [[ "$previous" == "--filter" && "$arg" == name=* ]]; then
                    filter_prefix="${arg#name=}"
                    filter_prefix="${filter_prefix#^}"
                fi
                if [[ "$previous" == "--format" && "$arg" == "json" ]]; then
                    format_json=1
                fi
                previous="$arg"
            done
            if [[ "$format_json" == 1 ]]; then
                json="["
                first=1
                for tracked in "$container_dir"/*; do
                    [[ -e "$tracked" ]] || continue
                    name="$(basename "$tracked")"
                    if [[ -n "$filter_prefix" && "$name" != "$filter_prefix"* ]]; then
                        continue
                    fi
                    state="$(sed -n '1p' "$tracked")"
                    if [[ "$first" == 1 ]]; then
                        first=0
                    else
                        json+=","
                    fi
                    json+="{\"Names\":[\"$name\"],\"State\":\"$state\"}"
                done
                json+="]"
                printf '%s\n' "$json"
            else
                for tracked in "$container_dir"/*; do
                    [[ -e "$tracked" ]] || continue
                    name="$(basename "$tracked")"
                    if [[ -n "$filter_prefix" && "$name" != "$filter_prefix"* ]]; then
                        continue
                    fi
                    printf '%s\n' "$name"
                done
            fi
        fi
        exit 0
        ;;
    stop)
        if stateful_containers_enabled; then
            for arg in "$@"; do
                [[ "$arg" == "stop" || "$arg" == -* ]] && continue
                # `stop -t <secs> <name>`: skip the timeout value too.
                [[ "$arg" =~ ^[0-9]+$ ]] && continue
                if [[ -f "$(container_path "$arg")" ]]; then
                    tracked_id="$(sed -n '2p' "$(container_path "$arg")")"
                    printf 'exited\n%s\n' "$tracked_id" >"$(container_path "$arg")"
                fi
            done
        fi
        exit 0
        ;;
    rm)
        if stateful_containers_enabled; then
            for arg in "$@"; do
                [[ "$arg" == "rm" || "$arg" == -* ]] && continue
                rm -f "$(container_path "$arg")"
            done
        fi
        exit 0
        ;;
    network|compose|system)
        # DELIBERATE no-ops. The product issues these and no test asserts on
        # them, so answering 0 is correct here — but it has to be SAID, because
        # the whole point of the default arm below is that "handled
        # deliberately" and "not handled at all" stop being the same answer.
        exit 0
        ;;
    *)
        # FAIL CLOSED (order 797-p2xa). This file used to end in a bare
        # `exit 0`, so any invocation the mock did not understand was answered
        # with success and no output, and every test built on it could pass
        # while exercising nothing.
        #
        # What that looked like downstream, measured on macuahuitl: `atomic
        # rename failed: No such file or directory` (the temp checkout the mock
        # never created) and `invalid gh JSON: EOF while parsing a value` (the
        # array it never printed). Neither message contains the words podman,
        # mock, or unrecognized — the failure surfaced as far from its cause as
        # it is possible to get.
        #
        # 66a37e92c closed the specific hole (global flags were not skipped, so
        # `--remote` became the subcommand). It could not close the CLASS: any
        # future flag, any subcommand the product starts using, any typo in a
        # litmus step landed in the same silent success. A mock that cannot
        # report its own confusion is not a test double, it is a source of
        # false green.
        #
        # 97 rather than 1: distinctive enough to grep for, and it cannot be
        # confused with a real podman exit status. The body moved into
        # mock_refuse() above so the three NESTED fall-throughs this arm could
        # not see refuse in the same words and with the same status.
        mock_refuse "subcommand" "$subcommand"
        ;;
esac

# Arms that print and fall through land here. This is SAFE now in a way it was
# not before: the `*)` arm above refuses anything unrecognized, so reaching this
# line means a deliberate arm ran to completion. Previously this same line was
# the fall-open default for every unmatched invocation — and, until the nested
# refusals above landed, for `image <unknown>`, `secret <unknown>` and bare
# `image inspect` as well, which reached it by leaving their arm rather than by
# missing the outer case.
exit 0
