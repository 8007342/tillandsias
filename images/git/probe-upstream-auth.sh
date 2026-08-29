#!/bin/sh
# @trace spec:git-mirror-service
# probe-upstream-auth <bare-mirror-dir>
#
# Order 756-2jnj (child of order 424): NON-MUTATING upstream WRITE-authorization
# probe. On 2026-08-15 a fresh-Windows forge lost two commits because the
# credential guard said ok:forge-git-mirror on REACHABILITY alone, while the
# mirror's Vault credential could not push upstream (GitHub 403 "Permission to
# 8007342/tillandsias.git denied") — a fact nobody learned until the FIRST push,
# hours after worker drain began. The verified-ack refusal worked as designed;
# detection was just too late. This probe moves that discovery to cycle start.
#
# WHAT IT PROVES. A `git push --dry-run` against the configured upstream fetches
# the receive-pack ref advertisement AUTHENTICATED with the same Vault-backed
# credential helper the live relay uses (order 424: token travels on stdin,
# never argv/env/URL). GitHub authorizes that advertisement request itself:
# 200 = the credential may push, 403 = it may not. --dry-run never sends a
# pack and never updates any upstream ref — no canary ref, nothing mutated.
#
# WHERE THE VERDICT GOES. The forge can only see the mirror through the git
# daemon, so the verdict is published as a ref the daemon already advertises:
#
#   refs/tillandsias/upstream-auth/<state>/<epoch>
#
# <state> is one of authorized | denied | no-credential | agent-unauthenticated | local-only | error;
# and a `denied` verdict carries a REASON segment (order 809-w2xy):
#   refs/tillandsias/upstream-auth/denied/<reason>/<epoch>
#   <reason> = permission | unauthenticated | sso
#              (`unclassified` exists as a defensive default in the classifier
#               but is unreachable today — see classify_refusal)
# The consumer reads the FIRST and LAST segments, so the reason is additive and
# an existing reader is unaffected.
# <epoch> is the probe's unix time, so a consumer can bound staleness
# (yesterday's verdict is from yesterday's token epoch — the bug in a hat).
# The namespace is OUTSIDE refs/heads and refs/tags, so the startup retry
# sweep, the reconcile passes, and clones all ignore it; it is never relayed
# upstream. Exactly one ref is kept: the new verdict is written first, then
# older ones are pruned (a crash between the two leaves extra refs, and the
# consumer picks the largest epoch).
#
# The consumer is scripts/check-credential-channel.sh (forge branch), which
# reads it via `git ls-remote origin 'refs/tillandsias/upstream-auth/*'` —
# the same transport a push takes.
#
# Emits exactly one line on stdout matching the falsifiable grammar
#   ^upstream-auth:(authorized|denied|no-credential|agent-unauthenticated|local-only|error):[0-9]+$
# and exits 0 (authorized | local-only) or 1 (everything else);
#
# `no-credential` vs `agent-unauthenticated` is a REMEDY distinction, not a
# shade of the same fact (order 828-k3mq). `no-credential` means Vault answered
# and holds no GitHub token — GitHub Login repairs it. `agent-unauthenticated`
# means the mirror's OWN Vault client token is dead, so the GitHub token's state
# is UNKNOWN and running GitHub Login is the wrong move; the Agent's AppRole
# login is what needs repair. The relay has always drawn this line in its log
# ("do NOT run GitHub Login"); the published verdict now draws it too.
# 2 is usage. Diagnostics go to stderr/log, always credential-redacted.
#
# Testability seams (same pattern as RELAY_REF/ENSURE_HEAD/RECONCILE_HEADS):
#   PUSH_PROBE  — executable invoked as `$PUSH_PROBE <push-url> <refspec>`
#                 instead of the real `git push --dry-run`, so fixtures can
#                 replay the exact 2026-08-15 GitHub 403 offline.
#   VAULT_CLI   — vault client command (default vault-cli); fixtures point it
#                 at a nonexistent path to model an ABSENT upstream credential.

