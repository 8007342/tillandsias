# GitHub App for fine-grained interaction + temporary elevated tokens (2026-07-31)

Classification: `research/` — deliverable for plan order **390**
`github-app-fine-grained-interaction-research` (v0.7, `web-share-release-milestone`).
Research and design only. **Nothing here is implemented, and nothing here is
authorized work.** The decision record in §7 is the artifact the operator signs;
until it is signed this file is analysis, not policy.

Evidence discipline used throughout:

- **[DOCS]** — asserted by GitHub's or HashiCorp's own documentation. URL in §10.
- **[REPO]** — verified by reading this checkout on branch `linux-next`,
  2026-07-31. Cited by symbol/file, not by line number, because
  `crates/tillandsias-headless/src/main.rs` was being edited by a concurrent
  agent during this research and line numbers shifted ~39 lines mid-session.
- **[UNVERIFIED]** — believed but not proven. Every one of these is also listed
  in §9 so none of them can be quietly promoted to fact later.

Where a claim's truth depends on *which machine* the code runs on, that is said
explicitly. This repository has been bitten repeatedly by "verified where it was
written is not verified where it runs," and §4 shows that failure mode is
currently load-bearing on exactly the invariant this packet must design against.

---

## 1. Executive summary

**Recommendation: adopt a private GitHub App as the machine identity for
repository-facing automation — and reject it as the fix for the
`HOMEBREW_GITHUB_API_TOKEN` injection.** Those are two different problems and
conflating them would produce a design that is worse than either fix alone.

Three findings drive that split:

1. **The App model is a real improvement for anything Tillandsias itself does to
   its own repository** — mirror push, release dispatch, stable promotion. It
   replaces a non-expiring, user-scoped, broadly-scoped OAuth token with a
   1-hour token that can be minted per-operation with a per-operation permission
   set and revoked immediately after. [DOCS]

2. **The App model cannot replace the forge-lane injection**, because an
   installation access token "cannot be granted access to repositories that the
   installation was not granted access to" [DOCS], and the thing the forge lane's
   token is actually consumed by — Homebrew bottle attestation verification —
   queries repositories owned by Homebrew, not by us. Swapping a PAT for an App
   token in that env var would break the very repro that motivated the injection
   (order 359) while leaving a readable credential in the lane. Worse trade.

3. **The invariant this packet must preserve is not currently enforced where the
   code runs.** §4 verifies that the "forge containers have zero credentials"
   claim is guarded almost entirely by greps over host-side source text, that the
   strongest such grep targets a module with no production consumers, and that
   the one genuinely runtime-level test proves a different property (Vault ACL)
   than the one at issue (possession). Designing "App tokens, invariant
   preserved" on top of that would be designing against a claim, not a fact.

The operator's framing is the correct one and is adopted here without
qualification: **the credential's presence in the forge is itself the exposure.**
§4.4 shows this is not a philosophical position — the injected token is
reachable, usable, and leaks through a second channel the code comments deny.

---

## 2. Permission model: App vs classic PAT vs fine-grained PAT

### 2.1 What each thing actually is

| | Classic PAT | Fine-grained PAT | GitHub App installation |
|---|---|---|---|
| Identity it acts as | the user | the user | **its own** — "can also act independently of a user" [DOCS] |
| Lifetime | optional expiry; may be non-expiring | max lifetime policy defaults to 366 days for orgs | **1 hour** [DOCS] |
| Repo scoping | scope-wide (`repo` = all repos the user can reach) | explicit repo list | explicit installation, further narrowable per token via `repositories`/`repository_ids` (up to 500) [DOCS] |
| Permission scoping | coarse OAuth scopes | per-resource read/write | per-resource read/write, **plus per-token down-scoping** via the `permissions` body parameter [DOCS] |
| Org control | none beyond scope | org may require admin approval per token (default) [DOCS] | org owner or repo admin installs and approves permission changes [DOCS] |
| Seat cost | user's seat | user's seat | **"GitHub App bots do not consume a GitHub Enterprise seat"** [DOCS] |
| Rate limit | 5,000/hr user budget | 5,000/hr user budget | 5,000/hr minimum, scaling +50/repo and +50/user, **capped at 12,500/hr** [DOCS] |
| Survives the human leaving | no | no | yes |
| Revocation | delete the token | delete the token | `DELETE /installation/token` — "once an installation token is revoked, the token is invalidated and cannot be used" [DOCS] |

### 2.2 What an App can scope that no PAT can

These are the concrete, non-marketing differences that matter for this codebase:

- **Per-mint down-scoping.** A PAT's permissions are fixed at creation. An
  installation token's are chosen *at mint time*: the same App can hand out a
  `{contents: write}` token for a mirror push and, ninety seconds later, an
  `{actions: write}` token for a release dispatch, from the same key, with no
  second credential to store. [DOCS] This is the single property that makes a
  "temporary elevated token for promotions" expressible at all. A PAT-based
  version of the same flow requires N stored PATs, one per privilege level —
  i.e. N long-lived secrets to protect instead of zero.

- **Down-scoping to a repository subset at mint time**, independent of the
  installation's own repo list. [DOCS] A PAT can be scoped to repositories only
  when it is created.

- **Identity that is not a person.** Actions attributed to an App bot are
  attributable to the automation, not to `@tlatoani`. For a product whose stated
  posture is "we cannot let users risk things they don't understand"
  (`plan/issues/operator-vision-ai-cloud-region-2026-07-31.md`, cited as CONTEXT
  only), a credential that can only ever do what the automation is permitted to
  do — rather than everything its human owner can do — is a category change, not
  an increment.

- **Bounded blast radius in time by construction.** An App token that leaks is
  useless in ≤1 hour, and can be made useless immediately by revocation. A leaked
  PAT is useful until a human notices. This is the property that makes token
  presence in a log, a core dump, or a container env *survivable* rather than
  *incident-grade*.

- **Triggering downstream workflows.** "Events triggered by the `GITHUB_TOKEN`
  will not create a new workflow run"; the documented workaround is "a GitHub App
  installation access token or a personal access token." [DOCS] A promotion flow
  that must kick a downstream workflow cannot use the ambient `GITHUB_TOKEN`.

### 2.3 Where the App model is *worse*

This section exists because the packet asked for an evaluation, not a pitch.

- **It introduces a new highest-value secret where there was none.** Today the
  worst credential in the system is a `gh` OAuth token: bad, but replaceable in
  one `gh auth login` and bounded by one user's permissions. An App private key
  is *persistent authentication as the App* [DOCS] — see §3.3. The App model
  trades many short-lived low-value tokens for one long-lived high-value key.
  That is usually a good trade, and it is only a good trade if the key custody is
  genuinely better than the credential it replaces. If the key ends up in a file
  next to the code, the App model is a strict downgrade.

