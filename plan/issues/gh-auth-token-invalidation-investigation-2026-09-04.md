# Investigation: `gh` keyring tokens go invalid fleet-wide, several times a day

- filed_by: pirria (linux, floor tier), at the operator's request 2026-09-04
- order: 1025-a896
- packet_id: the-operators-gh-token-is-revoked-two-or-three-times-a-day-on-several-hosts-while-the-coordinator-never-re-logs-in
- owner_host: linux-mutable (assigned to macuahuitl)
- capability_tags: [github, credentials, vault, research, online-search]
- status: in_progress
- kind: investigation
- priority: p1
- desired_release: v0.5

## Operator report

> "I have to `gh auth login` some terminals two or three times a day, and every
> time they said they were already logged in. While some others like Macuahuitl
> have never required a re-login."

Not OS-correlated: observed the same morning on **macneo (macOS)** and on
**pirria (CachyOS, rolling)**. Not immutability-correlated — pirria is a rolling
mutable host. The operator's read is that this is **systemic**, and the evidence
below supports that.

## Observed sequence (operator's terminal, pirria, 2026-09-04T08:06 local)

```
$ gh auth status
github.com
  X Failed to log in to github.com account 8007342 (keyring)
  - Active account: true
  - The token in keyring is invalid.
  - To re-authenticate, run: gh auth refresh -h github.com

$ gh auth login
  ... device flow, one-time code 233F-F401 ...
✓ Authentication complete.
✓ Logged in as 8007342
! You were already logged in to this account
```

Immediately after, `gh auth status` on the same host read healthy:

```
✓ Logged in to github.com account 8007342 (keyring)
  - Token: gho_************************************
  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'
```

## FIRST: two symptoms, and one of them is not a bug

**"! You were already logged in to this account" is NOT a refusal and is not the
defect.** It is printed on the LAST line, AFTER `✓ Authentication complete.` and
`✓ Logged in as 8007342` — i.e. the device flow succeeded and a NEW token was
written. It means only "the account you just authenticated was already present
in the config", which was true. Reading it as "the login was rejected / nothing
happened" is the natural reading and it is wrong; it is a trailing notice on a
successful re-auth.

Whoever picks this up must not spend the cycle on that string. **The real defect
is upstream of it: the stored token keeps becoming invalid.** `gh auth login`
reports on the PRESENCE of a stored account; `gh auth status` VALIDATES the token
against the API. "Already logged in" + "token is invalid" is exactly the
signature of a credential that is present locally and revoked server-side.

## MEASURED AND RULED OUT: the enclave proxy is not in this path

The operator's hypothesis was that proxied credentials make GitHub stop
considering us legitimate, with the caveat "except when running in bare metal
you're not going through our enclave proxy, are you?"

**Correct — bare-metal `gh` does not traverse the enclave proxy.** Measured on
pirria while the fault was live:

- `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, `https_proxy`, `NO_PROXY`,
  `no_proxy` — all unset in the host environment
- `gh config list` → `http_unix_socket=` empty, `api_host=` empty
- no `GH_HOST`, no `GH_TOKEN`, no `GITHUB_TOKEN` override
- `gh` is the host Homebrew binary `/home/linuxbrew/.linuxbrew/bin/gh` 2.100.0,
  not a container shim

So the host CLI reaches api.github.com directly. **Any hypothesis resting on the
proxy mangling host-side auth is dead on this lane** — which matters, because it
is the intuitive explanation and it would absorb a whole cycle. The proxy remains
in scope only for the IN-ENCLAVE path (below), which is a different consumer.

## LEADING HYPOTHESIS: OAuth-app single-token semantics, one account, many hosts

The token is `gho_*` — a **GitHub CLI OAuth app** token from the device flow, and
the scope set (`gist`, `read:org`, `repo`, `workflow`) is precisely gh's default
device-flow request. Every host in the fleet authenticates as the **same GitHub
account, `8007342`, through the same OAuth app**.

For OAuth apps, GitHub's authorization model is per (user, application), not per
device. A fresh device-flow authorization for the same user + same app can
therefore **replace/revoke the previously issued token**, invalidating the copy
held by every other host.

This predicts every property the operator reported:

| Observation | Predicted by this hypothesis |
|---|---|
| 2–3 invalidations per day | = how often *some other host* re-authenticates |
| macuahuitl never needs re-login | it is where the operator most often logs in, so it always holds the newest token |
| not OS-correlated (macneo + pirria) | nothing OS-specific in the mechanism |
| not immutability-correlated | ditto |
| "already logged in" + invalid token | local record survives; server-side token does not |

**It is self-reinforcing:** each corrective `gh auth login` invalidates another
host, which the operator then has to re-login, which invalidates another. That
matches "two or three times a day" better than any expiry schedule.

### Decisive test (cheap, do this first)
1. On host A record the token fingerprint: `gh auth token | sha256sum`, plus
   `gh auth status`.
2. On host B run `gh auth login` (device flow) to completion.
3. Re-run `gh auth status` on host A **without touching anything else**.

If A is now invalid, the hypothesis is confirmed and the remaining work is the
fix, not more diagnosis. If A survives, drop this hypothesis and go to the
alternatives.

## ALTERNATIVE HYPOTHESES, ranked

2. **One token captured into Vault and fanned out to many consumers.** The
   enclave does NOT run its own device flow — there is no `login/device` or
   `device_code` anywhere in the tree — it reads a token from Vault
   (`vault-cli read -field=token secret/…`, seen in this host's `--init` log) and
   mounts it into the git image. `scripts/build-image.sh` also consumes
   `gh auth token` directly. So the operator's single OAuth token is copied to
   N containers and hosts. Distinct from H1: here the risk is GitHub's *abuse /
   anomaly* heuristics seeing one OAuth token used from many IPs and user agents
   — including from inside the enclave, where it DOES egress via the proxy, so
   the fleet's traffic can appear to originate from one address while the same
   token is also used from several residential ones. Test: correlate an
   invalidation timestamp against enclave activity, and check GitHub's security
   log (below) for the revocation reason.
3. **Keyring/secret-service eviction.** The token lives in the OS keyring, not
   in `hosts.yml` (confirmed: `~/.config/gh/hosts.yml` on pirria carries only
   `git_protocol` and `users:`, no `oauth_token` field). A locked, restarted or
   evicted secret-service would make gh report the entry unreadable. **Weaker:**
   gh's message is "The token in keyring is invalid", i.e. it READ a token and
   the API rejected it — not that it failed to read one. Keep only if H1 and H2
   both fail.
4. **Token expiry.** GitHub OAuth tokens can carry an 8-hour lifetime when the
   owning app has expiring tokens enabled. 2–3 times a day is suspiciously close
   to an 8h cycle. Cheap to check and would explain the cadence without any
   fleet interaction — but does NOT explain why macuahuitl never re-logins, so
   it is likely at most a contributing factor.

## REQUIRED: online-search investigation

The operator asked for this explicitly, and it is the right call — the
authoritative answer is in GitHub's current behaviour, not in our tree. Whoever
takes this must search rather than reason from memory, because the OAuth
token-replacement semantics have changed over the years and stale knowledge here
produces a confident wrong answer.

Questions to answer from primary sources (GitHub docs, `cli/cli` issues,
GitHub changelog):

1. Does a new device-flow authorization for the same user + same OAuth app
   **revoke** the previously issued token today, or are concurrent tokens
   issued per authorization?
2. Does GitHub apply an expiry to GitHub-CLI OAuth tokens, and is it
   configurable/observable?
3. Does GitHub revoke OAuth tokens on anomalous concurrent use from many IPs,
   and is that surfaced anywhere the operator can read?
4. Known `cli/cli` issues matching "token in keyring is invalid" recurring
   several times daily — this is common enough that a matching issue likely
   exists with a maintainer answer.
5. **GitHub App vs fine-grained PAT for fleet use** — the operator's own
   instinct, and it is sound. A GitHub App issues **per-installation** tokens
   and fine-grained PATs are independent per token, so neither has the mutual
   revocation H1 describes. Establish what a fleet of ~8 hosts + ephemeral
   forge containers should use, and what scopes/permissions the fleet actually
   needs (we currently take gh's default four, which may be more than required).

Also read the operator's own **GitHub security log**
(`https://github.com/settings/security-log`, filter `action:oauth_authorization`
and `action:oauth_access.destroy`): it records authorization and revocation
events with timestamps, and will settle H1 vs H2 vs H4 directly against
observed reality rather than by argument.

## Findings and Settled Mechanism (Order 1025-a896)

### 1. The Mechanism
The invalidation cascade is governed by GitHub's OAuth app token issuance policy:
- Primary source: GitHub documentation ("Authorizing OAuth apps", `https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps`, cited 2026-09-04):
  > "There is a limit of ten tokens that are issued per user/application/scope combination. If an application creates more than ten tokens for the same user and the same scopes, the oldest tokens with the same user/application/scope combination are revoked."
  > "GitHub Apps don't have the per-user token limit."
- Further upstream issues in `cli/cli`:
  - `cli/cli#9233`: `gh auth login` for an already-logged-in user requests and generates a NEW OAuth token, replacing the local token without revoking the prior token on GitHub, adding to the pool count.
  - `cli/cli#11420`: all CLI OAuth logins for an account share one authorization grant.