LOG_CANDIDATES="/var/log/tillandsias/git-push.log $HOME/.cache/tillandsias/git-push.log /tmp/git-push.log"
LOG_FILE=""
for candidate in $LOG_CANDIDATES; do
    dir="$(dirname "$candidate")"
    if [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; then
        if : >> "$candidate" 2>/dev/null || [ -w "$candidate" ]; then
            LOG_FILE="$candidate"
            break
        fi
    fi
done

log_msg() {
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
    if [ -n "$LOG_FILE" ]; then
        echo "$timestamp [upstream-auth] $1" >> "$LOG_FILE" 2>/dev/null
    fi
    echo "[upstream-auth] $1" >&2
}

redact_output() { echo "$1" | sed -E 's#https://[^@/]+@#https://***@#g'; }

MIRROR="${1:-}"
if [ -z "$MIRROR" ] || [ ! -d "$MIRROR" ]; then
    echo "probe-upstream-auth: usage: probe-upstream-auth <bare-mirror-dir>" >&2
    exit 2
fi

EPOCH="$(date -u +%s)"

# Publish <state> as the single ref in the verdict namespace and print the
# probe's one-line verdict. The ref target is the empty blob — always
# writable, never confusable with project history.
publish() {
    state="$1"
    # ORDER 809-w2xy. A REASON segment may sit between the state and the epoch.
    # It is BACKWARD COMPATIBLE by construction: the consumer parses
    # `state="${rest%%/*}"` and `epoch="${rest##*/}"`
    # (scripts/check-credential-channel.sh), so a middle segment is invisible to
    # a reader that does not want it, and `git ls-remote` matches the deeper ref
    # under the same `refs/tillandsias/upstream-auth/*` pattern — verified
    # 2026-08-29 rather than assumed, because a guard that silently stopped
    # seeing the verdict would fail OPEN on the one signal that blocks drain.
    reason="${2:-}"
    if [ -n "$reason" ]; then
        new_ref="refs/tillandsias/upstream-auth/$state/$reason/$EPOCH"
    else
        new_ref="refs/tillandsias/upstream-auth/$state/$EPOCH"
    fi
    if blob="$(git -C "$MIRROR" hash-object -w --stdin </dev/null 2>/dev/null)" \
       && git -C "$MIRROR" update-ref "$new_ref" "$blob" 2>/dev/null; then
        for old in $(git -C "$MIRROR" for-each-ref --format='%(refname)' refs/tillandsias/upstream-auth 2>/dev/null); do
            [ "$old" = "$new_ref" ] && continue
            git -C "$MIRROR" update-ref -d "$old" 2>/dev/null || true
        done
    else
        # Publication failure is loud but does not change the verdict: the
        # consumer treats an absent/stale ref as blocked, which fails closed.
        log_msg "WARNING: could not publish $new_ref in $MIRROR"
    fi
    echo "upstream-auth:$state:$EPOCH"
}

finish() {
    state="$1"
    publish "$state" "${2:-}"
    case "$state" in
        authorized|local-only) exit 0 ;;
        *) exit 1 ;;
    esac
}

REMOTE_URL="$(git -C "$MIRROR" remote get-url origin 2>/dev/null || true)"
if [ -z "$REMOTE_URL" ]; then
    # No upstream configured: relay-refs accepts pushes as durable local-only
    # mirror updates, so the write channel IS usable.
    finish local-only
fi

