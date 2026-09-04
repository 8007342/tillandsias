# Investigation: `gh` keyring tokens go invalid fleet-wide, several times a day

- filed_by: pirria (linux, floor tier), at the operator's request 2026-09-04
- order: **UNMINTED — macuahuitl must mint via `tillandsias-plan next-order`**
  (pirria has no toolchain; per `order_id_allocation` an order is minted, never
  picked, so this file deliberately carries none)
- owner_host: any (investigation), **assigned to macuahuitl**
- capability_tags: [github, credentials, vault, research, online-search]
- status: ready
- kind: investigation
- priority: p2
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

## Exit criteria

- the mechanism is named with a citation to a primary source, not inferred
- the H1 decisive test above is run across two hosts and its result recorded
- a recommendation lands for how the fleet should authenticate (GitHub App,
  fine-grained PAT per host, or keep OAuth), including required scopes
- if the recommendation is a GitHub App: the additional config the fleet needs
  is specified, including how the enclave/Vault path obtains installation tokens
- the "already logged in" trailing-notice confusion is documented wherever
  operators will hit it, so it stops reading as a failure

## Evidence

- operator terminal transcript, pirria, 2026-09-04T08:06 local (above)
- `gh auth status` before and after, same host, same minute
- proxy-absence measurements on pirria, taken while the fault was live
- `~/.config/gh/hosts.yml` on pirria: no `oauth_token` key, keyring-backed
- `scripts/build-image.sh` consumes `gh auth token`
- this host's `--init` log: enclave gh runs in the git image with a
  Vault-supplied token, `secret_mounted=true`
- no `login/device` or `device_code` implementation anywhere in the tree

## Note on scope

pirria filed this and can reproduce the SYMPTOM but cannot run the cross-host
decisive test alone, and has no toolchain to mint the order. Assigned to
macuahuitl, which the operator reports is the one host that has never needed a
re-login — that asymmetry is itself evidence and macuahuitl is the right place to
test it from.
