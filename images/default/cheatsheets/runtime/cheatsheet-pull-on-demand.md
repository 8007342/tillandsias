---
tags: [meta, cheatsheet-system, pull-on-demand, license, recipe, proxy]
languages: []
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://www.oracle.com/downloads/licenses/oracle-free-license.html
  - https://docs.oracle.com/en/java/javase/21/docs/api/
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Cheatsheet pull-on-demand stub format

@trace spec:cheatsheets-license-tiered, spec:agent-cheatsheets
@cheatsheet runtime/cheatsheet-tier-system.md

**Use when**: You're authoring or reviewing a cheatsheet whose upstream license forbids bundling, and the in-forge agent must materialize the source through the proxy on demand.

## Provenance

- Oracle Free Terms and Conditions License (canonical "do-not-bundle" exemplar): <https://www.oracle.com/downloads/licenses/oracle-free-license.html>
- Oracle JDK 21 API documentation (worked-example upstream): <https://docs.oracle.com/en/java/javase/21/docs/api/>
- `openspec/specs/cheatsheets-license-tiered/spec.md` — normative spec; Decision 4 in the design defines this stub format
- **Last updated:** 2026-04-27

## Quick reference — required structure

A `tier: pull-on-demand` cheatsheet ships its `## Quick reference / Common patterns / Common pitfalls` sections like any other cheatsheet (hand-curated condensed summary). Below `## See also` it adds a `## Pull on Demand` section with this exact structure:

```markdown
## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: <license SPDX or short ID> — <license URL>. Redistribution is not granted.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

### Source

- **Upstream URL(s):**
  - `<canonical URL — single-page form preferred>`
- **Archive type:** `single-html` | `zip` | `tar.gz` | `tar.xz` | `directory-recursive`
- **Expected size:** `~<N> MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>`
- **License:** <SPDX or short ID>
- **License URL:** <canonical URL>

### Materialize recipe (agent runs this)

\`\`\`bash
set -euo pipefail
mkdir -p "$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/<host>/<path>"
cd       "$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/<host>/<path>"
curl --fail --silent --show-error \
  "<upstream-URL>" \
  -o index.html
# If the source is multi-page, fetch the rest here.
\`\`\`

### Generation guidelines (after pull)

1. Read `index.html` for the structure; pick subtrees relevant to the project.
2. Generate a project-contextual cheatsheet at
   `<project>/.tillandsias/cheatsheets/<category>/<name>.md` if the project
   uses these APIs heavily. Use `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local:
   ~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>`.
5. The next forge launch picks up the project-committed cheatsheet via the
   existing `forge-hot-cold-split` HOT path (tmpfs view of `/opt/cheatsheets/`).
```

## Common patterns

### Worked example — Oracle JDK 21 API

```markdown
## Pull on Demand

> Reason: oracle-ftc — https://www.oracle.com/downloads/licenses/oracle-free-license.html
> Redistribution is not granted.

### Source

- **Upstream URL(s):**
  - `https://docs.oracle.com/en/java/javase/21/docs/api/`
  - `https://docs.oracle.com/en/java/javase/21/docs/api/index-files/index-1.html` … `index-9.html`
- **Archive type:** `directory-recursive`
- **Expected size:** ~150 MB extracted
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/<project>/docs.oracle.com/en/java/javase/21/docs/api/`
- **License:** oracle-ftc
- **License URL:** https://www.oracle.com/downloads/licenses/oracle-free-license.html

### Materialize recipe (agent runs this)

\`\`\`bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/docs.oracle.com/en/java/javase/21/docs/api"
mkdir -p "$TARGET/index-files"
cd "$TARGET"
curl --fail --silent --show-error \
  "https://docs.oracle.com/en/java/javase/21/docs/api/" -o index.html
for i in 1 2 3 4 5 6 7 8 9; do
  curl --fail --silent --show-error \
    "https://docs.oracle.com/en/java/javase/21/docs/api/index-files/index-$i.html" \
    -o "index-files/index-$i.html"
done
\`\`\`

### Generation guidelines (after pull)

1. Read `index.html` for the package list; pick packages relevant to your project (e.g., `java.util.concurrent` for an event-driven backend).
2. Generate `<project>/.tillandsias/cheatsheets/languages/jdk-api.md` with
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
3. Cite the pulled source's local path in `## Provenance`.
```

## Common pitfalls

- **License URL missing** — validator ERROR. Every `## Pull on Demand` block MUST cite a canonical license URL the agent can `curl` to re-evaluate license drift.
- **Recipe targets a non-proxy-routable URL** — egress in the forge enclave is only allowed via the proxy (`HTTP_PROXY=http://proxy:3128`). Direct curls to non-allowlisted hosts will fail. The recipe SHOULD use vanilla `curl`; the `HTTPS_PROXY` env var is set forge-wide.
- **Recipe doesn't `mkdir -p` the cache target** — first-run failure. Always create the target directory before `cd`-ing or fetching into it.
- **Cache target outside the per-project subtree** — violates `forge-cache-dual` per-project isolation. The path MUST start with `$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/`. The `$PROJECT` env var is set by the forge entrypoint.
- **Generated project cheatsheet missing the right frontmatter** — at minimum needs `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`, `committed_for_project: true`. Validator ERRORs otherwise. If shadowing a forge default, ALSO needs the four CRDT override fields (`shadows_forge_default`, `override_reason`, `override_consequences`, `override_fallback`) — see `runtime/cheatsheet-crdt-overrides.md`.
- **Pulling content larger than the RAMDISK budget** — the pull cache is a tmpfs-overlay lane (64/128/1024 MB by host class) with auto-spillover to disk. Big pulls succeed; they just demote LRU content from tmpfs to disk inside the same per-project subtree. No agent action needed.
- **Forgetting that the cache is per-project ephemeral** — content survives container restart within the same project but NEVER crosses to project B's cache. Don't author recipes assuming cross-project persistence.

## See also

- `runtime/cheatsheet-tier-system.md` — when to pick `pull-on-demand` over the other tiers
- `runtime/cheatsheet-frontmatter-spec.md` — the v2 frontmatter contract
- `runtime/cheatsheet-crdt-overrides.md` — project-committed shadow flow (relevant when generated cheatsheets shadow forge defaults)
- `runtime/forge-hot-cold-split.md` — tmpfs-overlay lane semantics
- `runtime/forge-paths-ephemeral-vs-persistent.md` — per-project cache contract
- `cheatsheets/license-allowlist.toml` — domain license declarations
