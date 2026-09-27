#!/usr/bin/env bash
# @trace spec:meta-orchestration, openspec/changes/openspec-cli-version-pin (order 1441-myz3)
#
# openspec-pin.sh — the project's ONE openspec CLI version, and the only
# sanctioned way to move the generated /opsx command/skill sets forward.
#
# WHY. The repo recorded no openspec version. Every forge launch refreshed the
# CLI to @latest into the prefix its own `openspec init` used, so each openspec
# release first appeared as tracked-file dirt at launch, and "updating openspec"
# meant committing that dirt (order 540, reversed 2026-09-27). Trunk ended up
# holding three generator versions at once (.claude 1.13.1, .opencode 1.13.2,
# .codex/.github 1.3.1). Now openspec/cli-version is the record: forges install
# exactly it (ensure_openspec_pinned, images/default/lib-common.sh), and the
# coordinator moves it deliberately with `bump`, which regenerates every
# configured tool in ONE commit.
#
# Usage:
#   scripts/openspec-pin.sh pin              print the pinned version
#   scripts/openspec-pin.sh check            is npm's latest newer than the pin?
#   scripts/openspec-pin.sh drift            does every tracked generatedBy match?
#   scripts/openspec-pin.sh install [V]      install V (default: pin) into a
#                                            version-keyed cache; print the binary
#   scripts/openspec-pin.sh bump [--to V]    install V (default: npm latest), run
#                                            `openspec update --force` with an
#                                            ISOLATED openspec config, write the
#                                            pin, verify; never commits
#
# Verdicts (one line on stdout; detail on stderr):
#   pin:     <version>                                   0
#            absent:openspec-pin                         4
#   check:   ok:openspec-pin-current:<pin>               0
#            due:openspec-bump:<pin>-><latest>           5
#            unknown:openspec-latest:<reason>            2
#   drift:   ok:openspec-generated-matches-pin:<pin>:<n> 0
#            drift:openspec-generated:<pin>:<n>          3
#   install: <path to openspec>                          0
#            refused:openspec-install:<V>:<reason>       1
#   bump:    bumped:openspec:<old>-><new>:<n>-paths      0   commit it as ONE change
#            review:openspec-bump:<old>-><new>:<reason>  6   tree left for review
#            refused:openspec-bump:<reason>              1   nothing changed
#   absent:openspec-pin (4) from check/drift/bump-without---to when no pin exists.
#
# The isolated config matters: `openspec update` reads a per-machine global
# profile ($XDG_CONFIG_HOME/openspec/config.json). From an empty config it
# derives the profile from the workflows already committed ("Migrated: custom
# profile with N workflows"), so the output depends on the repo alone. Changing
# the workflow set is a separate, deliberate decision, not a side effect of
# whoever runs the bump.

set -uo pipefail

PKG="@fission-ai/openspec"
NPM="${OPENSPEC_PIN_NPM:-npm}"

if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "unknown:openspec-pin:not-a-git-repo"
    exit 2
fi
PIN_FILE="$ROOT/openspec/cli-version"
CACHE_ROOT="${OPENSPEC_PIN_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias/openspec-pinned}"

# Tracked generated skill files carry `generatedBy: "<version>"`; command and
# prompt files do not, so the skills are the version witnesses. Every harness
# locus the CLI writes to, including .agents/ (codex since 1.13.x).
GENERATED_SKILLS=(
    '.agents/skills/openspec-*/SKILL.md'
    '.claude/skills/openspec-*/SKILL.md'
    '.codex/skills/openspec-*/SKILL.md'
    '.gemini/skills/openspec-*/SKILL.md'
    '.github/skills/openspec-*/SKILL.md'
    '.opencode/skills/openspec-*/SKILL.md'
)
# Paths a bump may touch. Anything else changing is refused, not committed.
BUMP_SURFACE_RE='^(\.agents|\.claude|\.codex|\.gemini|\.github|\.opencode)/|^openspec/cli-version$'

is_version() {
    case "$1" in
        ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
    esac
    return 0
}

# version_lt A B: true when A sorts strictly before B (numeric per field).
version_lt() {
    [ "$1" != "$2" ] || return 1
    local first
    first="$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)"
    [ "$first" = "$1" ]
}

read_pin() {
    PIN=""
    [ -r "$PIN_FILE" ] || return 1
    PIN="$(tr -d ' \t\r\n' <"$PIN_FILE")"
    is_version "$PIN"
}

latest_version() {
    local v
    v="$("$NPM" view "$PKG" version 2>/dev/null | tail -n 1 | tr -d ' \r')" || return 1
    is_version "$v" || return 1
    printf '%s\n' "$v"
}

cmd_pin() {
    if read_pin; then
        echo "$PIN"
        return 0
    fi
    echo "absent:openspec-pin"
    return 4
}

cmd_check() {
    local latest
    read_pin || { echo "absent:openspec-pin"; return 4; }
    if ! latest="$(latest_version)"; then
        echo "unknown:openspec-latest:registry-unreachable"
        return 2
    fi
    if version_lt "$PIN" "$latest"; then
        echo "due:openspec-bump:$PIN->$latest"
        return 5
    fi
    echo "ok:openspec-pin-current:$PIN"
    return 0
}

