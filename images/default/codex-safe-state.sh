#!/usr/bin/env bash
# @trace spec:default-image
#
# Persist only explicitly reviewed Codex state classes. CODEX_HOME remains an
# ephemeral per-worker directory (order 428), because the official Codex
# contract places config, auth.json, logs, sessions, caches, and package
# metadata beneath that broad root. Persisting the whole directory would also
# persist plaintext provider authentication.
#
# This is a provider-auth boundary, not a general secret scrubber: cache,
# sessions, and SQLite can contain sensitive project or conversation data. They
# live beneath the project cache and receive the same confidentiality treatment
# as other persistent project state; auth.json and config.toml never do.
#
# The supported CODEX_SQLITE_HOME split is direct-to-volume. The whitelisted
# cache/session directories are symlinked directly to the project cache so they
# also survive a hard container kill. A small named file whitelist is restored
# at setup and checkpointed on normal codex-oauth-session exit. A hard kill can
# lose only mutations to those copied files since the last normal exit; it
# cannot lose the direct directories or SQLite state.

codex_safe_state_worker_key() {
    local raw="${TILLANDSIAS_CODEX_STATE_WORKER:-}" codex_home base digest
    codex_home="${CODEX_HOME:-$HOME/.codex}"

    # The host launcher supplies the exact dispatcher identity separately from
    # its lossy, Podman-safe CODEX_HOME suffix. The suffix remains a fallback
    # for older launchers and direct fixture use.
    if [ -z "$raw" ]; then
        base="${codex_home##*/}"
        case "$base" in
            .codex-*) raw="${base#.codex-}" ;;
        esac
    fi

    if [ -z "$raw" ]; then
        printf '%s\n' default
        return 0
    fi

    # Digest the exact raw identity instead of embedding a readable sanitized
    # prefix: host-normalized collisions, newlines, and differences beyond the
    # CODEX_HOME suffix length cap must all remain distinct single components.
    digest="$(printf '%s' "$raw" | sha256sum)" || return 1
    digest="${digest%% *}"
    [ "${#digest}" -eq 64 ] || return 1
    case "$digest" in *[!0-9a-f]*) return 1 ;; esac
    printf 'worker-%s\n' "$digest"
}

codex_safe_state_root() {
    local cache_root state_base root worker home_root
    cache_root="$(realpath -m "${PROJECT_CACHE:-$HOME/.cache/tillandsias-project}")" \
        || return 1
    state_base="$(realpath -m "$cache_root/codex-state")" || return 1
    worker="$(codex_safe_state_worker_key)" || return 1
    root="$(realpath -m "$state_base/$worker")" || return 1
    home_root="$(realpath -m "$HOME")" || return 1

    # Treat every computed path as hostile input. A non-default worker key is a
    # fixed `worker-<sha256>` component, and an existing symlink cannot redirect
    # either the state base or worker root outside the project cache.
    [ "$state_base" = "$cache_root/codex-state" ] || return 1
    [ "$root" = "$state_base/$worker" ] || return 1
    case "$root" in
        "" | / | "$home_root" | "$cache_root" | "$state_base") return 1 ;;
        "$state_base"/*) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$root"
}

codex_safe_home_path() {
    local codex_raw codex_lexical codex_home home_lexical home_root cache_root codex_base
    codex_raw="${CODEX_HOME:-$HOME/.codex}"
    [ ! -L "$codex_raw" ] || return 1
    codex_lexical="$(realpath -ms "$codex_raw")" || return 1
    codex_home="$(realpath -m "$codex_raw")" || return 1
    home_lexical="$(realpath -ms "$HOME")" || return 1
    home_root="$(realpath -m "$HOME")" || return 1
    cache_root="$(realpath -m "${PROJECT_CACHE:-$HOME/.cache/tillandsias-project}")" \
        || return 1
    [ "$(dirname "$codex_lexical")" = "$home_lexical" ] || return 1
    codex_base="${codex_lexical##*/}"
    [ "$codex_home" = "$home_root/$codex_base" ] || return 1
    case "$codex_base" in
        .codex | .codex-?*) ;;
        *) return 1 ;;
    esac
    [ "$codex_home" != / ] \
        && [ "$codex_home" != "$home_root" ] \
        && [ "$codex_home" != "$cache_root" ] \
        || return 1
    printf '%s\n' "$codex_home"
}

codex_safe_home_is_safe() {
    codex_safe_home_path >/dev/null
}

codex_safe_state_clear_exports() {
    unset CODEX_SQLITE_HOME TILLANDSIAS_CODEX_SAFE_STATE_READY \
        TILLANDSIAS_CODEX_SAFE_STATE_ROOT
}

