#!/bin/sh
# @trace spec:git-mirror-service, spec:cross-platform
# Pre-receive hook for git mirrors managed by Tillandsias.
# Installed into each mirror's hooks/pre-receive directory.
#
# Validates ledger YAML, then synchronously relays the proposed ref transaction
# upstream before accepting it locally. A client success therefore means the
# configured upstream has durably accepted the same atomic ref set.
#
# Validator fallback order:
#   1. tillandsias-policy validate-yaml (if available)
#   2. ruby -ryaml (Alpine package)
#   3. reject ledger-YAML updates (if neither is available)
#
# Exit codes:
#   0 - push accepted (policy valid and upstream relay verified)
#   1 - push rejected (policy or upstream relay failed)

# --- Logging (shared with post-receive hook pattern) ---
LOG_CANDIDATES="/var/log/tillandsias/git-push.log $HOME/.cache/tillandsias/git-push.log /tmp/git-push.log"
LOG_FILE=""
for candidate in $LOG_CANDIDATES; do
    dir="$(dirname "$candidate")"
    if [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; then
        if : > "$candidate" 2>/dev/null || [ -w "$candidate" ]; then
            LOG_FILE="$candidate"
            break
        fi
    fi
done

log_msg() {
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
    if [ -n "$LOG_FILE" ]; then
        echo "$timestamp [pre-receive] $1" >> "$LOG_FILE" 2>/dev/null
    fi
    echo "[pre-receive] $1" >&2
}

# --- Discover validator ---
VALIDATOR=""
if command -v tillandsias-policy >/dev/null 2>&1; then
    VALIDATOR="tillandsias-policy"
elif command -v ruby >/dev/null 2>&1; then
    VALIDATOR="ruby"
else
    VALIDATOR="none"
    log_msg "WARNING: no YAML validator found (tillandsias-policy or ruby)"
fi

# --- Validate a single YAML file content ---
# Args: $1 = file path (for logging), $2 = temp file path with content
validate_yaml_file() {
    local label="$1"
    local tmpfile="$2"

    case "$VALIDATOR" in
        tillandsias-policy)
            if tillandsias-policy validate-yaml "$tmpfile" >/dev/null 2>&1; then
                return 0
            else
                log_msg "REJECT: $label failed YAML validation"
                tillandsias-policy validate-yaml "$tmpfile" 2>&1 | while IFS= read -r line; do
                    log_msg "  $line"
                done
                return 1
            fi
            ;;
        ruby)
            if ruby -ryaml -e "YAML.load_file(ARGV[0])" "$tmpfile" 2>/dev/null; then
                return 0
            else
                log_msg "REJECT: $label failed YAML validation (ruby)"
                ruby -ryaml -e "YAML.load_file(ARGV[0])" "$tmpfile" 2>&1 | while IFS= read -r line; do
                    log_msg "  $line"
                done
                return 1
            fi
            ;;
        none)
            log_msg "REJECT: $label cannot be validated because no YAML validator is installed"
            return 1
            ;;
    esac
}

# --- Check if a path is a YAML file we care about ---
is_ledger_yaml() {
    local path="$1"
    case "$path" in
        plan.yaml) return 0 ;;
        plan/*.yaml) return 0 ;;
        plan/**/*.yaml) return 0 ;;
        openspec/*.yaml) return 0 ;;
        openspec/**/*.yaml) return 0 ;;
    esac
    return 1
}