- **More moving parts on the critical path.** The current mirror push reads one
  KV path and hands the value to git. The App version needs: read App metadata →
  build a JWT → sign it (RS256) → `POST /app/installations/{id}/access_tokens` →
  parse → hand to git → optionally revoke. Six steps that can fail, on the
  hottest path in the system, in a codebase whose own analysis names *silent
  degradation* as "the cross-cutting defect"
  (`plan/issues/git-mirror-architecture-decision-2026-07-19.md`). Every one of
  those steps must fail loud or the App model actively makes the system worse.

- **Offline is now a hard dependency.** A static PAT works as long as GitHub
  works. An App token cannot be minted without reaching `api.github.com` first.
  Any flow that could previously push after a transient API outage now cannot.

- **The 1-hour TTL is not configurable.** [DOCS] Long operations must handle
  mid-flight expiry. Git pushes are short; a long `git clone` of a large repo or
  a multi-hour workflow is not.

- **It does not constrain the human.** The packet framing says an App "gives
  fine-grained control over what a user may do in GitHub." That is true *only for
  actions taken through the App*. A user access token issued by an App "only has
  permissions that both the user and the app have" [DOCS] — the App can
  **narrow** a user, never expand and never restrain them elsewhere. The same
  user with their own browser session is entirely unaffected. If the intent is to
  stop a user (or an agent acting as one) from doing something in GitHub, the App
  is the wrong lever; branch/tag protection rules and org policy are the right
  ones. Recording this because building the wrong mechanism for this goal is a
  likely and expensive mistake.

- **Enterprise-level resources are out of reach.** "A GitHub App cannot yet be
  given permissions against an enterprise." [DOCS] Not relevant today; relevant
  if the multi-node vision ever acquires an org/enterprise shape.

- **Permission changes require re-approval.** Adding a permission after
  installation prompts the account owner, and "if the account owner does not
  approve the new permissions, their installation will continue to use the old
  permissions." [DOCS] Silent partial upgrades across a fleet of installations
  are therefore possible — a class of failure that does not exist with a PAT.

### 2.4 Fine-grained PAT: the honest middle option

A fine-grained PAT gets ~80% of the repo/permission scoping for ~5% of the work:
no key custody, no JWT, no minting service. What it does not get: expiry measured
in hours rather than months, per-operation down-scoping, seat independence,
survival of the owning human, or non-person attribution. It remains a *user*
credential, so it inherits every property of the user — including dying when the
account does.

For a single-operator repository it is a defensible choice and it should not be
dismissed. For the stated long-range posture (many nodes, non-technical users,
"frozen control plane") it is a dead end, because it cannot express "this
principal, for this purpose, for ten minutes" — the same argument the operator
already accepted for SSH certificates over `authorized_keys` in order 322.

---

## 3. Short-TTL installation tokens

### 3.1 How one is minted [DOCS]

1. Build a JWT. Required claims `iat`, `exp`, `iss` (client ID or app ID).
   Signed with **RS256**. `exp` may be "no more than 10 minutes into the future."
2. `POST /app/installations/{INSTALLATION_ID}/access_tokens` with
   `Authorization: Bearer <JWT>`.
3. Optional body parameters narrow the result:
   - `repositories` / `repository_ids` — "up to 500 repositories"
   - `permissions` — "the permissions that the installation access token should
     have"; omitted means "all of the permissions that were granted to the app."
4. Response carries the token (`ghs_…`) and its expiry.

Two hard limits, both from GitHub's docs: "The installation access token cannot
be granted access to repositories that the installation was not granted access
to" and "cannot be granted permissions that the app was not granted."

### 3.2 Lifetime, refresh, revocation [DOCS]

- **Lifetime: exactly 1 hour.** Not configurable.
- **There is no refresh.** "Refreshing" means repeating §3.1 from the JWT
  onward. This is architecturally important: the *only* durable secret in the
  whole flow is the private key. Everything else is derived and disposable.
- **Revocation exists:** `DELETE /installation/token` invalidates the token used
  to make the call. GitHub's own `actions/create-github-app-token` revokes in its
  post-job step by default, with `skip-token-revoke` to opt out. [DOCS] Mint →
  use → revoke should be the default shape here too; the window then measures in
  seconds, not an hour.
- (For completeness, the *user*-facing token type is different: App **user**
  access tokens default to 8 hours with a 6-month refresh token, and expiry is
  currently optional. [DOCS] Not proposed for use here.)

### 3.3 The private key — where it lives and what its compromise costs

This is the load-bearing risk of the whole proposal and it should be the first
thing the operator interrogates.

**What GitHub says** [DOCS]:

- Keys are generated *by GitHub* and downloaded in PEM (PKCS#1) form. Up to 25
  keys per App; "you should use multiple keys in order to rotate keys without
  downtime in the event of a key compromise."
- Storage guidance is explicit: store it "in a key vault, such as Azure Key
  Vault, and making it sign-only," and "you should not hard-code your private key
  in your app, even if your code is stored in a private repository." Environment
  variables are called out as weaker.
- Compromise cost, in GitHub's own words: an attacker who can read the key "can
  read the private key and gain **persistent authentication as the GitHub App**."
- Recovery is possible but not free: "you can remove a lost or compromised
  private key by deleting it, but you must regenerate a new key before you can
  delete the existing key."

**What that means concretely for Tillandsias.** Anyone holding the key can mint
installation tokens for every account the App is installed on, with the full
permission set of each installation, indefinitely, without touching the
operator's account and without appearing in the operator's own token list. It is
strictly worse than the current `secret/github/token` in blast radius, and
strictly better in exposure surface — *if and only if* the key is never readable.
If the key is stored as a readable Vault KV secret, the App model has
concentrated risk without reducing it.

**Recommended custody: HashiCorp Vault's Transit engine, sign-only.** This is a
direct match for GitHub's own advice, using an engine already deployed here:

- Transit supports `rsa-2048`/`3072`/`4096` and RSA signing with
  `signature_algorithm=pkcs1v15` + `hash_algorithm=sha2-256` — which is exactly
  RS256, the only algorithm GitHub accepts. [DOCS]
- Keys are **non-exportable by default**; `exportable` defaults to `false` and
  "once set, this cannot be disabled." [DOCS]
- Transit supports **BYOK import**, which is required here because GitHub
  generates the key, not us. [DOCS]

Under this shape, a `transit/sign/github-app` grant lets the holder produce App
JWTs but never lets anyone — including the tray, including a Vault operator with
that policy, including a stolen Vault token — read the key material. The key
never exists in a readable secret path.

Three caveats, stated rather than buried:

1. **Vault flags `pkcs1v15` as "a legacy padding scheme with security
   weaknesses."** [DOCS] We have no choice: GitHub requires RS256. Record it as
   an accepted, externally-imposed constraint, not an oversight.
2. **There is an unavoidable exposure window at import.** GitHub only lets you
   *download* a generated key; there is no CSR/upload path, so the PEM
   necessarily exists on the operator's machine (browser download → disk) before
   it reaches Transit. The mitigation is procedural: import immediately, shred
   the file, and rotate the key once from within the system so the key that is
   long-lived is one that never touched a browser. The 25-key allowance makes
   that cheap.
3. **Whoever can call `transit/sign` on that key holds App-level authority.** A
   JWT is not scoped — with it you can mint *any* installation token the App is
   entitled to. Therefore signing capability cannot be handed out per-caller as a
   way of expressing privilege levels. See §6.3; this constraint determines the
   whole broker architecture.

---

## 4. The forge-zero-credential invariant, as it actually exists today

Verified before designing against it, per the packet's instruction. This section
is [REPO] throughout.

### 4.1 Where the invariant is stated

The string `forge-zero-credential` **is not a registered invariant ID.** It
appears only as prose in `plan/index.yaml` (in this packet's own outcome text and
one other). The real statements are:

- `openspec/specs/forge-offline/spec.md` — Purpose: *"Forge containers operate
  offline -- no credentials, no project mounts, no direct internet."* Requirement
  heading: *"Forge containers have zero credentials."* Requirement body: *"Forge
  containers SHALL NOT have any credential **mounts**."* Scenario: *"the
  environment SHALL NOT contain `GIT_ASKPASS`, `ANTHROPIC_API_KEY`, or
  `GH_TOKEN`."* Note the gap: the absolute claim lives in the heading and the
  purpose line; the normative sentence is about *mounts*, and the env clause is
  an explicit three-name list.
- `openspec/specs/git-mirror-service/spec.md` — the strongest wording: *"No
  AppRole value, Vault token, GitHub token, D-Bus socket, keyring API,
  bind-mounted token file, or askpass helper SHALL cross into a forge container
  or appear in process arguments, environment variables, or logs."*
- `openspec/specs/tillandsias-vault/spec.md` — `…security.forge-offline@v2` has
  **already been narrowed** from "zero Vault tokens" to *"SHALL NOT receive a
  **broad** Vault token"*, plus
  `tillandsias-vault.invariant.forge-policy-has-no-token-read`.
- `openspec/specs/podman-idiomatic-patterns/spec.md` — invariant
  `…invariant.secrets-not-in-env`: *"passing them as `-e` environment variables
  is PROHIBITED"*; and `…invariant.forge-capability-only`.
- `openspec/specs/security-privacy-isolation/spec.md` — *"Zero-tolerance
  credential boundary."*
- `images/vault/policies/forge.hcl` — *"Explicitly NO github or token access —
  forge containers must remain credential-free for everything beyond TLS trust."*
- `methodology/convergence.yaml` `forbidden_shortcuts` includes *"host
  credential/config mounts into a forge container"*;
  `methodology/forge-diagnostics.yaml` disallows *"exposing host credentials or
  GitHub tokens to the forge."* `methodology.yaml`'s `invariant_summary` has **no**
  forge-credential entry.

### 4.2 Where the invariant is enforced — and where that enforcement runs

This is the part that matters for designing against it.

| Mechanism | Subject | Runs where | Actually proves |
|---|---|---|---|
| `litmus:credential-isolation` — the litmus **bound to** forge-offline's zero-credential gating point | the GitHub *login* flow | `backend: fake`, a podman **mock** | Nothing about a forge container. Asserts `gh auth login`, `gh auth token`, and `vault-cli write secret/github/token` appear in a mock call log. |
| `litmus:forge-offline-profile-shape` | `crates/tillandsias-core/src/container_profile.rs` | `grep` over host-side **source text**, pre-build | That a declarative profile module contains `secrets: vec![]` and no credential env names. **That module has no production consumers** — the real launch path is `main.rs::build_forge_agent_run_args_with_vault` / `build_opencode_forge_args`, which never touch it. The primary gate greps a layer that launches nothing. |
| `litmus:vault-policy-forge-cannot-read-github-token` | Vault ACL | **live Vault in the VM** — genuine runtime | That a `forge-policy` token gets 403 on `secret/github/token`, with an audit record. True and valuable — and orthogonal. It guards the *fetch* path, not *possession*. |
| `litmus:environment-isolation` | forge **image** env | runtime, but `podman run --rm --entrypoint /usr/bin/env $FORGE_IMAGE` with **no launch args** | Only the env baked into the Containerfile. Every variable the tray injects at launch is structurally invisible to it. This is the test that *looks* like a runtime proof of "no credential env in the forge" and is not. |
| `litmus:forge-secret-capability-contract` | `main.rs` source | `grep`/`awk`, pre-build | The most honest gate in the repo: it budgets a known deviation at ≤2 matching lines. But its matcher is `-e '.env(p.env_var()' -e 'GOOGLE_GENERATIVE_AI_API_KEY'` — **`spec.env("HOMEBREW_GITHUB_API_TOKEN", …)` matches neither**, so the GitHub-token injection is invisible to the deviation budget. |
| unit test `github_token_injected_as_env_host_side_never_argv` | `main.rs` source, via `include_str!` of itself | host compile-time | **It asserts the injection exists.** It is a pin protecting the deviation, not a guard against it. |
| `policy.rs::forge_policy_does_not_mention_github_token` and siblings | embedded HCL vs `images/vault/policies/*.hcl` | host, compile/test time | Real drift protection between client and image policy. Says nothing about the running Vault (that's the litmus above) and nothing about possession. |

**Conclusion: no test anywhere inspects the environment of an actually-launched
forge lane.** No `podman inspect <forge> --format '{{.Config.Env}}'`, no
`podman exec <forge> env`. The headline invariant is enforced by source greps,
and the strongest one targets dead code.

### 4.3 Where it is contradicted

Everything a forge agent lane receives today that carries credential bytes, from
`build_forge_agent_run_args_with_vault`:

- `ANTHROPIC_API_KEY` (Claude lane) — **named verbatim** in
  `forge-offline/spec.md`'s forbidden-env scenario.
- `OPENAI_API_KEY` / `CODEX_API_KEY` (Codex lane), `GEMINI_API_KEY` +
  `GOOGLE_GENERATIVE_AI_API_KEY` (Antigravity lane).
- `HOMEBREW_GITHUB_API_TOKEN` — **every** lane, all five modes, because brew is
  present in all of them.

The provider keys are formally recorded as
`podman-idiomatic-patterns.deviation.agent-forge-api-key-in-env`, observed
2026-07-28. The GitHub token is not recorded as a deviation anywhere; it is
tracked as spec drift in `plan/index.yaml` order **435**
`forge-credential-spec-reconciliation`, `status: needs_clarification`, awaiting
an operator decision between (1) amend the spec, (2) scope the injection to lanes
where brew runs, (3) remove it and accept anonymous brew.

By contrast the raw OpenCode lane (`build_opencode_forge_args`) carries **no**
credential env at all: it mounts a scoped Vault capability and the entrypoint
assembles `OPENCODE_AUTH_CONTENT` in-container. That lane is the conforming
reference implementation and the proof that the correct shape is already
achievable here.

### 4.4 The worked example, verified: what `HOMEBREW_GITHUB_API_TOKEN` actually exposes

The operator's framing — *presence is the exposure* — is not an abstraction. Four
verified facts:

1. **The value is a broad user credential, not a narrow machine one.**
   `secret/github/token` is written by the one-shot GitHub-login container as
   `gh auth token` piped into `vault-cli write-stdin` (`main.rs` github-login
   path; `litmus-vault-github-token-capture-shape.yaml`). `git-mirror.hcl`'s own
   comment calls it "the GitHub OAuth token." It carries whatever the `gh` CLI's
   OAuth grant carries for that user — not a scoped, purpose-built credential.

2. **A lane holding it can use it.** The enclave network is created
   `--internal` (no NAT egress, no external DNS), so a forge cannot reach GitHub
   directly — but every lane is given `http_proxy=http://proxy:3128`, and
   `images/proxy/allowlist.txt` allows `.github.com`, `.githubusercontent.com`
   and `.ghcr.io`. So the token is not merely present; it is **live**. A lane can
   authenticate to `api.github.com` right now.

3. **It leaks through a second channel the code comment denies.** The comment at
   the injection site reads "never on disk, never in argv."
   `ContainerSpec::build_run_args` in
   `crates/tillandsias-podman/src/container_spec.rs` emits, for every env entry,
   `--env` followed by `format!("{key}={value}")`. The raw token is therefore an
   argv element of the `podman run` process — visible in `/proc/<pid>/cmdline`
   and in `podman inspect` for the lane. On Linux that is the **host**; on macOS
   and Windows podman runs inside the guest VM, so the exposure is in the guest.
   Either way it is outside the forge and outside what the comment claims. This
   is already acknowledged for the provider keys in
   `podman-idiomatic-patterns.deviation.agent-forge-api-key-in-env` — the GitHub
   token has the same defect and no deviation record.

4. **The repo already condemned this exact pattern, elsewhere, and fixed it
   there.** `images/git/git-credential-tillandsias.sh`'s header explains that the
   old relay built `https://oauth2:${TOKEN}@github.com/...` and passed it in
   argv, "readable by anything sharing the namespace," and that this "contradicts
   an invariant this repository states explicitly elsewhere." Order 424 fixed the
   mirror. The forge-lane launcher still does the thing the mirror was fixed for.

**What the App-based replacement for that specific injection would look like —
and why it is the wrong fix.**

The literal swap would be: instead of `vault_kv_get_via_exec("secret/github/token")`,
have the host mint a 1-hour installation token scoped to `{contents: read}` on
`repository_ids=[<tillandsias>]` and inject *that* as
`HOMEBREW_GITHUB_API_TOKEN`. It would be a real improvement in one dimension
(a leaked value dies in an hour instead of never) and **it would not work**,
because:

- brew's attestation verification reads attestations from Homebrew-owned
  repositories, and "the installation access token cannot be granted access to
  repositories that the installation was not granted access to" [DOCS]. Our App
  will never be installed on `Homebrew/*`. Whether an installation token retains
  *any* implicit read of unrelated public repositories is **[UNVERIFIED]** and is
  listed in §9 — but the documented rule points the wrong way, and designing on
  the hope that it doesn't apply would be exactly the kind of unverified
  assumption this packet is supposed to avoid.
- it would still put a readable credential in the lane's env and in the podman
  argv. Shortening a leak's lifetime is not the same as not leaking.

**Therefore the recommendation for this specific injection is not "App token."**
It is, in preference order:

- **(A) Scope it out of existence.** Move brew's authenticated work to image
  build time, where a build-time credential is already accepted practice
  (`scripts/build-image.sh` already reaches for `gh auth token` for
  `cargo-binstall`), and let the runtime lane run brew anonymously or not at all.
  This satisfies order 435's option (2)/(3) without a security-posture trade.
- **(B) Mediate at the proxy.** The squid proxy is already the sole egress path
  and is already dual-homed. A broker that attaches `Authorization` on the lane's
  behalf would give the lane the *capability* without the *credential* — the
  exact "capability, not credential" distinction
  `podman-idiomatic-patterns/spec.md` already codifies. **Cost, stated honestly:**
  `images/proxy/squid.conf` currently bumps exactly one host
  (`release-assets.githubusercontent.com`) and its comment says "APIs, raw
  content, package registries, provider/auth endpoints … remain end-to-end
  spliced." Header injection for `api.github.com` requires bumping
  `api.github.com`, i.e. terminating TLS on all GitHub API traffic at the proxy.
  That is a deliberate posture change and must be decided as one, not slipped in.
- **(C) Accept and record.** Keep the injection, file the missing deviation
  record, and extend `litmus:forge-secret-capability-contract`'s budget matcher to
  actually count it. This is the minimum honest outcome even if (A) or (B) is
  chosen later, because today the violation is not merely unrecorded — it is
  invisible to the gate designed to catch it.

Order 435 owns that decision. This packet's contribution to it is a **fourth
option that did not previously exist** (B), plus the finding that the App model
is *not* option (D).

---

## 5. Webhook events, against a deliberately network-isolated posture

### 5.1 The events that matter for hooks/actions/workflows [DOCS]

| Event | Fires when | Required App permission |
|---|---|---|
| `workflow_run` | a workflow run completes | Actions: read |
| `workflow_job` | a job completes | Actions: read |
| `check_run` / `check_suite` | a check/suite reaches a conclusion | Checks: read |
| `deployment` / `deployment_status` | deployment created / status added | Deployments: read |
| `deployment_protection_rule` / `deployment_review` | environment gate requested / reviewed | Deployments: read |
| `push` | push to a branch, or tag deletion | Contents: read |
| `release` | draft saved, release/pre-release published | Contents: read |
| `registry_package` | package published/updated | Packages: read |
| `repository_dispatch` | POST to the dispatch endpoint | Contents: read |
| `status` | commit status changes | Commit statuses: read |

`deployment_protection_rule` is the interesting one for order 389: it is GitHub's
own hook for *gating* a deployment on an external decision, which is structurally
the same thing 389's evidence ladder does. If the ladder ever needs to gate a
GitHub-side deployment rather than a local one, that is the seam.

### 5.2 Why receiving them is a posture problem here

Webhooks are **push**. GitHub opens a connection to a URL you publish. The
operator's recorded vision is the opposite posture: production is *"Hosted with
NO enclave and NO network access, reached only through a native Cloudflare
tunnel"* (`plan/issues/operator-vision-ai-cloud-region-2026-07-31.md`, CONTEXT
only, not authorization). And the flagship node is *"an old computer next to a
router"* with no public address at all.

Three concrete blockers, all [DOCS]:

1. **GitHub's own documented answer for a non-public receiver is a third-party
   proxy.** The testing guide directs you to **smee.io**: "when your webhook
   proxy URL (smee.io URL) receives a webhook delivery from GitHub, smee will
   forward the webhook delivery to your local server." Every payload would
   transit a third party. For a product whose pitch is isolation, that is not a
   deployment option; it is a documented development convenience.
2. **A GitHub App has exactly one webhook URL.** The registration form has a
   single "Webhook URL" field. So a fleet of Tillandsias nodes cannot each
   receive the App's events; there would have to be one rendezvous endpoint that
   every node depends on — a central, always-on, publicly-reachable component,
   which is precisely what the architecture is trying not to have.
3. **`gh webhook forward` exists and is outbound-only**, which fits the posture —
   but it is a `gh` CLI *extension* documented under "testing and
   troubleshooting," it requires a `gh` login (a **user** credential, with
   `admin:org_hook` for org webhooks), and depending on it for production
   delivery would reintroduce exactly the user-credential dependency the App is
   meant to remove.

