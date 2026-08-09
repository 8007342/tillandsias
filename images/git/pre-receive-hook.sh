#!/bin/sh
# @trace spec:git-mirror-service, spec:cross-platform
# Pre-receive hook for git mirrors managed by Tillandsias.
# Installed into each mirror's hooks/pre-receive directory.
#
# Validates ledger YAML, then synchronously relays the proposed ref transaction
# upstream before accepting it locally. A client success therefore means the
# configured upstream has durably accepted the same atomic ref set.
#
# Branch policy (rung 2, order 500) is CONFIG-DRIVEN and convention-neutral:
# see the "config-supplied branch policy" section below. When that config is
# absent (e.g. a non-Tillandsias end-user mirror) this hook behaves exactly as
# before: no grammar warnings, no gate exemptions.
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

# --- Config-supplied branch policy (rung 2, order 500) ---
# @trace spec:git-mirror-service
# Branch-name grammar and YAML-gate ref exemptions reach this hook ONLY via
# the environment, supplied by the service entrypoint (or a test fixture).
# Hook CODE stays convention-neutral (the order-462 leak class): no project
# branch names or namespace enums are hard-coded here. On a mirror where
# these variables are absent or empty — e.g. a non-Tillandsias end-user
# repo — the hook emits no grammar warnings and exempts no refs, which is
# byte-identical to its pre-rung-2 behavior.
#
#   TILLANDSIAS_BRANCH_CREATION_REGEX  ERE matched against the full refname
#                                      of NEW branch creations (zero oldsha,
#                                      refs/heads/* only). A non-matching
#                                      name WARNS and is ACCEPTED: rung 2 is
#                                      warn-only; rejection is a later rung.
#   TILLANDSIAS_BRANCH_GRAMMAR_HINT    Optional human-readable summary of the
#                                      expected namespaces, used in the
#                                      warning instead of the raw regex.
#   TILLANDSIAS_YAML_GATE_EXEMPT_REFS  Space-separated shell glob(s); a full
#                                      refname matching one skips the
#                                      ledger-YAML gate for that ref so a
#                                      blocked agent can land a half-edited
#                                      tree for triage. Content is
#                                      re-validated at graduation/merge.
warn_if_outside_branch_grammar() {
    local refname="$1"
    [ -n "${TILLANDSIAS_BRANCH_CREATION_REGEX:-}" ] || return 0
    case "$refname" in
        refs/heads/*) ;;
        *) return 0 ;;
    esac
    if printf '%s\n' "$refname" | grep -Eq -e "$TILLANDSIAS_BRANCH_CREATION_REGEX"; then
        return 0
    fi
    log_msg "WARNING: new branch '$refname' does not match the configured branch-creation grammar"
    if [ -n "${TILLANDSIAS_BRANCH_GRAMMAR_HINT:-}" ]; then
        log_msg "WARNING: expected namespaces: $TILLANDSIAS_BRANCH_GRAMMAR_HINT"
    else
        log_msg "WARNING: expected pattern: $TILLANDSIAS_BRANCH_CREATION_REGEX"
    fi
    log_msg "WARNING: push accepted anyway — the branch-name grammar is warn-only at this rung"
    return 0
}

# --- CI workflow budget (order 598, operator directive 2026-08-03) ---
# @trace spec:git-mirror-service
#
# "ONLY the actual release needs to run in the cloud, since it uses github
# secrets for signing some binaries, everything else runs locally."
#
# CONFIG-DRIVEN and convention-neutral, like the branch grammar above: the hook
# hard-codes no filenames. Absent config = no gate, which is byte-identical to
# this hook's prior behavior and correct for an end-user repo that legitimately
# runs its own CI.
#
#   TILLANDSIAS_CI_WORKFLOW_ALLOWLIST  Space-separated shell glob(s) matched
#                                      against the BASENAME of any changed file
#                                      under .github/workflows/. A file whose
#                                      basename matches none of them is
#                                      REJECTED.
#
# Rejection, not a warning — unlike the branch grammar. A warning here would be
# indistinguishable from no gate: the push would still land, the workflow would
# still fire, and the minutes would still be spent. The failure this prevents
# already happened once (nix-cache-warm.yml kept firing from the default branch
# for two days after it was "removed").
#
# Returns 0 when the path is fine (not a workflow, or an allowed one).
workflow_path_is_allowed() {
    local path="$1"
    local base pattern

    [ -n "${TILLANDSIAS_CI_WORKFLOW_ALLOWLIST:-}" ] || return 0

    case "$path" in
        .github/workflows/*) ;;
        *) return 0 ;;
    esac

    # TOP-LEVEL ONLY. A shell `case` glob matches `/`, so a naive
    # `.github/workflows/*.yml` also catches `.github/workflows/nested/x.yml`.
    # GitHub only executes workflow files at the top level of that directory, so
    # a nested file consumes no minutes and rejecting it would be a false
    # positive against legitimate content.
    base="${path#.github/workflows/}"
    case "$base" in
        */*) return 0 ;;
    esac

    case "$base" in
        *.yml|*.yaml) ;;
        *) return 0 ;;
    esac
    for pattern in $TILLANDSIAS_CI_WORKFLOW_ALLOWLIST; do
        # shellcheck disable=SC2254
        # Unquoted on purpose: the config supplies shell glob patterns.
        case "$base" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