codex_safe_state_unlink_owned() {
    local codex_home="$1" root="$2" name target persisted status=0
    for name in cache sessions; do
        target="$codex_home/$name"
        persisted="$root/direct/$name"
        if [ -L "$target" ] \
            && [ "$(readlink "$target" 2>/dev/null)" = "$persisted" ]; then
            rm -f -- "$target" 2>/dev/null || status=1
            if [ ! -e "$target" ] && [ ! -L "$target" ]; then
                mkdir -p "$target" 2>/dev/null || status=1
                chmod 700 "$target" 2>/dev/null || status=1
            fi
        fi
    done
    return "$status"
}

codex_safe_state_setup_fail() {
    local codex_home="$1" root="$2"
    if ! codex_safe_state_unlink_owned "$codex_home" "$root"; then
        export TILLANDSIAS_CODEX_SAFE_STATE_PARTIAL_DIRECT=1
    fi
    codex_safe_state_clear_exports
    return 1
}

codex_safe_state_clean_temps() {
    local dir="$1" prefix="$2" candidate
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    for candidate in "$dir/$prefix"*; do
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then
            [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
            rm -f -- "$candidate" || return 1
        fi
    done
}

codex_safe_state_setup() {
    local codex_home root persisted target name source tmp candidate
    codex_safe_state_clear_exports
    unset TILLANDSIAS_CODEX_SAFE_STATE_PARTIAL_DIRECT
    codex_home="$(codex_safe_home_path)" || return 1
    root="$(codex_safe_state_root)" || return 1

    [ ! -L "$root" ] || {
        codex_safe_state_setup_fail "$codex_home" "$root"
        return 1
    }
    for name in direct files sqlite; do
        [ ! -L "$root/$name" ] || {
            codex_safe_state_setup_fail "$codex_home" "$root"
            return 1
        }
    done
    mkdir -p "$codex_home" "$root/direct" "$root/files" "$root/sqlite" \
        || {
            codex_safe_state_setup_fail "$codex_home" "$root"
            return 1
        }
    for name in "$root" "$root/direct" "$root/files" "$root/sqlite"; do
        [ -d "$name" ] && [ ! -L "$name" ] \
            && [ "$(realpath -m "$name")" = "$name" ] \
            || {
                codex_safe_state_setup_fail "$codex_home" "$root"
                return 1
            }
    done
    chmod 700 "$codex_home" "$root" "$root/direct" "$root/files" "$root/sqlite" \
        2>/dev/null || {
        codex_safe_state_setup_fail "$codex_home" "$root"
        return 1
    }

    # Preflight every direct class before creating any link. An ordinary local
    # directory is accepted only while empty; setup runs before Codex starts,
    # so there is no prior ephemeral state to migrate into persistence.
    for name in cache sessions; do
        persisted="$root/direct/$name"
        target="$codex_home/$name"
        [ ! -L "$persisted" ] || {
            codex_safe_state_setup_fail "$codex_home" "$root"
            return 1
        }
        mkdir -p "$persisted" || {
            codex_safe_state_setup_fail "$codex_home" "$root"
            return 1
        }
        [ -d "$persisted" ] && [ ! -L "$persisted" ] \
            && [ "$(realpath -m "$persisted")" = "$persisted" ] \
            && chmod 700 "$persisted" 2>/dev/null || {
            codex_safe_state_setup_fail "$codex_home" "$root"
            return 1
        }

        if [ -L "$target" ]; then
            [ "$(readlink "$target" 2>/dev/null)" = "$persisted" ] || {
                codex_safe_state_setup_fail "$codex_home" "$root"
                return 1
            }
        elif [ -d "$target" ]; then
            [ -z "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] \
                || {
                    codex_safe_state_setup_fail "$codex_home" "$root"
                    return 1
                }
        elif [ -e "$target" ]; then
            codex_safe_state_setup_fail "$codex_home" "$root"
            return 1
        fi
    done

    # Preflight the exact copied-file namespace and its reserved temporary
    # prefixes before restoring anything. A hard kill between install and rename
    # can leave a regular checkpoint temp containing only whitelisted metadata;
    # the next setup/flush removes it. Links and directories are rejected.
    for name in models_cache.json version.json installation_id .sandbox_migration; do
        source="$root/files/$name"
        target="$codex_home/$name"
        if [ -e "$source" ] || [ -L "$source" ]; then
            [ -f "$source" ] && [ ! -L "$source" ] || {
                codex_safe_state_setup_fail "$codex_home" "$root"
                return 1
            }
        fi
        if [ -e "$target" ] || [ -L "$target" ]; then
            [ -f "$target" ] && [ ! -L "$target" ] || {
                codex_safe_state_setup_fail "$codex_home" "$root"
                return 1
            }
        fi
        for candidate in "$root/files/.${name}.checkpoint."* \
            "$codex_home/.${name}.restore."*; do
            if [ -e "$candidate" ] || [ -L "$candidate" ]; then
                [ -f "$candidate" ] && [ ! -L "$candidate" ] || {
                    codex_safe_state_setup_fail "$codex_home" "$root"
                    return 1
                }
            fi
        done
    done
    for name in models_cache.json version.json installation_id .sandbox_migration; do
        codex_safe_state_clean_temps "$root/files" ".${name}.checkpoint." \
            || {
                codex_safe_state_setup_fail "$codex_home" "$root"
                return 1
            }
        codex_safe_state_clean_temps "$codex_home" ".${name}.restore." \
            || {
                codex_safe_state_setup_fail "$codex_home" "$root"
                return 1
            }
    done

    # These exact files are startup/model metadata. Provider auth, config,
    # history, logs, shell snapshots, skills, and unknown future files are
    # excluded.
    for name in models_cache.json version.json installation_id .sandbox_migration; do
        source="$root/files/$name"
        target="$codex_home/$name"
        if [ -f "$source" ] && [ ! -L "$source" ]; then
            tmp="$(mktemp "$codex_home/.${name}.restore.XXXXXX")" || {
                codex_safe_state_setup_fail "$codex_home" "$root"
                return 1
            }
            if ! install -m 0600 "$source" "$tmp" 2>/dev/null \
                || ! mv -fT -- "$tmp" "$target" 2>/dev/null; then
                rm -f -- "$tmp" 2>/dev/null || true
                codex_safe_state_setup_fail "$codex_home" "$root"
                return 1
            fi
        fi
    done

    # Only now replace empty local directories with helper-owned direct links.
    # If an I/O race still causes a failure, rollback removes only exact links
    # owned by this helper and recreates ephemeral directories.
    for name in cache sessions; do
        persisted="$root/direct/$name"
        target="$codex_home/$name"
        if [ -L "$target" ] \
            && [ "$(readlink "$target" 2>/dev/null)" = "$persisted" ]; then
            continue
        fi
        if [ -d "$target" ]; then
            rmdir "$target" || {
                codex_safe_state_setup_fail "$codex_home" "$root"
                return 1
            }
        fi
        ln -s "$persisted" "$target" || {
            codex_safe_state_setup_fail "$codex_home" "$root"
            return 1
        }
    done

    # Publish readiness only after every link and restore completes. The shared
    # OAuth wrapper also serves Claude and Antigravity, so it must never infer a
    # Codex state root merely because this helper exists in the image.
    export CODEX_SQLITE_HOME="$root/sqlite"
    export TILLANDSIAS_CODEX_SAFE_STATE_ROOT="$root"
    export TILLANDSIAS_CODEX_SAFE_STATE_READY=1
    unset TILLANDSIAS_CODEX_SAFE_STATE_DISABLED
}

codex_safe_state_flush() {
    local codex_home root source target tmp name
    [ "${TILLANDSIAS_CODEX_SAFE_STATE_READY:-0}" = 1 ] || return 1
    [ -n "${TILLANDSIAS_CODEX_SAFE_STATE_ROOT:-}" ] || return 1
    codex_home="$(codex_safe_home_path)" || return 1
    [ "$TILLANDSIAS_CODEX_SAFE_STATE_ROOT" = "$(codex_safe_state_root)" ] \
        || return 1
    root="$TILLANDSIAS_CODEX_SAFE_STATE_ROOT"
    [ ! -L "$root" ] && [ ! -L "$root/files" ] || return 1
    mkdir -p "$root/files" || return 1
    [ "$(realpath -m "$root/files")" = "$root/files" ] || return 1
    chmod 700 "$root" "$root/files" 2>/dev/null || return 1

    # Copy only the same explicit non-auth metadata whitelist used by setup.
    # Refuse links/directories and clean regular hard-kill temp artifacts before
    # writing the next randomized checkpoint.
    for name in models_cache.json version.json installation_id .sandbox_migration; do
        source="$codex_home/$name"
        target="$root/files/$name"
        if [ -e "$source" ] || [ -L "$source" ]; then
            [ -f "$source" ] && [ ! -L "$source" ] || return 1
        fi
        if [ -e "$target" ] || [ -L "$target" ]; then
            [ -f "$target" ] && [ ! -L "$target" ] || return 1
        fi
        codex_safe_state_clean_temps "$root/files" ".${name}.checkpoint." \
            || return 1
    done
    for name in models_cache.json version.json installation_id .sandbox_migration; do
        source="$codex_home/$name"
        target="$root/files/$name"
        if [ -f "$source" ] && [ ! -L "$source" ]; then
            tmp="$(mktemp "$root/files/.${name}.checkpoint.XXXXXX")" || return 1
            if ! install -m 0600 "$source" "$tmp" 2>/dev/null \
                || ! mv -fT -- "$tmp" "$target" 2>/dev/null; then
                rm -f -- "$tmp" 2>/dev/null || true
                return 1
            fi
        fi
    done
}
