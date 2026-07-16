# Research: git mirror fetch-before-push reconciliation hooks

- **Filed**: 2026-07-15
- **Host**: linux
- **Packet**: git-mirror-pre-reconcile-research (order 368)
- **Status**: completed

## Executive Summary

In-forge agents experience transient mirror staleness when the enclave's bare git mirror falls behind GitHub. Because standard Git has no server-side `pre-fetch` hook, the mirror cannot transparently pull upstream changes when a client agent runs `git fetch origin`. Consequently, if a blind push fails due to upstream divergence ("fetch first"), the agent's follow-up `git fetch origin` hits the still-stale mirror and retrieves nothing, breaking the automated retry loop.

We investigated standard git hooks, refspecs, and mirroring configurations. The recommended solution is to implement an **auto-reconciliation fetch on relay failure** directly inside the mirror's synchronous `pre-receive` hook (specifically in `relay-refs.sh`), executed *outside* the git quarantine environment, using a **non-forced** refspec to guarantee safe recovery without clobbering locally stranded commits.

## Investigation & Findings

### 1. No Native Client Fetch Interception
Standard Git architecture supports server-side interception for pushes (`pre-receive`, `update`, `post-receive`) but **not for fetches**. There is no standard `pre-upload-pack` hook that would allow the mirror to query GitHub *before* serving a client's `git fetch`.
- **Conclusion**: The mirror cannot auto-reconcile purely in response to a client's read operation. Reconciliation must be triggered either asynchronously (polling/cron, unsuitable for fast agent loops) or during a write operation (push).

### 2. Context from Order 301
Order 301 fixed a severe bug where the mirror's reconcile fetch used a forced refspec (`+refs/*:refs/*` or `+refs/heads/*:refs/heads/*`). If the mirror held a newly received commit that had not yet reached GitHub (or failed to relay), the forced fetch would overwrite the mirror's head with GitHub's older state, destroying the in-flight commit (clobbering exported refs).
- **Conclusion**: Any automatic fetch implemented in the mirror **must not use the forced (`+`) prefix** when targeting `refs/heads/*`.

### 3. The Affordance Gap (Issue 2026-07-15)
When a client pushes to the mirror and upstream rejects it (e.g., `fetch first`), the `pre-receive` hook (`relay-refs.sh`) correctly exits `1`. However, the mirror's state remains stale. The agent catches the push rejection and attempts to repair by fetching, but receives the same stale mirror state. 

## Recommended Hook Design (Solution)

To resolve the gap, we must hook into the **push failure path** inside `images/git/relay-refs.sh`.

When the atomic `git push` to the upstream remote fails:
1. **Unset Git Quarantine Variables**: The `pre-receive` hook runs in a quarantined environment where object writes are temporarily isolated. If we fetch upstream objects while in quarantine, they will be discarded when the hook exits `1`. We must prefix the fetch with `env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES`.
2. **Execute a Non-Forced Fetch**: Run `git fetch "$PUSH_URL" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'`. 
   - Because we omit the `+` flag, Git will natively reject any non-fast-forward updates. 
   - If the mirror is strictly behind upstream, the fetch securely fast-forwards the mirror's refs to match GitHub.
   - If the mirror has locally stranded commits (ahead or diverged), Git rejects the update, perfectly preserving the local state without clobbering, adhering to the order 301 invariant.
3. **Exit 1**: Return the failure to the client as usual.

### Implementation Blueprint (`images/git/relay-refs.sh`)

```bash
# Inside relay-refs.sh, when the push fails:
OUTPUT_REDACTED="$(redact_output "$OUTPUT")"
log_msg "Atomic push to $REMOTE_URL_REDACTED FAILED: $OUTPUT_REDACTED"

if [ -n "$PUSH_URL" ]; then
    log_msg "Attempting non-forced reconcile fetch from upstream..."
    # Escape quarantine so fetched objects are persisted to the main database
    if FETCH_OUTPUT="$(env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        git fetch "$PUSH_URL" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' 2>&1)"; then
        log_msg "Reconcile fetch succeeded. Mirror is now up to date."
    else
        FETCH_OUTPUT_REDACTED="$(redact_output "$FETCH_OUTPUT")"
        log_msg "Reconcile fetch non-fast-forward (expected if locally stranded): $FETCH_OUTPUT_REDACTED"
    fi
fi

unset PUSH_URL TOKEN BARE_URL
exit 1
```

### Why this is the best practice for this architecture:
- **Zero Client Config Changes**: Forge agents continue to run `git fetch origin` seamlessly.
- **Safe Recovery**: Automatically fast-forwards the mirror exactly when it matters (on push conflict), breaking the deadlock so the agent's retry loop works.
- **Data Integrity**: Enforces fast-forward-only reconciliation, completely avoiding the destructive clobbering detailed in order 301.