cmd_drift() {
    local n=0 bad=0 f v
    read_pin || { echo "absent:openspec-pin"; return 4; }
    while IFS= read -r -d '' f; do
        n=$((n + 1))
        v="$(sed -n 's/^[[:space:]]*generatedBy:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}[[:space:]]*$/\1/p' "$ROOT/$f" | head -n 1)"
        if [ "$v" != "$PIN" ]; then
            bad=$((bad + 1))
            echo "  $f generatedBy=${v:-none}" >&2
        fi
    done < <(cd "$ROOT" && git ls-files -z -- "${GENERATED_SKILLS[@]}")
    if [ "$bad" -gt 0 ]; then
        echo "drift:openspec-generated:$PIN:$bad"
        return 3
    fi
    echo "ok:openspec-generated-matches-pin:$PIN:$n"
    return 0
}

# install V: a version-keyed prefix, written atomically, reused when present.
install_version() {
    local v="$1" dir tmp have
    dir="$CACHE_ROOT/$v"
    if [ -x "$dir/node_modules/.bin/openspec" ]; then
        printf '%s\n' "$dir/node_modules/.bin/openspec"
        return 0
    fi
    mkdir -p "$CACHE_ROOT" || { echo "refused:openspec-install:$v:cache-unwritable"; return 1; }
    tmp="$dir.tmp.$$"
    rm -rf "$tmp"
    if ! "$NPM" install --prefix "$tmp" --no-audit --no-fund --silent "$PKG@$v" >/dev/null 2>&1; then
        rm -rf "$tmp"
        echo "refused:openspec-install:$v:npm-install-failed"
        return 1
    fi
    have="$("$tmp/node_modules/.bin/openspec" --version 2>/dev/null | tail -n 1)"
    if [ "$have" != "$v" ]; then
        rm -rf "$tmp"
        echo "refused:openspec-install:$v:installed-reports-${have:-nothing}"
        return 1
    fi
    rm -rf "$dir"
    mv "$tmp" "$dir"
    printf '%s\n' "$dir/node_modules/.bin/openspec"
}

cmd_install() {
    local v="${1:-}"
    if [ -z "$v" ]; then
        read_pin || { echo "absent:openspec-pin"; return 4; }
        v="$PIN"
    fi
    is_version "$v" || { echo "refused:openspec-install:$v:not-a-version"; return 1; }
    install_version "$v"
}

cmd_bump() {
    local to="" old bin cfg log out changed stray orphans
    while [ $# -gt 0 ]; do
        case "$1" in
            --to) to="${2:-}"; shift 2 ;;
            *) echo "refused:openspec-bump:unknown-argument:$1"; return 1 ;;
        esac
    done
    if [ -n "$(cd "$ROOT" && git status --porcelain --untracked-files=all)" ]; then
        echo "refused:openspec-bump:dirty-tree"
        return 1
    fi
    if read_pin; then old="$PIN"; else old="none"; fi
    if [ -z "$to" ]; then
        to="$(latest_version)" || { echo "refused:openspec-bump:registry-unreachable"; return 1; }
    fi
    is_version "$to" || { echo "refused:openspec-bump:not-a-version:$to"; return 1; }

    out="$(install_version "$to")" || { echo "refused:openspec-bump:${out#refused:}"; return 1; }
    bin="$out"

    cfg="$(mktemp -d "${TMPDIR:-/tmp}/openspec-pin-config.XXXXXX")"
    log="$cfg/update.log"
    (
        cd "$ROOT" &&
        env XDG_CONFIG_HOME="$cfg" OPENSPEC_TELEMETRY=0 DO_NOT_TRACK=1 \
            OPENSPEC_NO_UPDATE_CHECK=1 OPENSPEC_NO_AUTO_CONFIG=1 NO_COLOR=1 \
            "$bin" update --force </dev/null
    ) >"$log" 2>&1
    local rc=$?
    printf '%s\n' "$to" >"$PIN_FILE"

    if [ "$rc" -ne 0 ]; then
        sed 's/^/  update: /' "$log" >&2
        rm -rf "$cfg"
        echo "review:openspec-bump:$old->$to:update-exit-$rc"
        return 6
    fi

    changed="$(cd "$ROOT" && git status --porcelain --untracked-files=all | cut -c4-)"
    stray="$(printf '%s\n' "$changed" | grep -Ev "$BUMP_SURFACE_RE" | grep . || true)"
    if [ -n "$stray" ]; then
        printf '  outside the generated surface: %s\n' $stray >&2
        rm -rf "$cfg"
        echo "review:openspec-bump:$old->$to:paths-outside-generated-surface"
        return 6
    fi
    # The CLI keeps a superseded copy instead of overwriting it and says so:
    # "Left 11 files in .codex/ that differ from the copy in .agents/".
    orphans="$(sed -n 's/.*Left [0-9][0-9]* files in \([^ ]*\)\/ that differ from the copy in \([^ ]*\)\/.*/\1 (superseded by \2)/p' "$log")"
    rm -rf "$cfg"

    if ! cmd_drift >/dev/null 2>&1 || [ -n "$orphans" ]; then
        [ -n "$orphans" ] && printf '  superseded copy left by the CLI: %s\n' "$orphans" >&2
        cmd_drift >/dev/null
        echo "review:openspec-bump:$old->$to:drift-or-superseded-copies"
        return 6
    fi
    echo "bumped:openspec:$old->$to:$(printf '%s\n' "$changed" | grep -c .)-paths"
    return 0
}

case "${1:-}" in
    pin) shift; cmd_pin "$@" ;;
    check) shift; cmd_check "$@" ;;
    drift) shift; cmd_drift "$@" ;;
    install) shift; cmd_install "$@" ;;
    bump) shift; cmd_bump "$@" ;;
    *)
        echo "usage: $0 pin|check|drift|install [V]|bump [--to V]" >&2
        exit 2 ;;
esac