### 5.3 Recommendation: outbound conditional polling, no listener

Poll the REST API with an installation token, using ETag / `If-None-Match`.
GitHub documents that "making a conditional request does not count against your
primary rate limit if a `304` response is returned and the request was made while
correctly authorized with an `Authorization` header." [DOCS] GitHub also
explicitly prefers webhooks — "you should subscribe to webhook events instead of
polling the API for data" [DOCS] — and that preference is about *their* load, not
about our threat model. The rate-limit objection is answered by conditional
requests; the posture objection to webhooks is not answered by anything.

Net effect: **zero inbound listeners, zero public endpoints, zero third parties**,
at the cost of latency measured in the poll interval. For promotion and release
gating — human-initiated, minutes-scale operations — that latency is free.

Revisit only if and when orders 378/388 land a Cloudflare tunnel that is already
inside the threat model, and even then, only for the enclave-hosted `dev.*`
posture, never for the no-network production posture.

---

## 6. Temporary elevated tokens for promotions and releases

### 6.1 What the promotion/release surface is today [REPO]

- `.github/workflows/release.yml` — `workflow_dispatch` only; job-level
  `permissions: contents: write, id-token: write`; uses
  `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`; signs artifacts with **Sigstore Cosign
  keyless via GitHub Actions OIDC** (`--certificate-oidc-issuer
  https://token.actions.githubusercontent.com`).