PUSH_URL="$REMOTE_URL"
case "$REMOTE_URL" in
    https://*)
        # Same credential discovery as relay-refs.sh: Vault Agent owns the
        # token lifecycle; we only check that a token is CURRENTLY readable.
        # The secret value itself is discarded (>/dev/null) — never printed,
        # never persisted.
        VAULT_CLI="${VAULT_CLI:-vault-cli}"
        VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/run/secrets/vault-token}"
        # ORDER 828-k3mq: TWO FAILURES, TWO REMEDIES, AND THEY USED TO SHARE A
        # WORD. This block collapsed "the mirror's own Vault client token is
        # dead" and "Vault answers but holds no GitHub token" into one
        # `no-credential` verdict. The operator actions are OPPOSITE — the
        # first is repaired by the Vault Agent re-authenticating (and the relay
        # explicitly says "do NOT run GitHub Login"), the second is repaired by
        # running GitHub Login — so a single word sent half the readers the
        # wrong way. Measured on yolanda 2026-08-18: the Agent's AppRole login
        # had been failing for hours, the GitHub token was perfectly valid, and
        # the verdict said `no-credential`.
        #
        # Ordered deliberately: nothing this probe says about the GitHub
        # credential means anything until the client token it would be read
        # with is known good.
        if ! command -v "$VAULT_CLI" >/dev/null 2>&1 || [ ! -r "$VAULT_TOKEN_FILE" ]; then
            log_msg "the mirror's Vault client token sink is absent or unreadable ($VAULT_TOKEN_FILE); the Agent has not authenticated, so the GitHub credential cannot be read and its state is UNKNOWN. Inspect the [vault-agent] log; do NOT run GitHub Login on the strength of this verdict."
            finish agent-unauthenticated
        fi
        if ! "$VAULT_CLI" lookup-self >/dev/null 2>&1; then
            log_msg "the mirror's Vault client token is expired or rejected (lookup-self failed); the Agent cannot re-authenticate, so the GitHub credential cannot be read and its state is UNKNOWN. This is the order 828-k3mq shape — check whether the AppRole SecretID was destroyed under a still-running mirror. Do NOT run GitHub Login."
            finish agent-unauthenticated
        fi
        if ! "$VAULT_CLI" read -field=token secret/github/token >/dev/null 2>&1; then
            log_msg "Vault answers this mirror, but holds no readable upstream credential at secret/github/token; a push would fail before reaching GitHub. THIS is the state GitHub Login repairs."
            finish no-credential
        fi
        # Keep the URL clean (order 424) and wire the same stdin credential
        # helper the relay uses, via the ENVIRONMENT so the probe's command
        # shape stays a plain `git push --dry-run`.
        PUSH_URL="$(echo "$REMOTE_URL" | sed -E 's#https://[^@/]+@#https://#')"
        GIT_CONFIG_COUNT=2
        GIT_CONFIG_KEY_0=credential.helper
        GIT_CONFIG_VALUE_0=""
        GIT_CONFIG_KEY_1=credential.helper
        GIT_CREDENTIAL_HELPER="${GIT_CREDENTIAL_HELPER:-/usr/local/bin/git-credential-tillandsias}"
        GIT_CONFIG_VALUE_1="$GIT_CREDENTIAL_HELPER"
        export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 \
               GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1
        ;;
esac

# Any existing local head works: the authorization answer arrives with the ref
# advertisement, before git compares a single commit. Old-sha/new-sha content
# is irrelevant under --dry-run.
PROBE_REF="$(git -C "$MIRROR" for-each-ref --format='%(refname)' refs/heads 2>/dev/null | head -n 1)"
if [ -z "$PROBE_REF" ]; then
    log_msg "mirror has no local heads to probe with (still seeding?); cannot determine authorization"
    finish error
fi
PROBE_SHA="$(git -C "$MIRROR" rev-parse "$PROBE_REF" 2>/dev/null)"
if [ -z "$PROBE_SHA" ]; then
    log_msg "cannot resolve $PROBE_REF; cannot determine authorization"
    finish error
fi

if [ -n "${PUSH_PROBE:-}" ]; then
    OUT="$("$PUSH_PROBE" "$PUSH_URL" "$PROBE_SHA:$PROBE_REF" 2>&1)" && rc=0 || rc=$?
