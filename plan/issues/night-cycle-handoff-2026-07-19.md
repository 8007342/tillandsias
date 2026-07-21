# Overnight cycle handoff — 2026-07-19 (Linux, unattended)

- **Status**: complete; 24 commits on `linux-next`, both gates green
- **Operator**: Tlatoani (asleep for the duration; full autonomy granted)
- **Branch**: `linux-next`, head `ce885097`

## Read this first

Two **data-loss paths** were live in the forge and are now closed. Both were
described in their packets as ordinary breakage, and both turned out to destroy
repository contents. Neither was found by reading code.

1. **Absent `.git/index` → mass-deletion commit.** With no index, git reports
   every tracked file as staged-deleted AND untracked, and `git commit -am`
   commits the deletion of the entire tree. The working tree still holds every
   file, so nothing looks wrong locally — and the mirror relays that commit to
   GitHub. Reachable on **every WSL2 and macOS guest launch**, because those
   guests ship no git binary and the facade builder took a fail-open escape.
   The escape promised "in-container materialization"; nothing ever implemented
   it. Fixed: `ensure_forge_git_index` rebuilds from HEAD on all five lanes.

2. **Copied `packed-refs` → orphaned history.** `objects/` and `refs/` are
   bind-mounted live, but `packed-refs` was copied point-in-time. A routine host
   `git gc` packs loose refs away and deletes the loose files; the shared
   `refs/` empties while the stale copy predates the pack. The container loses
   every ref, then sees tracked files as untracked, then commits an **orphaned
   root commit**. auto-gc makes this a silent, routine trigger. Fixed:
   `packed-refs` is now mounted live.

Both are guarded by litmus tests that **reproduce the hazard** before proving
prevention. A guard that cannot demonstrate the failure it prevents is not
evidence.

## Decisions waiting on you

| Order | Decision |
| --- | --- |
| **437** | `/home/forge/src` is a host bind mount; BOTH `forge-hot-cold-split` and `forge-offline` forbid that (tmpfs + clone-only). Fixing it changes your workflow — agent edits would reach the host only via commit+relay, not directly. It is also what still makes concurrent workers unsafe. |
| **435** | `forge-offline` says "forge containers carry ZERO credentials", but `HOMEBREW_GITHUB_API_TOKEN` is injected for brew attestation, against a real operator repro. Amend the spec, scope the injection, or drop it and accept anonymous brew. Same drift exists on `tillandsias-vault` R6. |
| **431** | BLOCKED, deliberately. `OPENCODE_AUTH_CONTENT` is undocumented and falls back to disk **silently**; the forge installs `opencode-ai@latest` every launch. Your own code says "@latest is structurally unsafe without a survival path". Unblock by pinning the version, or by asserting post-launch that injection actually took effect. |
| **319 EC3** | GitHub App installation tokens: adopt or reject. Research is written and recommends them over a PAT. Only the decision is missing. |
| **440** | Plan ledger uses 11 status values with three synonym pairs; `index.yaml` and `schema.yaml` disagree about the vocabulary. |

**Also: rotate the `gho_` token** (`gh auth refresh`). A research agent invoked
`git credential fill`, which printed a live token into its transcript. Local
only, nothing pushed, but treat it as exposed.

## The architecture question you asked

**Do not re-architect the git mirror.** The synchronous `pre-receive` relay is
the shape GitLab officially documents for bidirectional mirroring, and our
`--atomic` whole-transaction relay is stronger than their published per-ref
sample. No off-the-shelf tool does synchronous push-through with server-held
credentials — Gitea, Forgejo, GitLab push-mirrors and Gerrit replication are all
**asynchronous**, acking the client before GitHub has seen the push, which is
the exact false-success class we already had a P1 on. Adopting one would be a
regression. Full reasoning and citations:
`plan/issues/git-mirror-architecture-decision-2026-07-19.md`.

The original blocker was **one missing refspec**: `git fetch <url>` with no
refspec updates zero refs while reporting success, so the mirror's exported
heads could never advance and an agent's fetch/rebase/retry loop could never
converge. That is what BigPickle was stuck in.

## What is done vs. what only looks done

CLOSED and verified: 422, 425, 430, 432, 433, 434, 436, 438, 439.
PARTIAL, with remaining work written into each packet: 423, 424, 426, 427, 428, 429.

**Not proven live** — treat as unverified until a real forge session exercises
them:

- 427/428 — instance-scoped names and per-worker state are unit-tested only.
  Nothing has launched two real workers on one project.
- 429 — the outcome parser is wired and mutation-tested, but no delegated run
  has been exercised end to end through a container.
- 424 — the credential helper is verified in-image and rotation is proven, but
  no real push has gone through it to GitHub.
- 384 — the mirror image is rebuilt and correct, but no mirror container is
  running; the reconcile is fixture-proven, not deployment-proven.

That last distinction is the night's most reusable lesson: the order-414 Vault
renewer passed its litmus while the running container served a pre-414 image for
days. **A fixture proves the logic; only a live probe proves the deployment.**

## Method note, if it is useful

Every packet worked from tonight had its framing wrong in some way — including
the ones written tonight:

- "reads the token once at startup" → reads per push
- "agents cannot commit" → agents commit a mass deletion
- "3 of 5 configs broken" → 3 healthy local-only projects
- "container loses refs" → container orphans history
- "two specs are incompatible" → the two specs agree; the code is the outlier
- "4 hacks removable now" → 2 had live consumers and would have broken things

None were bad packets. They were summaries, and summaries lose exactly the
detail that separates a harmless failure from a repository-destroying one. The
correction each time was cheap: run the thing and watch.

Three mistakes in this cycle were the author's own, and each was caught the same
way — by checking the result rather than the exit code. The last one is the
clearest: a commit here claimed to record a plan event, `check` passed, and the
event had landed in the wrong list. Detected only by parsing the ledger back.

Your `/advance-work-from-plan` agents read these packets as instructions. That
is the argument for orders 425 (fail-loud invariant) and 438 (transient-state
sweep) being the organising principle of v0.4 rather than items within it.