- `scripts/promote-stable.sh` — runs on the **host**, with the operator's ambient
  `gh` auth. It checks an evidence gate, then `gh release edit "$TAG"
  --prerelease=false --latest`, then force-moves and force-pushes the annotated
  `stable` tag.

Two observations that shape the design:

**The repo already runs a zero-stored-secret credential model.** Cosign keyless
signing via Actions OIDC is exactly the shape being proposed — an ephemeral,
scoped, non-storable identity minted at use time. Adopting App installation
tokens is not a new paradigm here; it is extending one that already ships.

**The evidence gate is forgeable by the agents it constrains.** The gate is:

```
grep -rIlE "(e2e|smoke).*(PASS|pass).*${VERSION_NO_V}|${VERSION_NO_V}.*(e2e|smoke).*(PASS|pass)" "$REPO_ROOT/plan/"
```

Any file under `plan/` containing that pattern satisfies it. Agents commit to
`plan/` on nearly every cycle. So an agent that wants to promote can satisfy the
gate by writing a sentence. The gate is a control-flow check in a script the
caller already controls. **This is the single most important integration point
with order 389**, and §6.4 addresses it.

### 6.2 Where the broker should live

The mirror container is the right home, and the specs already say so.
`forge-offline/spec.md`'s purpose line: *"secrets live exclusively in the git
service."* `git-mirror-service/spec.md`: *"the token never crosses into a forge
container."* The mirror is already:

- dual-homed on `tillandsias-enclave` + `tillandsias-egress` (one of only three
  containers that are — the others are the proxy and the one-shot login
  containers) [REPO],
- holding a launch-scoped AppRole in a mode-0400 podman secret, authenticating
  via **official Vault Agent auto-auth** with a file sink, and revoking on
  shutdown [REPO],
- already the sole consumer of `secret/github/token` in normal operation, via
  `git-credential-tillandsias.sh` reading it per invocation [REPO].

Putting the broker in the tray/host instead would add an outbound-network,
credential-minting code path to the process that already holds the Vault **root**
token — concentrating rather than separating authority. Putting it in a new
container adds a component. The mirror already has the network shape, the Vault
identity, the lifecycle, and the specified role.

### 6.3 The architecture, and the constraint that forces it

**Constraint (from §3.3): the ability to sign an App JWT *is* App-level
authority.** A JWT is unscoped; anyone who can produce one can mint any
installation token the App is entitled to. Therefore:

> Signing capability cannot be distributed per-caller as a way of expressing
> privilege levels. Exactly one process may hold `transit/sign` on the App key,
> and **that process is the policy decision point.** Vault policy gates *who may
> ask the broker*; the broker alone decides *what may be minted*.

Any design that hands `transit/sign` to more than one caller has no privilege
separation at all, however many Vault policies decorate it.

Sketch:

```
Vault (enclave-only container)
├── transit/keys/github-app          rsa-2048, exportable=false, BYOK-imported
│     └── grant: update on transit/sign/github-app  →  broker AppRole ONLY
├── secret/github/app/config         app_id, client_id, installation_id (metadata)
└── secret/github/app/profiles/*     the permission sets, one per profile

git mirror container (enclave + egress)
└── tillandsias-github-broker  (Rust; sole holder of the signing capability)
      ├── mint(profile, evidence?) → JWT (Transit) → POST access_tokens → ghs_…
      ├── enforces: profile → {repository_ids, permissions}
      ├── enforces: profile → evidence requirement (order 389)
      └── revokes via DELETE /installation/token after use

callers
├── git-credential-tillandsias.sh  → profile "mirror-push"
├── promote-stable.sh              → profile "promotion"     (evidence-gated)
└── release dispatch               → profile "release-dispatch" (evidence-gated)
```

Profiles, concretely:

| Profile | `permissions` | `repository_ids` | Evidence required | Typical lifetime |
|---|---|---|---|---|
| `mirror-push` | `{contents: write}` | `[tillandsias]` | none | mint → push → revoke (seconds) |
| `release-dispatch` | `{actions: write}` | `[tillandsias]` | 389 rung evidence | mint → dispatch → revoke |
| `promotion` | `{contents: write}` | `[tillandsias]` | 389 rung evidence + operator presence (open question Q5) | mint → edit + tag → revoke |
| `read-only` | `{metadata: read, contents: read}` | `[tillandsias]` | none | polling (§5.3) |

Note `mirror-push` and `promotion` request the same permission today. That is
honest: GitHub's permission granularity does not distinguish "push a branch" from
"move a tag and flip a release." The separation that *is* real is the evidence
requirement and the audit record, not the token's capability. Saying otherwise
would be security theatre. If a genuine capability split is wanted, it has to
come from **tag protection rules** on GitHub's side plus an App bypass list, not
from the token scope — see Q6.

### 6.4 Integration with order 389 — the part that actually changes something

Today: the evidence gate guards **a script**, and the credential is available
regardless. An agent that bypasses the script still has the credential.

Under this design: the evidence gate guards **the credential**. The broker is the
only thing that can mint a `promotion` token, and it refuses unless it can
independently verify the evidence. `promote-stable.sh` without a token cannot
promote, no matter what its control flow does.