- In a fleet of ~8 bare-metal hosts, plus forge containers, VM guests, WSL distros, and test runs, authenticating via `gh auth login` (which defaults to OAuth device flow requesting scopes `'gist', 'read:org', 'repo', 'workflow'`) exceeds the 10-token cap per (user, client_id, scopes).
- Once the pool exceeds 10 tokens, each subsequent `gh auth login` revokes the oldest live token in that user/app/scope pool. The affected host later receives a 401 Bad Credentials (`The token in keyring is invalid`), prompting the operator to run `gh auth login` on that host, which in turn mints another token and evicts the next oldest token on another host in a self-reinforcing cascade.

### 2. Multi-Host Evidence and In-Fleet Observations
- **2026-09-04**: macneo's token (minted ~14:40Z) became invalid by ~17:10Z after pirria logged in at 15:06Z.
- **2026-09-04 20:20Z**: pirria's token (fingerprint `4df91890...6f67`), verified identical locally, failed server-side with 401 Bad Credentials after subsequent logins/refreshes elsewhere.
- **Vault/Enclave interaction**: The enclave's Vault-fanned token is a copy of a bare-metal token (via `scripts/build-image.sh` consuming `gh auth token` and seeding Vault `secret/github/token`). When the bare-metal OAuth token is evicted by GitHub's 10-token cap, the Vault copy also becomes invalid. It does NOT mint separate tokens, but is affected downstream.

### 3. Recommendation & Trade-offs
- **Option A: Fine-Grained Personal Access Tokens (PATs) per host (Recommended)**
  - *Mechanism*: Generate fine-grained PATs scoped specifically to repository `8007342/tillandsias` with permissions:
    - Contents: Read and write
    - Workflows: Read and write
    - Pull Requests: Read and write
  - *Trade-offs*: Independent token lifetimes; each host has its own token that cannot be evicted by other hosts. Requires an all-or-none conversion: if any host continues using OAuth device flow, those logins will still cycle the OAuth pool, but PAT-backed hosts will remain completely immune.
- **Option B: GitHub App Installation Token for the Fleet**
  - *Mechanism*: Create a dedicated Tillandsias GitHub App installed on the account/repository. Hosts authenticate via App credentials to mint installation access tokens.
  - *Trade-offs*: GitHub Apps have no per-user 10-token limit. However, installation tokens expire in 1 hour, requiring an active refresh daemon/sidecar or Vault AppRole integration on every host to continuously mint fresh installation tokens.
- **Option C: Fleet Discipline (Interim Mitigation)**
  - *Rule*: Strict ban on `gh auth login` or `gh auth refresh` across worker cycles. Only the operator logs in when strictly necessary.
  - *Trade-offs*: Cheap to enforce, but fragile; any re-login risks evicting another node.

### 4. Remedy Line in `scripts/check-credential-channel.sh`
- Updated in `scripts/check-credential-channel.sh` under the `rejected` arm:
  - Specifically explains that GitHub revoked or expired the token (most commonly due to the 10-token OAuth cap across multi-host environments).
  - Provides the single-command remedy `gh auth login` (or switching to a fine-grained PAT / repo-local store via `print-remedy`).

## Exit Criteria Status

- [x] **Criterion 1**: The mechanism is named from measurement and documentation: GitHub's 10-token limit per user/application/scope combination for OAuth apps, causing eviction of oldest tokens under multi-host `gh auth login`.
- [x] **Criterion 2**: GitHub's current OAuth-app token semantics are cited from GitHub's official documentation (`https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps`, read 2026-09-04) and `cli/cli#9233`.
- [x] **Criterion 3**: Fix proposed with trade-offs: Fine-grained PATs per host vs. GitHub App installation tokens vs. OAuth cessation; Vault-fanned enclave token confirmed affected downstream as a copy.
- [x] **Criterion 4**: `scripts/check-credential-channel.sh` remedy line updated to name the mechanism and direct one-command remedy.
- [x] **Criterion 5**: The trailing notice "! You were already logged in to this account" documented as benign config-presence notification following successful authentication.

## Evidence

- operator terminal transcript, pirria, 2026-09-04T08:06 local (above)
- `gh auth status` before and after, same host, same minute
- proxy-absence measurements on pirria, taken while the fault was live
- `~/.config/gh/hosts.yml` on pirria: no `oauth_token` key, keyring-backed
- `scripts/build-image.sh` consumes `gh auth token`
- this host's `--init` log: enclave gh runs in the git image with a
  Vault-supplied token, `secret_mounted=true`
- no `login/device` or `device_code` implementation anywhere in the tree
- multi-host eviction timeline: macneo 14:40Z -> 17:10Z; pirria 15:06Z -> 20:20Z.

