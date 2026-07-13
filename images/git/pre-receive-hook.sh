#!/bin/sh
# @trace spec:git-mirror-service, spec:cross-platform
# Pre-receive hook for git mirrors managed by Tillandsias.
# Installed into each mirror's hooks/pre-receive directory.
#
# Validates YAML files in plan/ and openspec/ paths before accepting a push.
# Rejects the push if any touched YAML file fails to parse. This prevents
# broken plan/index.yaml or openspec spec files from propagating to GitHub.
#
# Validator fallback order:
#   1. tillandsias-policy validate-yaml (if available)
#   2. ruby -ryaml (Alpine package)
#   3. skip validation with warning (if neither is available)
#
# Exit codes:
#   0 - push accepted (all YAML valid or no YAML touched)
#   1 - push rejected (YAML validation failed)

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
    log_msg "WARNING: no YAML validator found (tillandsias-policy or ruby); skipping validation"
    exit 0
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

# --- Temp directory for extracted blobs ---
TMPDIR_WORK="$(mktemp -d 2>/dev/null || mktemp -d -t 'git-pre-receive')"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

REJECTED=0

# Read stdin: one line per ref as "<oldsha> <newsha> <refname>"
while read -r OLDSHA NEWSHA REFNAME; do
    [ -n "$REFNAME" ] || continue

    # Skip deletions (newsha is zero)
    case "$NEWSHA" in
        0000000000000000000000000000000000000000) continue ;;
    esac

    # If this is the initial push (oldsha is zero), validate the whole tree
    case "$OLDSHA" in
        0000000000000000000000000000000000000000)
            FILES="$(git ls-tree -r --name-only "$NEWSHA" 2>/dev/null)" || continue
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

        # Extract the file content from the new tree
        CONTENT="$(git show "$NEWSHA:$FILEPATH" 2>/dev/null)" || {
            log_msg "WARNING: could not extract $FILEPATH from $NEWSHA"
            continue
        }

        # Write to temp file for validation
        TMPFILE="$TMPDIR_WORK/$(echo "$FILEPATH" | tr '/' '_')"
        printf '%s\n' "$CONTENT" > "$TMPFILE"

        if ! validate_yaml_file "$FILEPATH" "$TMPFILE"; then
            REJECTED=1
        fi
    done < <(echo "$FILES")
done

if [ "$REJECTED" -eq 1 ]; then
    log_msg "Push rejected: YAML validation failed for ledger files"
    exit 1
fi

exit 0
