#!/usr/bin/env bash
# @trace order:1637-cnxq
#
# check-scratch-location-added.sh — refuse a NEWLY ADDED shell line that makes
# scratch OUTSIDE the checkout, unless the line names a recorded exception.
#
# THE RULE (operator direction 2026-10-12, order 1637-cnxq; methodology
# multi-host-development.yaml -> single_checkout_branching): in the DEVELOPMENT
# runtime every disposable thing a script makes (temp trees, logs, private
# podman stores, any worktree) lives under <checkout>/scratch/, the one ignored
# dir, reached through scripts/scratch-dir.sh. A recursive rm outside the
# workspace asks the operator for consent (1443-we89), and a bypass-mode session
# waiting on that prompt halts the fleet. User runtime (inside a forge) is
# exempt by design and says so with the `user-runtime` key.
#
# WHAT IS A SITE, on an ADDED, non-comment line of scripts/**/*.sh:
#   mktemp     — `mktemp` in command position (start of line, or after `$(`,
#                `(`, a backtick, `;`, `&&`, `||`, `|`) whose arguments do not
#                route through scratch (`scratch-dir.sh`, `/scratch/`,
#                `$SCRATCH`, `TILLANDSIAS_SCRATCH`).
#   tmp        — a literal `/tmp/`, `/var/tmp/`, `$TMPDIR` or `${TMPDIR` on a
#                line that does not also route through scratch.
#   worktree   — `git worktree add <target>` with a target outside scratch.
#   parent     — a write that climbs out of the checkout: mkdir, mktemp, cp,
#                mv, tee, rsync, git clone or a `>` redirect naming `../`.
#                `cd "$(dirname "$0")/.."` is a resolution, not a write, and
#                is not a site.
# A line carrying `# scratch-exception:<key>` is exempt when <key> is listed
# in scripts/portability/scratch-exceptions.txt, and a VIOLATION when it is
# not: an exception is always a recorded one.
#
# DIFF-SCOPED BY CONSTRUCTION. 728 of the tree's 731 mktemp sites make
# scratch outside the checkout today (measured 2026-10-12); the corpus is
# migrated by the rows that own it, not by this guard. The population is the
# change, INCLUDING untracked files (1391-8ikx: `git diff --name-only` never
# lists a brand-new script). This guard and its fixture are excluded by EXACT
# path, named below, because both quote every token they refuse (a pattern
# over a set containing itself reports itself).
#
# Verdicts (stdout; why/remedy on stderr):
#   ok:scratch-location-added:files=<n>:sites=<m>:exempt=<k>    exit 0
#   violation:scratch-location-added:<count>                    exit 1
#     preceded by one violation:scratch-location-added:<rule>:<path>:<line>
#     per site, rule in {mktemp,tmp,worktree,parent,unrecorded-exception}
#   refused:scratch-location-added:no-base:<ref>                exit 2
#   refused:scratch-location-added:not-bash                     exit 2
#
# Env: TILLANDSIAS_SCRATCH_LOCATION_BASE, else TILLANDSIAS_GATE_DIFF_BASE,
# else origin/linux-next; TILLANDSIAS_SCRATCH_EXCEPTIONS names the key file.
set -u

[ -n "${BASH_VERSION:-}" ] || { echo "refused:scratch-location-added:not-bash"; exit 2; }

_afford() {  # <why> <remedy>
    echo "  why: $1" >&2
    echo "  remedy: $2" >&2
}

base_ref="${TILLANDSIAS_SCRATCH_LOCATION_BASE:-${TILLANDSIAS_GATE_DIFF_BASE:-origin/linux-next}}"
EXC_FILE="${TILLANDSIAS_SCRATCH_EXCEPTIONS:-scripts/portability/scratch-exceptions.txt}"
SELF="scripts/check-scratch-location-added.sh"
SELF_FIXTURE="scripts/test-check-scratch-location-added.sh"
REMEDY='route the site through the checkout: tmp="$(mktemp -d "$(scripts/scratch-dir.sh fixtures)/<name>.XXXXXX")" — or, for a measured reason, append `# scratch-exception:<key>` with a key from scripts/portability/scratch-exceptions.txt'

if ! git rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null 2>&1; then
    echo "refused:scratch-location-added:no-base:$base_ref"
    _afford "the diff base does not resolve, so the set of added lines is unknown and nothing was checked" \
        "git fetch origin, or point TILLANDSIAS_SCRATCH_LOCATION_BASE at a commit"
    exit 2
fi

# Is <key> recorded? The key file is data: a line `<key> <why...>`.
_recorded() {
    [ -r "$EXC_FILE" ] || return 1
    local k
    while IFS= read -r k || [ -n "$k" ]; do
        case "$k" in ''|'#'*) continue ;; esac
        [ "${k%% *}" = "$1" ] && return 0
    done < "$EXC_FILE"
    return 1
}