# --- Check if a path is in the frozen legacy archive (exempt from validation) ---
is_legacy_archive() {
    local path="$1"
    case "$path" in
        openspec/changes/archive/*) return 0 ;;
    esac
    return 1
}

# --- For a new branch, find the nearest existing ancestor ref to diff against ---
# This avoids validating the entire inherited tree (which includes frozen legacy
# archive files that intentionally have invalid YAML).
find_diff_base() {
    local newsra="$1"

    # Try the repository's default branch (HEAD symbolic ref)
    local default_ref
    if default_ref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"; then
        local base_sha
        if base_sha="$(git merge-base "$newsra" "$default_ref" 2>/dev/null)"; then
            echo "$base_sha"
            return 0
        fi
    fi

    # Fallback: try common branch names
    local candidate
    for candidate in origin/linux-next origin/main origin/master; do
        local base_sha
        if base_sha="$(git merge-base "$newsra" "$candidate" 2>/dev/null)"; then
            echo "$base_sha"
            return 0
        fi
    done

    return 1
}

# --- Temp directory for extracted blobs ---
TMPDIR_WORK="$(mktemp -d 2>/dev/null || mktemp -d -t 'git-pre-receive')"
trap 'rm -rf "$TMPDIR_WORK"' EXIT
UPDATES_FILE="$TMPDIR_WORK/updates"
REJECT_MARKER="$TMPDIR_WORK/rejected"

# Preserve stdin because both policy validation and the relay helper need the
# exact receive-pack transaction.
cat > "$UPDATES_FILE"

REJECTED=0

# Read stdin: one line per ref as "<oldsha> <newsha> <refname>"
while read -r OLDSHA NEWSHA REFNAME; do
    [ -n "$REFNAME" ] || continue

    # Skip deletions (newsha is zero)
    case "$NEWSHA" in
        0000000000000000000000000000000000000000) continue ;;
    esac

    # Determine the set of changed files to validate
    case "$OLDSHA" in
        0000000000000000000000000000000000000000)
            # New branch or tag: find a diff-base ancestor to avoid validating
            # the entire inherited tree (which includes frozen legacy archive
            # files that intentionally have invalid YAML).
            DIFF_BASE="$(find_diff_base "$NEWSHA" 2>/dev/null)"
            if [ -n "$DIFF_BASE" ]; then
                FILES="$(git diff --name-only "$DIFF_BASE" "$NEWSHA" 2>/dev/null)" || continue
            else
                # No ancestor found (true initial push): validate the whole tree
                FILES="$(git ls-tree -r --name-only "$NEWSHA" 2>/dev/null)" || continue
            fi
            ;;
        *)
            # Diff between old and new trees to find changed files
            FILES="$(git diff --name-only "$OLDSHA" "$NEWSHA" 2>/dev/null)" || continue
            ;;
    esac

    [ -n "$FILES" ] || continue

    # Check each changed file (process substitution, not pipe, to avoid subshell)
    while IFS= read -r FILEPATH; do
        [ -n "$FILEPATH" ] || continue
        is_ledger_yaml "$FILEPATH" || continue
        is_legacy_archive "$FILEPATH" && continue

        # Extract the file content from the new tree
        CONTENT="$(git show "$NEWSHA:$FILEPATH" 2>/dev/null)" || {
            log_msg "WARNING: could not extract $FILEPATH from $NEWSHA"
            continue
        }

        # Write to temp file for validation
        TMPFILE="$TMPDIR_WORK/$(echo "$FILEPATH" | tr '/' '_')"
        printf '%s\n' "$CONTENT" > "$TMPFILE"

        if ! validate_yaml_file "$FILEPATH" "$TMPFILE"; then
            : > "$REJECT_MARKER"
        fi
    done <<EOF
$FILES
EOF
done < "$UPDATES_FILE"

[ -e "$REJECT_MARKER" ] && REJECTED=1

if [ "$REJECTED" -eq 1 ]; then
    log_msg "Push rejected: YAML validation failed for ledger files"
    exit 1
fi

RELAY_HELPER="$(dirname "$0")/tillandsias-relay-refs"
if [ ! -x "$RELAY_HELPER" ]; then
    log_msg "Push rejected: relay helper is missing or not executable at $RELAY_HELPER"
    exit 1
fi

if ! "$RELAY_HELPER" < "$UPDATES_FILE"; then
    log_msg "Push rejected: configured upstream did not durably accept the ref transaction"
    exit 1
fi

log_msg "Relay verified: upstream durably accepted the ref transaction"

exit 0
