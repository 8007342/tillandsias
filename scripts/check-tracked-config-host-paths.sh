#!/usr/bin/env bash
# @trace spec:ci-release, spec:forge-environment-discoverability
#
# check-tracked-config-host-paths.sh — no TRACKED agent config may hard-code a
# path that exists on exactly one machine (order 789-nc2s).
#
# WHY. `.claude/settings.local.json` is tracked despite the `.local`
# convention, and it exported
# FORGE_SPEC_INDEX_DIR=/mnt/c/Users/<someone>/…/spec-index — a WSL path. Every
# other host in the fleet inherited it. Since forge-plan.sh resolves the spec
# index directory from that variable, every non-Windows host resolved the spec
# RAG index to a directory that cannot exist, so `spec_answer` would have
# refused forever no matter what index was built. The refusal even named the
# (wrong) directory, so it looked like an honest missing-index report rather
# than a config leak. Found on yoga 2026-08-17 only because a new capability
# field reported `absent` for an index that demonstrably existed.
#
# SCOPE IS DELIBERATELY NARROW: tracked AGENT CONFIG only. Prose must stay free
# to quote these paths — cheatsheets/runtime/podman-in-wsl2.md and this
# repository's own plan packets cite `/mnt/c` as evidence, and a guard that
# flagged documentation for describing the defect would be its own defect.
#
# Output grammar (exactly one line):
#   ^(ok:tracked-config-host-paths:[0-9]+ scanned|violation:tracked-config-host-path:[0-9]+)$
#
# Usage:
#   scripts/check-tracked-config-host-paths.sh
#   scripts/check-tracked-config-host-paths.sh --selftest
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The shapes that name ONE machine:
#   /mnt/<drive>/    a WSL drive mount
#   /c/Users/…       a Git-Bash drive mount
#   /Users/<name>/   a macOS home
#   C:\ or C:/       a Windows absolute path — a SINGLE letter at a boundary,
#                    which is what keeps `http://` from matching (writing this
#                    as [A-Za-z]:[\\/] flags every URL in the file, as this
#                    guard's own first run demonstrated).
# Deliberately NOT /home/<name>/: it is the normal shape on every Linux host
# and flagging it would drown the signal.
HOST_PATH_RE='(/mnt/[a-z]/|/[a-z]/Users/|/Users/[A-Za-z0-9._-]+/|(^|[^A-Za-z0-9])[A-Za-z]:[\\/])'

_config_files() {
    git -C "$1" ls-files 2>/dev/null |
        grep -E '^\.(claude|opencode|codex|gemini|vscode)/.*\.(json|toml|ya?ml)$' || true
}

# Only the ENV block is a REFUSAL. A leaked env value changes behaviour on
# every host that reads the file — that is the 789-nc2s defect. A host-specific
# path inside a `permissions` allowlist is inert elsewhere (a pattern that
# never matches costs nothing), so it is reported as a NOTE: still fleet
# pollution worth cleaning, but not something this guard should block a push
# over, and not something one host should silently delete from another host's
# allowances.
_env_block() {
    awk '/"env"[[:space:]]*:[[:space:]]*\{/{inenv=1} inenv{print} inenv&&/^[[:space:]]*\},?[[:space:]]*$/{inenv=0}' "$1"
}

_scan() {
    local root="$1" scanned=0 offenders=0 notes=0 f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$root/$f" ] || continue
        scanned=$((scanned + 1))
        if _env_block "$root/$f" | grep -Eq "$HOST_PATH_RE" 2>/dev/null; then
            offenders=$((offenders + 1))
            echo "  $f (env block):" >&2
            _env_block "$root/$f" | grep -E "$HOST_PATH_RE" | head -5 | sed 's/^/    /' >&2
        elif grep -Eq "$HOST_PATH_RE" "$root/$f" 2>/dev/null; then
            notes=$((notes + 1))
            echo "note: $f carries host-specific path(s) outside its env block (inert on other hosts, still fleet pollution):" >&2
            grep -nE "$HOST_PATH_RE" "$root/$f" | head -3 | sed 's/^/    /' >&2
        fi
    done < <(_config_files "$root")

    if [ "$offenders" -gt 0 ]; then
        echo "violation:tracked-config-host-path:$offenders"
        {
            echo "A tracked agent config hard-codes a path that exists on one machine."
            echo "Every host that opens this checkout inherits it — see order 789-nc2s,"
            echo "where a /mnt/c path silently disabled the spec expert fleet-wide."
            echo "Fix: remove the key (let the code's default apply), or move it to an"
            echo "untracked per-machine override."
        } >&2
        return 1
    fi
    echo "ok:tracked-config-host-paths:$scanned scanned"
    return 0
}

if [ "${1:-}" = "--selftest" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    fail=0
    ( cd "$tmp" && git init -q . && mkdir -p .claude cheatsheets ) || exit 1

    # Clean config passes.
    printf '{"env":{"E":"http://127.0.0.1:11434"}}\n' > "$tmp/.claude/settings.local.json"
    # Prose quoting the bad shape must NOT be scanned — this is the exclusion
    # that keeps the guard from flagging its own documentation.
    printf 'On WSL the drive is at /mnt/c/Users/someone/repo.\n' > "$tmp/cheatsheets/wsl.md"
    ( cd "$tmp" && git add -A && git -c user.email=t@t -c user.name=t commit -qm x ) || exit 1
    out="$(_scan "$tmp" 2>/dev/null)"
    case "$out" in
        ok:tracked-config-host-paths:*) : ;;
        *) echo "SELFTEST-FAIL: clean config rejected ($out)"; fail=1 ;;
    esac

    # NEGATIVE CONTROL: the same bad path INSIDE tracked config must refuse.
    printf '{"env":{"D":"/mnt/c/Users/someone/repo/target"}}\n' > "$tmp/.claude/settings.local.json"
    ( cd "$tmp" && git add -A && git -c user.email=t@t -c user.name=t commit -qm y ) || exit 1
    out="$(_scan "$tmp" 2>/dev/null)"
    case "$out" in
        violation:tracked-config-host-path:*) : ;;
        *) echo "SELFTEST-FAIL: a /mnt/c path in tracked config was accepted ($out)"; fail=1 ;;
    esac

    # A macOS home and a Windows drive letter are the same class.
    printf '{"env":{"D":"/Users/someone/repo"}}\n' > "$tmp/.claude/settings.local.json"
    ( cd "$tmp" && git add -A && git -c user.email=t@t -c user.name=t commit -qm z ) || exit 1
    out="$(_scan "$tmp" 2>/dev/null)"
    case "$out" in
        violation:*) : ;;
        *) echo "SELFTEST-FAIL: a /Users/ path was accepted ($out)"; fail=1 ;;
    esac

    [ "$fail" -eq 0 ] || { echo "selftest:tracked-config-host-paths:FAIL"; exit 1; }
    echo "selftest:tracked-config-host-paths:4 cases PASS"
    exit 0
fi

_scan "$ROOT"
