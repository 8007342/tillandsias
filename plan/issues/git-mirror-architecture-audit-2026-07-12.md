# Git-mirror architecture audit — SIMPLICITY: DEFAULTS OVER CONFIGURATION

- Date: 2026-07-12
- Class: research (work packet — order 315, multi_cycle)
- Filed by: linux_mutable coordinator, operator directive (The Tlatoāni)
- Executor: heaviest available agents (Fable / Opus tier), coordinated from
  linux_mutable

## Operator directive (verbatim intent)

The whole git-mirror architecture is due a full audit. Back it with facts and
cheatsheets with rightful provenance. Guiding principle: **SIMPLICITY —
DEFAULTS OVER CONFIGURATION**. Minimize the environment parameters being
chucked around; they get polluted and aren't compatible across runtimes
(Linux podman forge, macOS VM forge, WSL2, host shells). The git mirror must
not be "hacking scripts because it works" but grounded in enterprise best
practices for git mirrors and distributed concurrent teams — the end user
will eventually work in a team, and Tillandsias should be the best tool for
that.

## Evidence base (all filed 2026-07-08 → 2026-07-12; read before auditing)

P1 class — the mirror's trust contract is broken from the inside:

- `git-mirror-push-false-success-not-relayed-2026-07-12.md` — mirror acks a
  push, updates tracking refs (strongest "it worked" signal), never relays to
  GitHub; recovered only by host-side push. The credential-channel guard
  accepts `TILLANDSIAS_HOST_KIND=forge` on the mirror's transparency promise,
  so a lying mirror silently voids every forge exit contract.
- `git-mirror-fetch-clobbers-exported-ref-2026-07-12.md` (orders 301/302) —
  reconcile fetch under `+refs/*:refs/*` raced/reverted just-received refs;
  code and live image deployment were verified complete on 2026-07-13.
- `mirror-pre-receive-openspec-yaml-reject-2026-07-12.md` — reject path is
  loud while the accept path can silently drop; asymmetric failure semantics.

Credential / config-surface class:

- `forge-mirror-insteadof-missing-2026-07-12.md` — macOS forge had NO
  insteadOf rewrite (Linux injects it via write_forge_gitconfig +
  GIT_CONFIG_GLOBAL bind-mount; macOS lane never got the equivalent), so the
  agent hand-configured `.git/config` — which lives on the SHARED HOST
  CHECKOUT bind-mount and poisoned the host's git config (the "insteadOf
  host-poisoning" addendum in 258327d6). Host .git credentials/config and
  forge git state are overlapping in both directions.
- `forge-credential-guard-push-channel-gap-2026-07-08.md` — guard passes on
  host-kind alone without verifying the channel actually delivers.
- Env-param sprawl (the pollution the operator calls out), current inventory:
  GIT_CONFIG_GLOBAL, GIT_SSL_CAINFO, SSL_CERT_FILE, REQUESTS_CA_BUNDLE,
  NODE_EXTRA_CA_CERTS, GH_TOKEN/GITHUB_TOKEN, TILLANDSIAS_HOST_KIND,
  git identity env pairs, insteadOf rewrites (image-injected on Linux,
  hand-hacked on macOS), tmpfs quarantines at ~/.ssh + ~/.config/gh,
  repo-local .gh-credentials, core.hooksPath overrides
  (forge-global-hookspath-shadows-repo-hooks-2026-07-12.md), plus the
  per-runtime divergence between podman/VM/WSL transports.

## Audit charter

1. **Facts first**: map the ACTUAL current architecture end-to-end (host tray
   → enclave mirror container → GitHub; all three platforms; every config
   injection point, env var, hook, and credential path). Produce a provenance
   -cited map: every claim traces to a file:line, commit, or reproduced
   command output.
2. **Best-practice baseline**: research how enterprise git mirroring and
   distributed concurrent teams actually solve this (git's own documented
   primitives first: credential helpers, `credential.helper` store/cache/
   OS keychains, `git-credential` protocol; bare mirrors + `--mirror`
   semantics; `receive.denyNonFastForwards`; pre/post-receive relay patterns
   with durable acks; Gerrit/GitLab-mirror/`git-repo` prior art). Cite
   sources with provenance (URL + retrieved date) in cheatsheets.
3. **Gap analysis under DEFAULTS OVER CONFIGURATION**: for each env var /
   injected config / hack, answer: what git-native default or helper makes it
   unnecessary? Target: a forge where `git push` just works with ZERO
   Tillandsias-specific env vars inside the container, credentials never
   exist inside the forge, and the mirror never acks what it cannot durably
   relay.
4. **Proposal**: a simplified target architecture + staged migration ladder
   (flag→soak→default→remove per migration discipline), each rung with a
   verifiable closure (litmus/fixture). Explicitly evaluate proper git
   credential helpers vs the current script mesh.

## Deliverables

- `cheatsheets/git-mirror-architecture-audit.md` — the fact-backed current
  -state map with provenance.
- `cheatsheets/git-mirror-enterprise-practices.md` — sourced best-practice
  baseline (every source: URL/man-page/commit + date).
- Gap analysis + target architecture appended to THIS issue.
- Child ready packets in plan/index.yaml for each migration rung.

## Exit criteria (completion gate: multi_cycle, verify per rung)

- Both cheatsheets exist with provenance on every load-bearing claim.
- Every current env var / config injection is dispositioned: keep (justified),
  replace-with-default, or delete — no "unknown" rows.
- Mirror ack semantics are specified: no success signal without durable relay
  state, pinned by a litmus that fails on ack-without-relay.
- Host/forge git-config isolation is bidirectional: forge cannot write host
  .git/config; host credentials/config cannot leak into forge (fixture).
- Child packets filed for the migration ladder.

## Current completion matrix (2026-07-14)

| Gate | State | Evidence / remaining owner |
|---|---|---|
| Current-state map and provenance | PASS | Audit refreshed through linux-next `6a5af9a2`; resolved pre-receive and live-image findings corrected. |
| Enterprise best-practice baseline | PASS | Bundled enterprise-practices cheatsheet retains source URL/man-page and retrieval provenance. |
| Explicit variable/config disposition | PASS | Audit section 6 assigns every section-4 variable `keep-justified`, `replace-with-default`, or `delete`; no unknown rows remain. |
| Relay-verified acknowledgement litmus | PASS | Order 318: missing credential rejects the client ack; success converges; multi-ref rejection is atomic. |
| Bidirectional config-isolation fixture | OPEN | Order 321 (`forge-git-config-quarantine`). |
| Migration child packets | PASS | Orders 318-322 are filed with staged deliverables and verification gates. |