# Added lines of one file as `<new-line-number>:<text>`. A tracked file is
# diffed against the base with no context, so every `+` line is an addition
# and its number follows the hunk header; an untracked file is wholly new.
_added_lines() {
    if git ls-files --error-unmatch -- "$1" >/dev/null 2>&1 && git cat-file -e "$base_ref:$1" 2>/dev/null; then
        git diff -U0 "$base_ref" -- "$1" 2>/dev/null | awk '
            /^@@/ { split($3, a, ","); n = substr(a[1], 2) + 0; next }
            /^\+\+\+/ { next }
            /^\+/ { print n ":" substr($0, 2); n++; next }'
    else
        awk '{ print NR ":" $0 }' "$1"
    fi
}

_routes_through_scratch() {
    case "$1" in
        *scratch-dir.sh*|*/scratch/*|*'$SCRATCH'*|*'${SCRATCH'*|*TILLANDSIAS_SCRATCH*) return 0 ;;
    esac
    return 1
}

files=0; sites=0; exempt=0; violations=0
pop="$(
    { git diff --name-only "$base_ref" -- 'scripts/*.sh' 'scripts/**/*.sh' 2>/dev/null
      git ls-files --others --exclude-standard -- 'scripts/*.sh' 'scripts/**/*.sh' 2>/dev/null; } | LC_ALL=C sort -u
)"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue                    # deleted in this change: nothing added
    case "$f" in "$SELF"|"$SELF_FIXTURE") continue ;; esac
    files=$((files + 1))
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        ln="${rec%%:*}"; line="${rec#*:}"
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in ''|'#'*) continue ;; esac   # a comment is not a site
        code="$line"
        case "$line" in
            *'# scratch-exception:'*)
                key="${line##*# scratch-exception:}"
                key="${key%%[[:space:]]*}"
                if _recorded "$key"; then
                    exempt=$((exempt + 1)); continue
                fi
                violations=$((violations + 1))
                echo "violation:scratch-location-added:unrecorded-exception:$f:$ln"
                _afford "the line claims scratch-exception:$key, and $EXC_FILE does not list that key, so the exception is nobody's decision" \
                    "use a listed key (user-runtime, podman-runroot, matcher, preflight-door), or record the new one in $EXC_FILE with the measurement that forces it"
                continue ;;
        esac
        rule=""
        if printf '%s\n' "$code" | grep -Eq '(^|\$\(|\(|`|;|&&|\|\||\|)[[:space:]]*mktemp([[:space:]]|$)'; then
            _routes_through_scratch "$code" || rule="mktemp"
        fi
        if [ -z "$rule" ]; then
            case "$code" in
                */tmp/*|*/var/tmp/*|*'$TMPDIR'*|*'${TMPDIR'*)
                    _routes_through_scratch "$code" || rule="tmp" ;;
            esac
        fi
        if [ -z "$rule" ]; then
            case "$code" in
                *'git worktree add'*)
                    _routes_through_scratch "$code" || rule="worktree" ;;
            esac
        fi
        if [ -z "$rule" ]; then
            if printf '%s\n' "$code" | grep -Eq '(mkdir|mktemp|cp|mv|tee|rsync|git clone|git worktree add)[^|;&]*[[:space:]"'"'"']\.\./|>+[[:space:]]*"?\.\./'; then
                rule="parent"
            fi
        fi
        if [ -z "$rule" ]; then
            case "$code" in *mktemp*|*'git worktree add'*) sites=$((sites + 1)) ;; esac
            continue
        fi
        violations=$((violations + 1))
        echo "violation:scratch-location-added:$rule:$f:$ln"
        # labels quoted: a bare `mktemp)` at line start reads as a site to 1619-7i9r
        case "$rule" in
            "mktemp")   why="a new mktemp makes scratch outside the checkout; deleting it later asks the operator for consent (1443-we89), which halts a bypass-mode session" ;;
            "tmp")      why="a new /tmp or \$TMPDIR path makes scratch outside the checkout; deleting it later asks the operator for consent (1443-we89)" ;;
            "worktree") why="a new worktree outside scratch/ is outside the session's workspace (single_checkout_branching); its removal needs operator consent" ;;
            "parent")   why="a write that climbs to ../ leaves the checkout; nothing inside the workspace may delete it without a consent prompt" ;;
        esac
        _afford "$why" "$REMEDY"
    done <<EOF
$(_added_lines "$f")
EOF
done <<EOF
$pop
EOF

if [ "$violations" -gt 0 ]; then
    echo "violation:scratch-location-added:$violations"
    _afford "$violations added line(s) make scratch outside <checkout>/scratch/ (listed above with path:line); this guard is diff-scoped and never flags the existing corpus" \
        "$REMEDY"
    exit 1
fi
echo "ok:scratch-location-added:files=$files:sites=$sites:exempt=$exempt"
exit 0