That is the difference between a gate and a suggestion, and it is the same
principle already load-bearing in this codebase ("a guard only an attentive agent
honors is a suggestion, not a constraint").

For that to be real, the evidence must be something the requesting agent cannot
manufacture. A `grep` over `plan/` fails that test. Order 389 must define an
evidence artifact with at least one of: a signature the requester cannot produce,
or a fact the broker can re-derive independently (e.g. the broker itself queries
the release's checks/attestations via a `read-only` token rather than trusting a
file). **This packet does not decide 389's evidence format** — it states the
requirement 390 places on it: *evidence must be verifiable by the broker without
trusting the caller.*

It also lines up with the operator's recorded XP framing — *"XP is user lingo for
verifiable constraints"*, and the explicit warning that activity-derived XP would
be a privilege-escalation path. A broker that mints on verifiable constraints and
refuses on self-asserted ones is the same rule expressed in credentials.

### 6.5 Failure modes to design for explicitly

Named here because `plan/issues/git-mirror-architecture-decision-2026-07-19.md`
identifies silent degradation as the recurring defect class, and this design adds
five new failure points to the hottest path:

- Transit sign fails → **fail loud**, never fall back to a static token.
- `POST access_tokens` returns 401/403 → **fail loud** naming the App and
  installation; do not retry into a rate limit.
- Clock skew → JWT `exp` is capped at 10 minutes [DOCS]; a host with a skewed
  clock produces JWTs GitHub rejects, and the error will not say "your clock is
  wrong." Check skew and say so.
- Mid-operation expiry → 1 hour is not configurable; long operations must
  re-mint, not retry blindly.
- GitHub API unreachable → previously a push could succeed with a cached PAT;
  now it cannot. State this as an accepted regression, do not paper over it.

---

## 7. Decision record (for The Tlatoāni)

### 7.1 Recommendation

**ADOPT** a **private** GitHub App (installable only on the owning account) as
the machine identity for Tillandsias' own repository operations, staged as four
rungs, with the private key held **sign-only and non-exportable in Vault
Transit**, and with **exactly one process** holding the signing capability.

**REJECT** the App as the remedy for `HOMEBREW_GITHUB_API_TOKEN`. That injection
is order 435's decision and should be resolved on its own terms; §4.4 adds a
fourth option (proxy-mediated capability) to 435's existing three.

**DEFER** webhooks entirely. Use outbound conditional polling. Revisit only if
orders 378/388 produce an inbound path that is already inside the threat model.

Rungs, each independently valuable and independently abandonable:

- **R0 — no App required.** File the missing deviation record for
  `HOMEBREW_GITHUB_API_TOKEN` and fix `litmus:forge-secret-capability-contract`'s
  budget matcher so the injection is *counted*. Add one runtime assertion that
  inspects a launched lane's actual env (`podman inspect`), because today nothing
  does. This is worth doing whatever the operator decides about the App, and it
  is the precondition for honestly claiming any invariant is "preserved."
- **R1 — identity.** Register the App; import its key to Vault Transit
  (non-exportable); add `github-app-broker-policy` + AppRole; add
  `secret/github/app/config` and the profile definitions. No behaviour change.
- **R2 — mirror push.** Swap `git-credential-tillandsias.sh`'s KV read for a
  broker call with the `mirror-push` profile. **This closes order 319's EC3 with
  a decision of ADOPT.** The credential-helper protocol boundary does not move,
  so 319's EC1/EC2 evidence stays valid.
- **R3 — elevated promotion/release**, gated on order 389's evidence contract
  (§6.4). Retire the operator's ambient `gh` auth from `promote-stable.sh`.

### 7.2 Rationale

1. It replaces a non-expiring, user-scoped OAuth token — currently the highest-
   value readable secret in the system, held in `secret/github/token` and read by
   the mirror, by ephemeral `gh` containers, and injected into every forge lane —
   with tokens that die in ≤1 hour and are revoked in seconds.
2. It is the only mechanism that can express "elevated, for this operation, now,"
   which is what a promotion gate needs. PATs cannot; only per-mint down-scoping
   can. [DOCS]
3. It turns order 389's gate from a script check into a credential withhold.
4. It matches a model this repo already runs in production (Cosign keyless via
   Actions OIDC) rather than introducing a foreign one.
5. The identity survives the human. For a product intended to run unattended on
   a box next to a router, a credential that expires when a person's account does
   is a latent outage.
6. It is the same architectural bet the operator already accepted for order 322
   (SSH CA over `authorized_keys`): pay for a rotatable, short-lived, purpose-
   scoped identity now so the multi-node case extends it instead of inventing a
   second scheme beside it.

### 7.3 Rejected alternatives

| Alternative | Why rejected |
|---|---|
| **Status quo — `gh auth login` OAuth token in `secret/github/token`** | Non-expiring, user-scoped, broad; leaked value is useful until a human notices; currently injected into every forge lane. This is the thing being fixed. |
| **Classic PAT** | Same properties as the status quo with worse ergonomics. No gain. |
| **Fine-grained PAT** | Genuinely decent and much cheaper: repo + permission scoping with no key custody. Rejected because it is still a *user* credential (dies with the account, consumes a seat, max lifetime in months not hours) and cannot down-scope per operation — so it cannot express the elevated-promotion flow, which is the packet's whole point. **Recommended as the fallback if the operator judges App-key custody too costly** (Q2). |
| **Machine user + PAT** | Consumes a seat [DOCS]; still a long-lived credential; adds an account to secure. Strictly worse than an App. |
| **Deploy keys (SSH, per repo)** | Push-only, no API. Cannot edit releases, cannot dispatch workflows, cannot poll Actions. Would solve only the mirror push and would need a second mechanism for everything else. Worth noting that it would interact with order 322's SSH-CA direction, but a second key-distribution scheme is precisely what 322 argued against. |
| **GitHub Actions OIDC → Vault JWT auth** | Excellent, and solves the *inverse* problem: it lets a workflow authenticate **to Vault** without a stored secret. It does not let the host authenticate **to GitHub**. Complementary, not substitutable — and worth filing separately if workflows ever need Vault. |
| **Store the App private key in Vault KV** | Would make the App model a net downgrade: one readable secret whose compromise is "persistent authentication as the GitHub App" [DOCS], replacing one readable secret whose compromise is one user's scopes. Transit sign-only or don't do it. |
| **App private key in a repo secret / env var** | GitHub's own guidance rejects this: "you should not hard-code your private key… even if your code is stored in a private repository," and env vars are called out as weaker [DOCS]. |
| **Accept webhooks via smee.io** | Every payload transits a third party. Incompatible with the stated posture. |
| **Accept webhooks via a public endpoint on the node** | Requires an inbound listener on a machine whose defining property is that it has none. |
| **App installation token as the new `HOMEBREW_GITHUB_API_TOKEN`** | Does not work (installation tokens cannot reach repos outside the installation [DOCS]; brew reads Homebrew-owned attestations) and does not remove the readable credential from the lane. See §4.4. |

### 7.4 Questions that genuinely need a human call

**Q1 — Who owns the App?** A personal account (`tlatoani`) or a new
organization? Personal is simpler today; org is required if the identity should
outlive one person's account, and it changes who can rotate the key. Private
("only on this account") is recommended either way; public would let third
parties install it. **Blocks R1.**

**Q2 — Is a single-node Vault Transit key acceptable custody** for a secret whose
compromise is persistent App impersonation? The recorded vision already flags
"blast radius of the CA itself… its compromise is worse than any token's" for the
SSH CA; this key is the same class. Alternatives: hardware-backed signing, or an
offline key used only to bootstrap. **If the answer is no, take the fine-grained
PAT fallback instead of building a weak App.**

**Q3 — Does a forge lane keep any GitHub capability at all?** This is order 435's
open decision, now with four options: amend the spec / scope the injection /
remove it and accept anonymous brew / mediate at the proxy (§4.4-B). The
proxy option requires bumping `api.github.com`, which is a deliberate TLS-
interception posture change and needs its own yes/no.

**Q4 — Webhooks: defer entirely, or build the outbound poller now?** Deferring
costs nothing today. Building the poller early gives order 389 a source of
verifiable, broker-checkable evidence (§6.4) that does not depend on trusting the
caller — which may be worth pulling forward.

**Q5 — Does minting an elevated (`promotion` / `release-dispatch`) token require
human presence?** The recorded vision's "encrypted OK button" — a WebAuthn
assertion over a hash of the exact action text — is the natural fit, and the
vision explicitly says unlocked capabilities are pre-authorized while locked ones
require presence. But the flagship node is headless. **Decide whether promotion
is a "locked" capability.** If yes, R3 depends on a mechanism that does not exist
yet and should be sequenced accordingly.

**Q6 — Should GitHub-side protection rules back the token scoping?** §6.3 is
explicit that `mirror-push` and `promotion` request the same permission because
GitHub's granularity does not distinguish them. A real capability split needs tag
protection rules plus a deliberate App bypass list on GitHub. Worth doing, but it
is configuration in GitHub's UI, not code, and someone has to own it.

**Q7 — Is losing offline-tolerant push acceptable?** Today a push can succeed
with a cached PAT while the GitHub API is degraded. Under the App model, minting
must succeed first. Small, real, and irreversible once adopted.

---

## 8. Boundary with packet 319 (`mirror-credential-helper-broker`)

Drawn explicitly so neither packet silently absorbs the other.

**Packet 319 owns the credential *channel* for one consumer: the mirror's
upstream push.** Its EC1 (no token in URL/argv/env) and EC2 (rotation without
rebuild) are **already satisfied and verified** by order 424 — the
`git-credential-tillandsias` helper, the cleaned push URL, and the per-invocation
Vault read. Its EC3 is a **decision record: adopt or reject GitHub App
installation tokens for the mirror push**, and it is the only thing keeping 319
open.

**Packet 390 owns the App itself**: the identity, the key custody, the minting
authority, the profile/permission model, the elevated-token flow for promotions
and releases, and the webhook posture.

| Concern | 319 | 390 |
|---|---|---|
| `git-credential-tillandsias.sh` helper contract (get/store/erase, stdin/stdout) | **owns** | must not change it |
| Clean push URL, no token in argv/env, rotation without rebuild | **owns** (done) | inherits |
| Mirror's Vault identity (AppRole + Vault Agent auto-auth) | **owns** | reuses, extends with a signing grant |
| The *decision* "App tokens for the mirror push: adopt or reject" | **owns EC3** | **supplies** the analysis and the recommendation (§7.1 R2 = ADOPT) |
| App registration, ownership, private-key custody | — | **owns** |
| JWT minting, profiles, per-operation permission sets, revocation | — | **owns** |
| Promotion / release elevated tokens; integration with order 389 | — | **owns** |
| Webhooks | — | **owns** (recommendation: defer) |
| Forge-lane `HOMEBREW_GITHUB_API_TOKEN` | — | analyses it (§4.4) but **does not own it — order 435 does** |

**Operationally:** 319 closes when the operator signs §7.1's R2 line ("adopt, via
a broker behind the existing helper"). It does **not** need R1–R3 implemented to
close — EC3 asks for a decision, not a deployment. 390 remains open after that,
because promotions, releases, key custody, and webhooks are outside 319's scope
by its own title ("that packet scopes the push credential only", per 390's
`outcome`).

**Anti-absorption rule:** if implementation work changes the *helper protocol* or
the *mirror's push path*, it belongs to 319. If it changes *what identity mints
the credential* or *what that identity may do*, it belongs to 390.

---

## 9. What could not be verified, and why

1. **Whether a GitHub App installation token retains any implicit read access to
   public repositories outside its installation.** GitHub's docs state plainly
   that an installation token "cannot be granted access to repositories that the
   installation was not granted access to," and separately that implicit public-
   resource read is described for **user** access tokens; the permissions
   reference only says "some endpoints can also be used to access public
   resources without these permissions," without naming a token type. This is
   decisive for §4.4 (whether an App token could ever serve brew) and it can only
   be settled empirically — mint a token and `GET
   /repos/Homebrew/homebrew-core`. Not done: no App exists, and creating one is
   implementation work this packet is not authorized to do.

2. **Whether `HOMEBREW_GITHUB_API_TOKEN` is even the right lever for brew's
   attestation path.** Homebrew's attestation verification shells out to the `gh`
   CLI and reads attestations from Homebrew-owned repositories; the exact token
   requirement is discussed in Homebrew issues rather than pinned in
   documentation. The operator's 2026-07-15 repro is the authority that *some*
   token is needed; *which* token would suffice is unverified.

3. **The live runtime env of an actual forge lane.** I did not launch one. Every
   claim in §4.3–§4.4 about what a lane receives is derived from reading
   `build_forge_agent_run_args_with_vault` and
   `ContainerSpec::build_run_args` — i.e. **verified where it was written, not
   where it runs.** That is the same gap §4.2 identifies in the repo's own test
   suite, and it is why R0 exists. On Linux the launcher runs on the host; on
   macOS and Windows the same argv is executed by podman inside the guest VM, so
   even a host-side observation would not generalize.

4. **`main.rs` line numbers.** The file was being edited by a concurrent agent
   during this research (line numbers shifted ~39 lines mid-session). All
   `main.rs` claims are cited by symbol name and were re-confirmed by grep, but
   any line number quoted from it elsewhere in the ledger may be stale.

5. **Whether the operator's `gh` auth on the host is an OAuth grant or a pasted
   PAT.** `secret/github/token` is written from `gh auth token` in the login
   container, and `git-mirror.hcl` calls it "the GitHub OAuth token," but an
   interactive paste path also exists. Its actual scopes were not enumerated —
   doing so would require reading the live token, which this packet will not do.

6. **Vault Transit RSA signing against *this* deployment.** The capability is
   documented and the deployed version (`hashicorp/vault:1.18`) is well past the
   feature's introduction, but Transit is **not currently enabled** in this
   Vault — `images/vault/entrypoint.sh` enables `approle`, KV-v2, and the file
   audit device only. Enabling it is R1 work.

7. **Whether GitHub's tag protection can be made to distinguish the `stable` tag
   force-push from ordinary pushes for an App principal** (Q6). Not researched;
   it is GitHub-side configuration and depends on repository settings not visible
   from this checkout.

8. **Rate-limit headroom under polling.** §5.3's conditional-request argument is
   documented, but the actual poll frequency the ladder needs is undefined until
   order 389 defines its stages.

---

## 10. Sources

GitHub documentation (the authority for every [DOCS] claim):

- Installation access tokens: <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app>
- Authenticating as an installation: <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
- Generating a JWT: <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app>
- Managing private keys: <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps>
- Choosing permissions: <https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app>
- Registering a GitHub App: <https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app>
- About creating GitHub Apps: <https://docs.github.com/en/apps/creating-github-apps/about-creating-github-apps/about-creating-github-apps>
- Apps vs OAuth apps: <https://docs.github.com/en/apps/creating-github-apps/setting-up-a-github-app/differences-between-github-apps-and-oauth-apps>
- User access tokens: <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app>
- REST: installations (incl. `DELETE /installation/token`): <https://docs.github.com/en/rest/apps/installations>
- Rate limits: <https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api>
- REST best practices (conditional requests, polling vs webhooks): <https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api>
- Webhook events and payloads: <https://docs.github.com/en/webhooks/webhook-events-and-payloads>
- Testing webhooks (smee.io): <https://docs.github.com/en/webhooks/testing-and-troubleshooting-webhooks/testing-webhooks>
- Webhook forwarding via the GitHub CLI: <https://docs.github.com/en/webhooks/testing-and-troubleshooting-webhooks/using-the-github-cli-to-forward-webhooks-for-testing>
- Validating webhook deliveries: <https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries>
- Triggering a workflow (GITHUB_TOKEN does not create new runs): <https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow>
- PAT policy for organizations: <https://docs.github.com/en/organizations/managing-programmatic-access-to-your-organization/setting-a-personal-access-token-policy-for-your-organization>
- `actions/create-github-app-token`: <https://github.com/actions/create-github-app-token>

HashiCorp documentation:

- Transit API (key types, `signature_algorithm`, `exportable`, import): <https://developer.hashicorp.com/vault/api-docs/secret/transit>
- Transit engine overview (BYOK): <https://developer.hashicorp.com/vault/docs/secrets/transit>

In-repo (all [REPO] claims; branch `linux-next`, 2026-07-31):

- `openspec/specs/forge-offline/spec.md`, `openspec/specs/git-mirror-service/spec.md`,
  `openspec/specs/tillandsias-vault/spec.md`,
  `openspec/specs/podman-idiomatic-patterns/spec.md`,
  `openspec/specs/security-privacy-isolation/spec.md`
- `openspec/litmus-tests/litmus-credential-isolation.yaml`,
  `…/litmus-forge-offline-profile-shape.yaml`,
  `…/litmus-vault-policy-forge-cannot-read-github-token.yaml`,
  `…/litmus-environment-isolation.yaml`,
  `…/litmus-forge-secret-capability-contract.yaml`,
  `…/litmus-vault-github-token-capture-shape.yaml`
- `crates/tillandsias-headless/src/main.rs`
  (`build_forge_agent_run_args_with_vault`, `build_opencode_forge_args`,
  `build_git_run_args`, `github_token_injected_as_env_host_side_never_argv`)
- `crates/tillandsias-headless/src/vault_bootstrap.rs`
  (`vault_kv_get_via_exec`, `read_and_handover_root_token`,
  `mint_approle_auto_auth_for_container`, `provision_approle_roles`)
- `crates/tillandsias-podman/src/container_spec.rs` (`build_run_args`)
- `crates/tillandsias-vault-client/src/policy.rs`
- `images/vault/policies/*.hcl`, `images/vault/entrypoint.sh`,
  `images/vault/Containerfile`
- `images/git/git-credential-tillandsias.sh`, `images/git/relay-refs.sh`,
  `images/git/vault-cli.sh`, `images/git/vault-agent.hcl`,
  `images/git/entrypoint.sh`
- `images/proxy/squid.conf`, `images/proxy/allowlist.txt`
- `.github/workflows/release.yml`, `scripts/promote-stable.sh`,
  `scripts/build-image.sh`, `scripts/check-credential-channel.sh`
- `plan/index.yaml` orders 319, 359, 389, 390, 426, 435
- `plan/issues/git-mirror-architecture-decision-2026-07-19.md`,
  `plan/issues/brew-shim-attestation-requires-gh-token-2026-07-12.md`,
  `plan/issues/night-cycle-handoff-2026-07-19.md`
- `plan/issues/operator-vision-ai-cloud-region-2026-07-31.md` — **CONTEXT only,
  not authorization** (§5.2, §6.4, §7.4 Q5 cite it as recorded vision)
