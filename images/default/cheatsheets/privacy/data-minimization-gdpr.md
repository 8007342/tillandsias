---
tags: [privacy, gdpr, data-minimization, ccpa, principles]
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://gdpr-info.eu/art-5-gdpr/
  - https://gdpr.eu/data-minimization/
  - https://oag.ca.gov/privacy/ccpa
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Data minimisation — GDPR Article 5 + CCPA principles

@trace spec:agent-cheatsheets
@cheatsheet security/owasp-top-10-2021.md

## Provenance

- GDPR Article 5 (the principles, including "data minimisation"): <https://gdpr-info.eu/art-5-gdpr/>
- GDPR.eu plain-language summary of data minimisation: <https://gdpr.eu/data-minimization/>
- California Office of the Attorney General — CCPA reference: <https://oag.ca.gov/privacy/ccpa>
- **Last updated:** 2026-04-25

## Use when

You're designing a data model, building an API, choosing what to log, or scoping a feature that touches personal data. The principle: **collect only what you need, keep only as long as you need, share only what's necessary.** Applies regardless of jurisdiction — GDPR/CCPA codify it; common sense + threat-model practice predates them.

## The principle in one sentence

Per GDPR Article 5(1)(c): personal data shall be "adequate, relevant and limited to what is necessary in relation to the purposes for which they are processed."

Three operative words: **adequate** (enough to do the job), **relevant** (related to the stated purpose), **limited** (no extras).

## Quick reference — apply the lens

| Question to ask | If "no" → minimise |
|---|---|
| Do I need this field to deliver the stated value? | drop the column |
| Do I need this field NOW vs later? | defer collection until needed |
| Do I need to store this, or can it pass through? | don't persist; relay only |
| Do I need user-identifying granularity, or aggregate? | aggregate / pseudonymise |
| Do I need this 90 days from now? | set a TTL / retention schedule |
| Does this third party need it, or can I forward less? | filter before forwarding |
| Is this in the log? Why? | scrub or hash; logs aren't a feature |

## Common patterns

### Pattern 1 — "Do not collect" beats "delete after"

The cheapest data to comply with is data you never collected. If a feature works without a phone number, don't collect a phone number. If it works without exact location, ask for region. If it works without a name, ask for a display handle.

### Pattern 2 — Pseudonymise at the boundary

When a downstream system needs an identifier but doesn't need to know who it points to, hand them an opaque ID (HMAC of the user ID + a secret) instead of the user ID itself. Reversing requires the secret; routine downstream operations don't.

```text
internal user_id   →  HMAC-SHA256(user_id, k_downstream)  →  downstream
```

GDPR Recital 26: pseudonymisation reduces but does not eliminate privacy obligation; anonymisation (irreversible) does.

### Pattern 3 — Retention schedules expressed as code

```text
class UserEvent:
    occurred_at: timestamp
    retain_until: timestamp = occurred_at + 90 days

# nightly job:
DELETE FROM user_events WHERE retain_until < NOW();
```

The schedule is in the data model, not in a wiki page someone forgets to follow. Audit who can extend retention; default-deny.

### Pattern 4 — Logs are data too

Application logs almost always contain personal data (email in user-prompt logs, IP in access logs, cookie values in error traces). Apply the same lens: do logs need to retain identifiers for 90 days, or 7? Strip secrets before logging, hash identifiers, set log-retention TTL.

### Pattern 5 — Right to erasure cascades

Per GDPR Article 17, when a user requests erasure, every system holding their data deletes — primary DB, replicas, caches, search indices, BigQuery exports, S3 backups (within reasonable timeframe — backups have retention windows, but new restores must respect the deletion).

Build a `delete_user(user_id)` function in your service interface from day one. Wiring it through every store after the fact is much harder than wiring it in.

## Common pitfalls

- **"It's anonymised" when it's pseudonymised** — anonymisation is irreversible by your org. If you keep the lookup table, it's pseudonymised; the GDPR/CCPA still apply.
- **Aggregate data isn't always anonymous** — small-group aggregates can re-identify (k-anonymity violations). Latanya Sweeney showed 87% of US population is uniquely identified by `(zip, gender, DOB)`.
- **"We don't sell data, just share it"** — CCPA defines "sale" broadly; sharing for cross-context advertising counts. Consult counsel before relying on an "we don't sell" framing.
- **Retention schedules without enforcement** — a 90-day TTL that nobody runs is fiction. Cron / scheduled job + monitoring on its execution.
- **DSAR (data subject access request) takes weeks** — should be hours-to-days. If you don't know what data you have on a user, you have a different problem than DSAR latency.
- **PII in URLs** — query strings end up in access logs, referer headers, screenshots. Move PII into POST bodies / cookies / headers, never URL components.
- **Backup retention longer than primary retention** — defeats the purpose. Either shorten backup retention OR encrypt backups with rotating keys you can destroy.
- **Vendor lists that drift** — every third-party processor is a privacy surface. Maintain a current list (data-processing agreements / sub-processor list) and audit on schedule.

## When to talk to a lawyer

- Cross-border data transfer (EU↔US, EU↔China, US↔China). Schrems II changed the calculus — your "standard contractual clauses" are no longer a free pass for EU→US.
- Categorical sensitive data: health, biometric, children, ethnicity, sexual orientation, religion. Special-category data under GDPR Article 9 has stricter rules.
- B2B vs B2C distinction. CCPA carves out some B2B; GDPR doesn't.
- Whenever you're considering "we'll just hash the email" as your anonymisation story.

This cheatsheet is **not legal advice**. It's a practitioner's lens for "where to start."

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://gdpr-info.eu/art-5-gdpr/`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/gdpr-info.eu/art-5-gdpr/`
- **License:** see-license-allowlist
- **License URL:** https://gdpr-info.eu/art-5-gdpr/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/gdpr-info.eu/art-5-gdpr/"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://gdpr-info.eu/art-5-gdpr/" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/privacy/data-minimization-gdpr.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `security/owasp-top-10-2021.md` — A02 (cryptographic failures), A04 (insecure design), A07 (auth failures) all touch privacy
- `data/postgresql-indexing-basics.md` — column-level encryption for sensitive fields