ref_is_gate_exempt() {
    local refname="$1"
    local pattern
    [ -n "${TILLANDSIAS_YAML_GATE_EXEMPT_REFS:-}" ] || return 1
    for pattern in $TILLANDSIAS_YAML_GATE_EXEMPT_REFS; do
        # shellcheck disable=SC2254
        # Unquoted on purpose: the config supplies shell glob patterns.
        case "$refname" in
            $pattern) return 0 ;;
        esac
    done
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
OID_SAMPLE="$(git hash-object --stdin </dev/null 2>/dev/null)" || {
    log_msg "Push rejected: cannot determine repository object format"
    exit 1
}
OID_LENGTH="${#OID_SAMPLE}"
ZERO_SHA="$(printf '%*s' "$OID_LENGTH" '' | tr ' ' '0')"
SEEN_REFS="$TMPDIR_WORK/seen-refs"
: > "$SEEN_REFS"

# --- Validate transaction + enforce policy before privileged relay (order 579) ---
# @trace spec:git-mirror-service
# receive-pack runs pre-receive BEFORE it evaluates receive.denyDeletes and
# receive.denyNonFastForwards. Relying on repo config alone can therefore relay
# a destructive transaction upstream and reject it only afterwards locally.
# Validate the same load-bearing transaction facts receive-pack applies later:
# refname grammar, object-ID width/existence, uniqueness, and exact old-value
# match. Without this, a fabricated stale OLDSHA or invalid refname can reach
# upstream first and then fail local receive-pack validation, splitting refs.
# Apply the zero-trust containment policy here while both repositories are still
# unchanged: reject every ref deletion, plus non-fast-forward branch updates.
# Git's receive.denyDeletes is branch-scoped in practice, so the explicit hook
# check is what protects tag and custom namespaces. New ref creation remains
# allowed.
RECEIVE_POLICY_REJECTED=0
while read -r OLDSHA NEWSHA REFNAME EXTRA; do
    if [ -z "$OLDSHA" ] || [ -z "$NEWSHA" ] || [ -z "$REFNAME" ] || [ -n "${EXTRA:-}" ]; then
        log_msg "REJECT: malformed receive transaction record"
        RECEIVE_POLICY_REJECTED=1
        continue
    fi

    if [ "${#OLDSHA}" -ne "$OID_LENGTH" ] || [ "${#NEWSHA}" -ne "$OID_LENGTH" ]; then
        log_msg "REJECT: object ID width does not match repository object format"
        RECEIVE_POLICY_REJECTED=1
        continue
    fi
    case "$OLDSHA$NEWSHA" in
        *[!0-9a-f]*)
            log_msg "REJECT: object ID is not lowercase hexadecimal"
            RECEIVE_POLICY_REJECTED=1
            continue
            ;;
    esac

    case "$REFNAME" in
        refs/*) ;;
        *)
            log_msg "REJECT: refname is outside refs/*"
            RECEIVE_POLICY_REJECTED=1
            continue
            ;;
    esac
    if ! git check-ref-format "$REFNAME" >/dev/null 2>&1; then
        log_msg "REJECT: invalid refname in receive transaction"
        RECEIVE_POLICY_REJECTED=1
        continue
    fi
    if grep -Fqx "$REFNAME" "$SEEN_REFS"; then
        log_msg "REJECT: duplicate ref in receive transaction: $REFNAME"
        RECEIVE_POLICY_REJECTED=1
        continue
    fi
    printf '%s\n' "$REFNAME" >> "$SEEN_REFS"

    ACTUAL_SHA="$(git rev-parse --verify "$REFNAME" 2>/dev/null || true)"
    if [ "$OLDSHA" = "$ZERO_SHA" ]; then
        if [ -n "$ACTUAL_SHA" ]; then
            log_msg "REJECT: stale old object ID does not match current ref: $REFNAME"
            RECEIVE_POLICY_REJECTED=1
            continue
        fi
    elif [ "$ACTUAL_SHA" != "$OLDSHA" ]; then
        log_msg "REJECT: stale old object ID does not match current ref: $REFNAME"
        RECEIVE_POLICY_REJECTED=1
        continue
    fi

    if [ "$NEWSHA" = "$ZERO_SHA" ]; then
        log_msg "REJECT: ref deletion is disabled: $REFNAME"
        RECEIVE_POLICY_REJECTED=1
        continue
    fi

    if ! git cat-file -e "$NEWSHA" 2>/dev/null; then
        log_msg "REJECT: proposed object is unavailable: $REFNAME"
        RECEIVE_POLICY_REJECTED=1
        continue
    fi

    case "$REFNAME" in
        refs/heads/*)
            if [ "$(git cat-file -t "$NEWSHA" 2>/dev/null || true)" != "commit" ]; then
                log_msg "REJECT: proposed branch tip is not a commit: $REFNAME"
                RECEIVE_POLICY_REJECTED=1
                continue
            fi
            ;;
    esac

    case "$REFNAME" in
        refs/heads/*)
            if [ "$OLDSHA" != "$ZERO_SHA" ] \
               && ! git merge-base --is-ancestor "$OLDSHA" "$NEWSHA" 2>/dev/null; then
                log_msg "REJECT: non-fast-forward branch update is disabled: $REFNAME"
                RECEIVE_POLICY_REJECTED=1
            fi
            ;;
    esac
done < "$UPDATES_FILE"

if [ "$RECEIVE_POLICY_REJECTED" -eq 1 ]; then
    log_msg "Push rejected: transaction or receive hardening policy failed before upstream relay"
    exit 1
fi

# Read stdin: one line per ref as "<oldsha> <newsha> <refname>"
while read -r OLDSHA NEWSHA REFNAME; do
    [ -n "$REFNAME" ] || continue

    # Deletions were rejected in the pre-relay transaction pass above.
    [ "$NEWSHA" = "$ZERO_SHA" ] && continue

    # Rung 2 (order 500): warn-only name grammar applies to NEW branch
    # creations only (zero oldsha). Never rejects; no-op without config.
    if [ "$OLDSHA" = "$ZERO_SHA" ]; then
        warn_if_outside_branch_grammar "$REFNAME"
    fi

    # Rung 2 (order 500, repair B4): a ref matching a config-supplied exempt
    # pattern skips the ledger-YAML gate entirely — a blocked agent must be
    # able to land a half-edited tree for triage. The relay below still runs
    # for the full transaction, and content is re-validated when the ref
    # graduates via merge (rung-4 territory). Absent config = no exemptions.
    if ref_is_gate_exempt "$REFNAME"; then
        log_msg "NOTE: $REFNAME matches a configured YAML-gate exemption; ledger YAML validation skipped for this ref (re-validated at graduation)"
        continue
    fi

    # Determine the set of changed files to validate
    case "$OLDSHA" in
        "$ZERO_SHA")
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
            # Existing branch: diff between old and new trees.
            FILES="$(git diff --name-only "$OLDSHA" "$NEWSHA" 2>/dev/null)" || continue
            ;;
    esac

    [ -n "$FILES" ] || continue

    # Check each changed file (process substitution, not pipe, to avoid subshell)
    while IFS= read -r FILEPATH; do
        [ -n "$FILEPATH" ] || continue

        # CI workflow budget gate. Rejecting HERE is uniquely effective: the
        # mirror relays the transaction upstream only after accepting it
        # locally, so a workflow file stopped at this point never reaches the
        # forge host and therefore can never trigger a paid run. A local hook
        # can be --no-verify'd; this cannot.
        # A DELETION also appears in `git diff --name-only`, so gate only paths
        # that still EXIST in the new tree. Without this, removing a workflow
        # would be rejected — the gate would block the very cleanup it exists to
        # protect, and the only way to comply would be to bypass it.
        if git cat-file -e "$NEWSHA:$FILEPATH" 2>/dev/null; then
            if ! workflow_path_is_allowed "$FILEPATH"; then
                log_msg "REJECT: $FILEPATH is not an allowed CI workflow"
                log_msg "REJECT: allowed: ${TILLANDSIAS_CI_WORKFLOW_ALLOWLIST:-<none>}"
                : > "$REJECT_MARKER"
            fi
        fi

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