else
    OUT="$(GIT_TERMINAL_PROMPT=0 timeout "${AUTH_PROBE_TIMEOUT:-30}" \
        git -C "$MIRROR" push --dry-run "$PUSH_URL" "$PROBE_SHA:$PROBE_REF" 2>&1)" && rc=0 || rc=$?
fi

if [ "$rc" -eq 0 ]; then
    finish authorized
fi

OUT_REDACTED="$(redact_output "$OUT")"

# ORDER 809-w2xy — WHY the refusal, not just that there was one.
#
# `denied` collapsed three refusals that need three DIFFERENT operator actions,
# and the packet's second deliverable is to tell them apart at probe time so the
# next occurrence is a one-line answer instead of a two-hour rediscovery.
#
# THE CLASSIFICATION IS DELIBERATELY COARSE, and here is the measured reason.
# On 2026-08-15 this fleet captured the real refusal:
#
#   remote: Permission to 8007342/tillandsias.git denied to 8007342.
#   fatal: unable to access: The requested URL returned error: 403
#
# and the operator later found the cause was an EXPIRED PAT (recorded on
# 809-w2xy, 2026-08-19). So on this fleet an expired token presents as
# "permission denied", NOT as an authentication failure. `permission` therefore
# means "authenticated, then refused" and must NOT be read as "the scope is
# wrong" — expiry is the first thing to check, and the guard says so in that
# order. Claiming a finer split than the evidence supports would be the same
# confident-wrong-cause this milestone exists to remove.
#
# `sso` is the one refusal with a genuinely distinctive upstream message. It is
# classified from GitHub's documented SAML wording rather than from a capture on
# this fleet — we have never hit it — so it is separated from the measured cases
# here rather than presented as equally evidenced.
classify_refusal() {
    # The `*)` arm below is UNREACHABLE today and deliberately kept: every
    # substring the outer case matches on is covered by an arm here, and output
    # matching none of them goes to `finish error` rather than reaching this
    # function at all. It exists so that widening the outer case can never
    # produce an EMPTY reason and a malformed ref — not as a state an operator
    # will ever be shown. Verified unreachable 2026-08-29 by exercising every
    # outer token.
    case "$1" in
        *"SAML"*|*"SSO"*|*"single sign-on"*|*"single-sign-on"*) echo sso ;;
        *"error: 401"*|*"Authentication failed"*|*"could not read Username"*|*"terminal prompts disabled"*|*"Invalid username or password"*)
            echo unauthenticated ;;
        *"error: 403"*|*"Permission to "*|*"denied to "*|*"Write access to repository not granted"*)
            echo permission ;;
        *) echo unclassified ;;
    esac
}

case "$OUT" in
    # Authorization/authentication failures. GitHub's 403 body is
    # "Permission to <repo> denied to <login>"; 401/credential-helper
    # failures surface as "Authentication failed", "could not read
    # Username", or "terminal prompts disabled".
    *"error: 403"*|*"Permission to "*|*"denied to "*|*"error: 401"*|*"Authentication failed"*|*"could not read Username"*|*"terminal prompts disabled"*|*"Invalid username or password"*|*"Write access to repository not granted"*|*"SAML"*|*"SSO"*)
        refusal="$(classify_refusal "$OUT")"
        log_msg "upstream REFUSED the authenticated receive-pack advertisement (reason=$refusal) — the credential cannot push: $OUT_REDACTED"
        finish denied "$refusal"
        ;;
    # The advertisement WAS served (authorization succeeded); the dry-run then
    # failed on ref policy (e.g. non-fast-forward). That is a data problem,
    # not an authorization problem — reconcile handles it.
    *"[rejected]"*|*"non-fast-forward"*|*"[remote rejected]"*)
        log_msg "advertisement served; dry-run rejected on ref policy (not an authorization failure): $OUT_REDACTED"
        finish authorized
        ;;
    *)
        log_msg "probe could not determine authorization (network/transport failure?): $OUT_REDACTED"
        finish error
        ;;
esac
