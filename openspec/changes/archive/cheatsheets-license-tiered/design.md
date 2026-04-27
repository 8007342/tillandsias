# Design — cheatsheets-license-tiered

## Context

Tillandsias ships a forge container in which agents (Claude Code, OpenCode, OpenSpec) act on behalf of a non-technical user ("AJ"). Cheatsheets are the **active source of truth** that anchors those agents: every spec cites cheatsheets under `## Sources of Truth`, every code path that follows a cheatsheet pattern carries a `@cheatsheet <category>/<file>.md` annotation, and every accountability log event names the cheatsheet that informed it. Cheatsheets are part of the convergence loop — code and spec converge toward intent, and cheatsheets ensure the intent is grounded in vendor-authoritative reality.

The just-archived `cheatsheet-source-layer` capability bundled verbatim source documents (RFCs, MDN pages, OWASP cheat sheets, etc.) into `cheatsheet-sources/` in the repo. Three problems surfaced:

1. **License fragility.** Every new domain required a manual allowlist audit. Any unaudited fetch was a redistribution risk.
2. **Repo bloat.** 48 verbatim files across 16 publishers as of v0.1.169.x; growth unbounded as cheatsheets proliferate.
3. **Drift cost.** Refresh was a manual chore. Verbatim bytes do not summarize themselves; their value is in *being there to consult*, but they had to be re-fetched to confirm they were still current.

The new model accepts that cheatsheets and their underlying sources have **different distribution constraints** and resolves the tension by **tiering**. Bundled material lives in the forge image (build-time fetch + bake), pull-on-demand material is a stub that the in-forge agent materializes at runtime through the proxy, and distro-packaged material rides on whatever the OS package manager already ships. The user's verbatim direction frames this as: agents inside the forge SHOULD be able to keep cheatsheets and their sources of truth up to date and complete; references SHOULD use the cached cheatsheet whenever present; and pull-and-generate is the agent's job, not ours.

**Stakeholders** (in priority order):

| Stakeholder | What they need from this system |
|---|---|
| In-forge agents (primary) | Fast local lookup + a deterministic recipe to fetch deeper context when the local summary is insufficient |
| Host maintainers (secondary) | License-clean redistribution, predictable image size, a refresh mechanism that converges over time |
| AJ (tertiary, hands-off) | Zero visible difference; cheatsheets just work, no prompts, no decisions |

## Goals / Non-Goals

### Goals

- License-clean redistribution: the forge image SHALL contain only material whose license permits redistribution, classified by an explicit allowlist.
- Fast-path zero-network reference: bundled cheatsheets and their sources are readable from `/opt/cheatsheets-image/` and `/opt/cheatsheet-sources/` with no proxy round-trip.
- Slow-path on-demand depth: non-redistributable APIs are reachable via a single deterministic recipe per cheatsheet, materialized into the per-project ephemeral cache through the proxy.
- Cheatsheets stay an active source of truth: agents can refresh them, generate project-contextual variants, and feed observations back via telemetry.
- Telemetry foundation: every cache miss (`agent had to pull because the cheatsheet did not cover it`) emits a structured event so the host can prioritize cheatsheet refresh on what agents actually consult.
- Distro-packaged sources are a first-class third tier (no fetch, no stub — just a path inside the image).

### Non-Goals

- We do NOT implement the runtime fetcher inside the forge — agents call the proxy themselves. This change ships the **stub format and recipe contract**; the runtime fetch is an agent capability we assume.
- We do NOT solve cross-project knowledge sharing in v1: per-project ephemeral cache only (per `forge-cache-dual`).
- We do NOT pre-generate per-project cheatsheets at forge build time. Project-contextual cheatsheets are runtime artifacts, committed to the project under `<project>/.tillandsias/cheatsheets/` if the user wants to keep them.
- We do NOT bundle non-redistributable content under any "fair use" or "we'll cite it" rationalization. Tier is enforced by the allowlist.
- We do NOT consume telemetry in v1 — only emit. Refresh-prioritization analytics is v2.
- We do NOT keep `cheatsheet-sources/` in git after the migration completes. The directory becomes a build cache (gitignored) populated on demand.

## Decisions

### Decision 1 — Three tiers, not two

| Tier | Source location at runtime | License constraint | Build-time work | Runtime work |
|---|---|---|---|---|
| `bundled` | `/opt/cheatsheet-sources/<host>/<path>` (image-baked, RO) | Redistribution permitted (allowlisted SPDX) | Fetch + SHA-pin at build | None — agent reads locally |
| `distro-packaged` | OS-installed path (e.g., `/usr/share/javadoc/java-21-openjdk/api/index.html`) | Vendor-shipped via the package manager; license already accepted at install | Validate package is in image manifest | None — agent reads OS-installed file |
| `pull-on-demand` | `~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>` (RAMDISK with disk spillover, per-project ephemeral) | Redistribution forbidden or unclear | Validate stub completeness only | Agent fetches via proxy when depth needed |

**Rationale:** Two tiers conflate "we ship this in the image" with "we fetch this at build". Distro-packaged material (Java JDK docs via `java-21-openjdk-doc`, Perl docs via `perl-doc`, etc.) is image-baked but NOT something we fetched — the package manager handled both license acceptance and bytes. Conflating it with `bundled` would either (a) duplicate bytes (download + dnf install), or (b) force `bundled` to handle dnf-managed paths, complicating the fetcher. Three tiers cleanly separate three install paths. The cheatsheet author picks one per cheatsheet via frontmatter; the validator enforces that the picked tier matches the cheatsheet's content.

**Alternative considered:** "License-clean cheatsheets, opaque sources." Drop `bundled` entirely and treat all sources as pull-on-demand. Rejected because (a) it forces a network hop on the most common case (vendor docs that ARE freely redistributable), defeating the "zero runtime downloads" methodology, and (b) it weakens the convergence loop — agents that have to pull every reference will not pull every reference.

### Decision 2 — Where bundled sources live in the forge image

- Bundled sources land at `/opt/cheatsheet-sources/<host>/<path>` inside the forge image, mirroring URL host structure (e.g., `https://www.rfc-editor.org/rfc/rfc6265` → `/opt/cheatsheet-sources/www.rfc-editor.org/rfc/rfc6265`).
- The directory is part of the image (lower-layer overlayfs) — RO at runtime. NO tmpfs view. The cheatsheets themselves get the tmpfs treatment (per existing `agent-cheatsheets` requirement); their underlying *sources* are bulk reference material and stay on disk.
- Each bundled source SHALL carry a `.meta.yaml` sidecar (URL, content_sha256, fetched timestamp, license, fetcher_version) baked alongside it.
- The cheatsheet that cites the source SHALL carry the SHA-256 in its frontmatter `image_baked_sha256` field at build time, so a corrupted or substituted file can be detected by `diff` against the live URL or by a re-bake.

**Rationale:** A tmpfs view of `/opt/cheatsheet-sources/` would burn RAM (some bundled sources are 100 KB+ HTML pages × dozens of cheatsheets). Disk is fine for sources; the cheatsheets are what need to be lightning-fast. Mirroring URL structure keeps the path predictable and the stub-format invariant unified ("the URL → path mapping is the same in `bundled` and `pull-on-demand`; only the location differs").

### Decision 3 — Where pull-on-demand content materializes

- Per-project ephemeral path: `~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>` inside the forge container. This sits inside the per-project cache mount governed by `forge-cache-dual` (project A NEVER sees project B).
- Backing store: by default the `~/.cache/tillandsias/cheatsheets-pulled/` subtree is **disk** (per-project cache directory, persistent across container restarts within the same project). The "RAMDISK preference" the user mentioned applies to the **generated cheatsheet** that summarizes the pulled source, not the raw bytes — the raw bytes can be a 200 MB JDK API archive that has no business in RAM.
- Generated project-contextual cheatsheets land in `/opt/cheatsheets/` (the existing 8 MB tmpfs governed by `forge-hot-cold-split` and `agent-cheatsheets`), and additionally are written to `<project>/.tillandsias/cheatsheets/<name>.md` on the project's bind mount when the agent decides to keep them across launches.
- **Pull-cache budget — tiered by host class, not a single number.** RAM cost is approximately linear in archive size (n bytes on disk ≈ n × 1.03 in tmpfs because of inode + alignment overhead). Spill to disk is **automatic** the moment the soft cap is exceeded — agents do not need to know which side of the cap their pull landed on. Defaults:

  | Host class | RAMDISK soft cap | How detected | Override |
  |---|---|---|---|
  | Modest (≤ 8 GB total RAM, no swap headroom) | **64 MB** | `MemTotal < 8 GiB` from `/proc/meminfo` at tray startup | `forge.pull_cache_ram_mb` in `~/.config/tillandsias/config.toml` |
  | Normal (8–32 GB total RAM) | **128 MB** | `8 GiB ≤ MemTotal < 32 GiB` | same |
  | Plentiful (≥ 32 GB total RAM) | **1024 MB (1 GB)** | `MemTotal ≥ 32 GiB` | same |

  Beyond the cap, content lives on disk under the same `~/.cache/tillandsias/cheatsheets-pulled/<project>/` path (the cache is a single LRU-managed pool; the cap controls how much sits in tmpfs vs disk). LRU eviction within the per-project subtree only — no cross-project eviction (`forge-cache-dual` invariant).

**Rationale:** The per-project cache is the existing dual-cache lane; reusing it gives us ephemerality, isolation, and persistence across container restarts within the same project for free. A single fixed budget would either starve plentiful hosts or overload modest ones; tiering on `MemTotal` is the cheapest accurate-enough heuristic (zero new dependencies). The `× 1.03` RAM-vs-disk overhead is small enough to ignore for budget math, large enough to mention so future debuggers know why a 128 MB cap may show 132 MB tmpfs usage.

### Decision 4 — Stub format for pull-on-demand cheatsheets

A pull-on-demand cheatsheet ships its `## Quick reference / Common patterns / Common pitfalls` sections like any other cheatsheet (hand-curated condensed summary). Below `## See also` it adds a `## Pull on Demand` section with this exact structure:

```markdown
## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: <license SPDX> — <license URL>. Redistribution is not granted.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

### Source

- **Upstream URL(s):**
  - `https://docs.oracle.com/en/java/javase/21/docs/api/`  (single-page form: `…/index-files/index-1.html`)
- **Archive type:** `single-html` | `zip` | `tar.gz` | `tar.xz` | `directory-recursive`
- **Expected size:** ~150 MB extracted
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/<project>/docs.oracle.com/en/java/javase/21/docs/api/`
- **License:** Oracle Free Terms and Conditions (no redistribution)
- **License URL:** https://www.oracle.com/downloads/licenses/oracle-free-license.html

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
mkdir -p "$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/docs.oracle.com/en/java/javase/21/docs/api"
cd "$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/docs.oracle.com/en/java/javase/21/docs/api"
curl --fail --silent --show-error \
  "https://docs.oracle.com/en/java/javase/21/docs/api/" \
  -o index.html
# For the full single-page form, fetch the index-files/ subtree:
for i in 1 2 3 4 5 6 7 8 9; do
  curl --fail --silent --show-error \
    "https://docs.oracle.com/en/java/javase/21/docs/api/index-files/index-$i.html" \
    -o "index-files/index-$i.html"
done
```

### Generation guidelines (after pull)

1. Read `index.html` for the package list; pick packages relevant to your project.
2. Generate a project-contextual cheatsheet at
   `<project>/.tillandsias/cheatsheets/languages/jdk-api.md` if the project
   uses JDK APIs heavily. Use `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter `summary_generated_by:
   agent-generated-at-runtime`, `tier: pull-on-demand`, and
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local:
   ~/.cache/tillandsias/cheatsheets-pulled/<project>/docs.oracle.com/...`.
5. The next forge launch will pick up the project-committed cheatsheet via
   the existing `forge-hot-cold-split` HOT path (tmpfs view).
```

**Rationale:** A markdown stub is human-readable AND machine-parseable (the `### Source` and `### Materialize recipe` headings are stable anchors). The recipe is shell because every agent in the forge has bash and curl. The generation guidelines are informational — we explicitly do NOT prescribe an output schema beyond "use the template" because the agent knows the project context and can shape the cheatsheet accordingly.

**Alternative considered:** YAML manifest in a sibling file (e.g., `cheatsheets/languages/jdk-api.recipe.yaml`). Rejected because it splits the cheatsheet into two files the agent has to load and reconcile; markdown-with-fenced-blocks keeps everything in one grep target.

### Decision 5 — Provenance schema v2 (frontmatter contract)

Every cheatsheet's `## Provenance` section gains structured frontmatter at the top of the file:

```yaml
---
tier: bundled                          # bundled | distro-packaged | pull-on-demand
source_urls:
  - https://docs.python.org/3/library/asyncio.html
last_verified: 2026-04-25              # ISO date — re-verified against upstream
summary_generated_by: hand-curated     # hand-curated | agent-generated-at-build | agent-generated-at-runtime
bundled_into_image: true               # true iff tier in {bundled, distro-packaged}
image_baked_sha256: d4760344…          # only for tier: bundled (set at build)
structural_drift_fingerprint: 8a3c1f…  # only for tier: bundled (set at build)
local: /opt/cheatsheet-sources/docs.python.org/3/library/asyncio.html  # only for bundled
package: java-21-openjdk-doc           # only for tier: distro-packaged
pull_recipe: see-section-pull-on-demand  # only for tier: pull-on-demand
committed_for_project: false           # true iff this lives under <project>/.tillandsias/cheatsheets/
---
```

The pre-existing `## Provenance` markdown section is retained for human readability (URLs, license names, "Last updated:" line). The frontmatter is the machine contract; the markdown is the eyeball contract. They MUST agree at validate time.

**Rationale:** YAML frontmatter is the standard markdown convention for machine metadata and the existing `cheatsheets/INDEX.md` regeneration script already parses it. Keeping a human-readable section preserves the `agent-cheatsheets` Provenance requirement without breakage.

### Decision 6 — Structural-drift fingerprint

For bundled-tier sources, compute a fingerprint at build time:

```
fingerprint = SHA256( join("\n", [h.text for h in soup.find_all(['h1','h2','h3'])]) )
```

Persist the first 16 hex chars in the cheatsheet's `structural_drift_fingerprint` frontmatter. On the next build (or on-demand refresh), re-fetch the URL, re-compute the fingerprint, diff. A mismatch flags the cheatsheet for human review — the upstream restructured. Word-level edits inside an unchanged outline do NOT trip the fingerprint (intentional: cheatsheets are summaries, not transcriptions).

For pull-on-demand tier, the in-forge agent computes the fingerprint after materializing the source and reports it back via the telemetry channel. The host can compare fingerprints across forge launches to detect structural drift before the agent even consults the cheatsheet again.

**Rationale:** Full content fingerprints (SHA over bytes) generate constant noise — every comma fix or typo edit would force a refresh review. Heading-outline fingerprints catch the change that actually breaks summaries: when a vendor moves a section, the cheatsheet's "see section X" guidance silently invalidates. Cheap, high signal, tolerant of editorial polish. **Trade-off accepted:** semantic changes within an unchanged outline (e.g., a vendor changes a default value) are not caught — refresh-cadence discipline (`Last updated` ≤ 90 days) covers that.

### Decision 7 — Build-time fetch flow

`scripts/build-image.sh forge` gains a fetch-and-bake stage immediately before the existing cheatsheet staging:

```
1. Read every cheatsheet's frontmatter under cheatsheets/**/*.md
2. Filter to entries with tier: bundled
3. For each, derive the (URL → /opt/cheatsheet-sources/<host>/<path>) mapping
4. Compute a cache key: SHA-256( sorted(union(URLs)) || --max-age-days flag )
5. Look up cache key in $CACHE_DIR/cheatsheet-source-bake/<key>/
6. If miss: invoke scripts/fetch-cheatsheet-source.sh --tier=bundled,
            populating $CACHE_DIR/cheatsheet-source-bake/<key>/
7. Stage <key>/ as the build context's cheatsheet-sources/ subtree
8. Containerfile / flake.nix: COPY cheatsheet-sources/ /opt/cheatsheet-sources/
9. For each bundled cheatsheet, inject image_baked_sha256 +
   structural_drift_fingerprint into a side-channel
   (.cheatsheets-meta/<category>/<name>.frontmatter.json) so populate_hot_paths
   can reflect the SHA in INDEX.md without rewriting the cheatsheet itself
   inside the image.
```

The cache survives between local builds; CI runs may pass `--max-age-days N` to age-pin; explicit `--refresh-sources` forces re-fetch. **Network failure during fetch SHALL NOT fail the build** — the previous `<key>/` (if any) is reused with a WARN, and the cheatsheet's `last_verified` is not bumped. This preserves the convergence philosophy: progress on what works, flag what doesn't.

**Rationale:** Reusing `scripts/fetch-cheatsheet-source.sh` as the bundled-tier engine keeps the proven HTTP semantics (raw GitHub rewrite, IETF .txt preference, etc.) and just gates on tier. The cache key over the URL-set means a new bundled cheatsheet automatically invalidates and triggers a partial re-fetch; an unchanged set is a no-op (the image build's existing staleness-detection layer rejects it before invoking the fetcher).

### Decision 8 — Distro-packaged path

Cheatsheet declares:

```yaml
---
tier: distro-packaged
package: java-21-openjdk-doc
local: /usr/share/javadoc/java-21-openjdk/api/index.html
source_urls:
  - https://docs.oracle.com/en/java/javase/21/docs/api/  # the upstream truth, even though we read the package locally
---
```

At build validation, `scripts/check-cheatsheet-sources.sh` confirms that `package` is listed in the forge image's package manifest (extract from `flake.nix` `contents`, or from `images/default/Containerfile` `dnf install` lines, or from a dedicated `images/default/distro-packages.txt` if one is added). At runtime, the agent reads `local` directly. No fetch. No stub. The frontmatter `source_urls` records the upstream truth so the structural-drift discipline can apply (the in-forge agent OR a host-side refresh script can compare local against upstream to catch package drift).

**Rationale:** This was implicit in the user's "linux packages that might include docs (jdk, jdk-docs, etc)" remark. Treating distro-shipped doc packages as a third tier means we benefit from package-manager license handling and disk efficiency (the JDK docs already live on disk if `java-21-openjdk-doc` is installed; we do not duplicate them under `/opt/cheatsheet-sources/`). It also lets the cheatsheet author opt into a doc bundle by editing the package list, with no fetch script changes.

### Decision 9 — Telemetry: "what made you check the API that wasn't in the cheatsheet?"

A new EXTERNAL-tier producer role: **`cheatsheet-telemetry`**. The forge container itself is the producer (writes to `/var/log/tillandsias/external/cheatsheet-telemetry/lookups.jsonl`, which is bind-mounted to `~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/lookups.jsonl` per `external-logs-layer`). Manifest:

```yaml
role: cheatsheet-telemetry
files:
  - name: lookups.jsonl
    purpose: One event per cheatsheet consultation by an in-forge agent
    format: jsonl
    rotate_at_mb: 10
    written_by: forge-agent (claude / opencode / opsx)
```

Event schema (one JSON object per line):

```json
{
  "ts": "2026-04-26T10:23:11Z",
  "project": "<project>",
  "cheatsheet": "languages/python.md",
  "query": "asyncio cancellation semantics",
  "resolved_via": "bundled" | "distro-packaged" | "pulled" | "live-api" | "miss",
  "pulled_url": "https://docs.python.org/3/library/asyncio-task.html#shielding-from-cancellation",
  "chars_consumed": 4823,
  "spec": "cheatsheets-license-tiered",
  "accountability": true,
  "cheatsheet_field": "languages/python.md"
}
```

`resolved_via = miss` is the load-bearing one: it means the agent looked at the cheatsheet, did not find what it needed, and pulled a deeper source (or queried a live API). These misses tell the host **what to add to which cheatsheet on the next refresh**.

**v1 scope (this change):** emit only. The agent (or the in-forge cheatsheet-resolver helper, if added) writes events; the tray's external-logs auditor enforces the manifest contract. Host-side analytics is **not** in v1.

**v2 scope (future change):** consume the events. A host-side `scripts/analyze-cheatsheet-telemetry.sh` aggregates by `(cheatsheet, query)` and surfaces top-N misses per cheatsheet to drive refresh priority. A cheatsheet whose top miss is a stable upstream URL becomes a candidate for inclusion in `## Quick reference`.

**Rationale:** Reusing the EXTERNAL-tier mechanism gives us host visibility without bind-mounting yet another path; the auditor already enforces the producer-manifest contract. JSON Lines is `jq`-friendly. v1 emission is cheap and creates the data surface for v2 analytics; doing analytics in v1 risks designing the consumption side without enough data to know what queries matter.

### Decision 10 — Project-committed cheatsheets (CRDT override discipline)

When the in-forge agent generates a cheatsheet from a pulled source for a specific project's needs, it writes to `<project>/.tillandsias/cheatsheets/<category>/<name>.md`. This directory is on the project's bind mount; the cheatsheet survives container stop and gets git-committed when the user wants to keep it.

**No hard shadow.** Cheatsheets are CRDTs — meaning converges across replicas (forge default + project override + agent-generated refinement) by structured discipline, not by silent shadowing. When a project-committed cheatsheet shadows a same-pathed forge-bundled cheatsheet, the project version wins in scope BUT MUST declare three override fields so agents reason instead of obey. Frontmatter:

```yaml
---
tier: pull-on-demand                  # the upstream is still pull-on-demand
summary_generated_by: agent-generated-at-runtime
committed_for_project: true
last_verified: 2026-04-26
source_urls:
  - https://docs.oracle.com/en/java/javase/21/docs/api/
license: Oracle FTC (do-not-bundle upstream)

# CRDT override discipline — REQUIRED iff this cheatsheet shadows a forge-bundled
# cheatsheet at the same path. Validator emits ERROR if shadowing without these.
shadows_forge_default: cheatsheets/languages/jdk-api.md
override_reason: |
  This project pins JDK 17 LTS rather than the forge default JDK 21, because
  our deployment target (Android Gradle Plugin 8.x) does not yet support JDK 21
  bytecode. We need the JDK 17 API surface, not 21.
override_consequences: |
  Agents working on this project MUST NOT use JDK 21-only APIs (java.util.HexFormat
  pattern matching for switch, sealed-class enhancements, etc.). Code that compiles
  on the forge default may fail at our deployment gate.
override_fallback: |
  If the agent encounters a JDK 21 example in upstream documentation that this
  cheatsheet does not cover, it SHOULD: (1) check whether the API is back-portable
  to JDK 17 (most java.lang/java.util additions are not), (2) if not, find the
  JDK 17 equivalent or open a project issue tagging "java-21-blocker", (3) NOT
  silently use the JDK 21 idiom assuming the forge default applies.
---
```

The three override fields (`override_reason`, `override_consequences`, `override_fallback`) are mandatory whenever `shadows_forge_default` is set; the validator emits ERROR if any are missing or empty. At runtime the agent reading the project cheatsheet sees ALL THREE fields surfaced **before** the cheatsheet body — the override is reasoned, not silent.

At forge launch, `populate_hot_paths()` (per `forge-hot-cold-split`) extends to include `<project>/.tillandsias/cheatsheets/` as a HOT-path source — its contents merge into `/opt/cheatsheets/` (tmpfs view) **after** the image-baked canonical, so project files override forge-shipped ones with the same path. The merger emits a forge-launch banner line per shadow:

```
[cheatsheet override] languages/jdk-api.md → project version (reason: JDK 17 LTS pin)
```

Forge-agnostic cheatsheets (the ones that would benefit other projects) are flagged by the agent at generation time via a comment:

```markdown
<!-- promotion-candidate: this cheatsheet is forge-agnostic and could be promoted to cheatsheets/ -->
```

The user (or a host-side script) can `git mv` the file from `<project>/.tillandsias/cheatsheets/` to `cheatsheets/` to promote it. Promotion is intentionally manual — automatic promotion across project boundaries violates `forge-cache-dual`'s isolation invariant.

**Rationale:** The CRDT override discipline (`override_reason` + `override_consequences` + `override_fallback`) is a **universal principle** that applies to all knowledge artifacts in the system — not a cheatsheet-specific patch. Silent overrides cause agents to make wrong decisions in edge cases without realizing they are holding a non-default position. The three-field envelope makes the trade-off auditable, lets the agent reason instead of obey, and gives the agent recovery semantics for cases the override author did not foresee. The project bind mount is the natural persistence layer for project-scoped knowledge; `forge-hot-cold-split`'s tmpfs view already governs `/opt/cheatsheets/`, so extending `populate_hot_paths()` to merge project-committed cheatsheets with shadow detection is a small, additive change.

### Decision 11 — Index regeneration

`scripts/regenerate-cheatsheet-index.sh` updated:

| Tier in frontmatter | Index-line suffix |
|---|---|
| `tier: bundled` (image_baked_sha256 set) | `[bundled, verified: <sha8>]` |
| `tier: bundled` (no fingerprint yet) | `[bundled, partial-verify]` |
| `tier: distro-packaged` (package present in manifest) | `[distro-packaged: <package>]` |
| `tier: distro-packaged` (package missing from manifest) | `[distro-packaged: MISSING]` (warning) |
| `tier: pull-on-demand` (no pull yet) | `[pull-on-demand: stub]` |
| `tier: pull-on-demand` (project-committed) | `[pull-on-demand: project-committed]` |

At runtime inside the forge, the in-forge index view (`/opt/cheatsheets/INDEX.md`) is the same baked file PLUS a runtime-merged section that lists project-committed cheatsheets and any pulled materializations under `~/.cache/tillandsias/cheatsheets-pulled/<project>/` (with a `[pulled]` badge). Implementation: `populate_hot_paths()` re-runs the index-regenerate logic (a stripped-down shell version) after merging.

**Rationale:** Tier-aware badges are the human-and-agent-facing signal that the tier system exists. The `[stub]` badge tells an agent "consult the recipe before assuming this cheatsheet is shallow on purpose"; `[verified: <sha8>]` tells an agent "this cheatsheet's source is on disk; you can `cat /opt/cheatsheet-sources/...` for depth without pulling".

### Decision 12 — Tombstone strategy

The just-archived `cheatsheet-source-layer` requirements that get superseded by this change need code-level `@tombstone superseded:cheatsheets-license-tiered` markers in the same commit that lands the new behavior. Specifically:

- `cheatsheet-sources/` directory tree: emptied (gitignored), but a single `cheatsheet-sources/.gitkeep-tombstone` file is committed with a `@tombstone superseded:cheatsheets-license-tiered — kept for traceability through 0.1.<N+3>.x` header. Final removal in 0.1.<N+3>.x per the three-release retention rule.
- `scripts/regenerate-source-index.sh`: keep, but add a `@tombstone obsolete:cheatsheet-source-layer` header. The script no longer runs in CI; safe to delete after three releases.
- `scripts/bind-provenance-local-paths.sh`: same treatment — superseded by the build-time meta injection in Decision 7.
- The pre-existing `cheatsheet-sources/license-allowlist.toml`: NOT tombstoned — repurposed (Decision 13).

The migration plan section spells out the version cadence; the design itself does not include the tombstone block markup (that lives in the implementation).

### Decision 13 — License-allowlist.toml as a CRDT (repurpose + lifecycle)

The existing `cheatsheet-sources/license-allowlist.toml` survives but moves to `cheatsheets/license-allowlist.toml` (next to the cheatsheets it classifies, not next to the now-empty sources tree). Schema gains a `default_tier` field, a `last_evaluated` timestamp, and an `evaluated_by` provenance marker per domain:

```toml
[domains."docs.python.org"]
publisher = "Python Software Foundation"
license = "psf"
license_url = "https://docs.python.org/3/license.html"
redistribution = "bundled"
default_tier = "bundled"               # cheatsheet author may override per-cheatsheet
last_evaluated = "2026-04-26"          # date the license was last re-checked
evaluated_by = "agent-runtime-pull"    # hand-curated | agent-runtime-pull | host-refresh-script

[domains."docs.oracle.com"]
publisher = "Oracle"
license = "oracle-ftc"
license_url = "https://www.oracle.com/downloads/licenses/oracle-free-license.html"
redistribution = "do-not-bundle"
default_tier = "pull-on-demand"
last_evaluated = "2026-04-26"
evaluated_by = "hand-curated"
```

**The allowlist itself is a CRDT.** Every pull-on-demand fetch by an in-forge agent re-evaluates the upstream's license declaration (the agent SHOULD `curl` the license URL, parse the SPDX or Oracle-FTC-style declaration, and compare to the stored value) and bumps `last_evaluated` if unchanged or emits a license-drift telemetry event (EXTERNAL tier, new event type `license_drift`) if changed. The host-side refresh script aggregates these events and surfaces drift for human triage; the actual edit to the TOML stays manual until v3 (auto-merge of agent-proposed allowlist changes is out of scope).

When a cheatsheet's frontmatter omits `tier`, the validator infers it from the first `source_urls[0]`'s domain: matched-domain `default_tier`, else `pull-on-demand` (safe default — never accidentally bundle an unaudited domain). The cheatsheet author MAY override (e.g., bundle a specific RFC excerpt explicitly) by setting `tier: bundled` in frontmatter and citing the per-document license in `## Provenance`.

**Rationale:** The allowlist already encodes the legal authority answer; making it a tier-classifier reuses that work. Treating it as a CRDT (versus a static config file) lets the cheatsheet system improve over time without manual sweeps — agents that pull fresh content are already the most authoritative source of "is this license still what we think it is?" data, and routing their observations through the existing telemetry channel reuses infrastructure. Per-cheatsheet override preserves authorial agency for edge cases (e.g., a single OWASP cheat sheet under CC-BY-SA-4.0 where the parent domain is unspecified).

### Decision 14 — Validator changes

`scripts/check-cheatsheet-sources.sh` becomes tier-aware:

| Tier | Validation |
|---|---|
| `bundled` | Source file exists at `/opt/cheatsheet-sources/<host>/<path>` (in image, post-build); `image_baked_sha256` matches; structural-drift fingerprint present |
| `distro-packaged` | `package` is in the forge image's package manifest; `local` path exists in the image |
| `pull-on-demand` | `## Pull on Demand` section present with all required sub-headings; `### Materialize recipe` is non-empty bash; `pull_recipe: see-section-pull-on-demand` in frontmatter |

ERROR violations exit non-zero. WARN violations (e.g., bundled cheatsheet missing fingerprint pre-first-build) print but exit 0. The pre-commit hook continues to run with `--no-sha` and surface ERRORs as non-blocking warnings (CRDT convergence philosophy).

**Rationale:** Tier-aware validation is the single point that prevents authors from accidentally shipping pull-on-demand content as bundled (license risk) or claiming a tier without filling in the contract. Keeping the pre-commit hook non-blocking preserves the project's convergence-not-correctness ethos.

## Cheatsheet Lifecycle (the convergence loop)

The user's direction was to "define [the cheatsheet's] lifecycle carefully and let runtime inference take care of it." The lifecycle below is what makes cheatsheets a CRDT: every state transition is monotonic (information accumulates, never silently disappears), and each transition is observable via telemetry, traces, or commit history.

```
┌─────────────────┐
│   AUTHORED      │  hand-curated .md in cheatsheets/, frontmatter tier set
└────────┬────────┘
         │  build-image.sh forge
         ▼
┌─────────────────┐
│  BUNDLED-BAKED  │  source fetched (bundled tier) OR package validated (distro)
│  OR STUB-VALID  │  OR stub recipe validated (pull-on-demand)
│                 │  → image_baked_sha256 + structural_drift_fingerprint set
└────────┬────────┘
         │  forge launch → populate_hot_paths()
         ▼
┌─────────────────┐
│     LOADED      │  /opt/cheatsheets/ tmpfs view ready; INDEX.md regenerated
│                 │  with [bundled, verified: <sha8>] / [stub] / [distro-packaged]
└────────┬────────┘
         │  agent reads cheatsheet
         ▼
┌─────────────────┐    cheatsheet-telemetry: resolved_via=bundled|distro|cached-pull
│      HIT        │ ───────────────────────────────────────────────────────► (loop)
└────────┬────────┘
         │  agent needs depth not in cheatsheet
         ▼
┌─────────────────┐    cheatsheet-telemetry: resolved_via=miss → query logged
│      MISS       │
└────────┬────────┘
         │  agent runs Materialize recipe (pull-on-demand)
         ▼
┌─────────────────┐    cheatsheet-telemetry: resolved_via=pulled, pulled_url logged
│     PULLED      │    license re-evaluation → license_drift event if changed
│                 │    structural_drift_fingerprint computed and reported
└────────┬────────┘
         │  agent generates project-contextual cheatsheet
         ▼
┌─────────────────┐
│    REFINED      │  written to <project>/.tillandsias/cheatsheets/<name>.md
│  (per-project)  │  summary_generated_by: agent-generated-at-runtime
└────────┬────────┘
         │  if shadows forge default → CRDT override fields required
         │  next forge launch → populate_hot_paths() merges into HOT
         ▼
┌─────────────────┐
│  PROMOTED?      │  manual: <!-- promotion-candidate --> → user git mv
│  (forge-wide)   │  Phase 4 / future change scope
└────────┬────────┘
         │  next bundled-tier rebuild OR scheduled refresh script
         ▼
┌─────────────────┐    structural_drift_fingerprint diff → if mismatch: WARN
│  RE-VERIFIED    │    last_verified bumped; image_baked_sha256 re-pinned
└────────┬────────┘
         │  back to BUNDLED-BAKED
         └────────────────────────► (loop)
```

**Each transition emits an observable signal.** Build-time transitions go to commit history (`@trace spec:cheatsheets-license-tiered`) and the cheatsheet's own frontmatter (`last_verified`, `image_baked_sha256`). Runtime transitions go to the EXTERNAL-tier `cheatsheet-telemetry` log (HIT, MISS, PULLED, license_drift, structural_drift). REFINED is observable via the project's git history (`.tillandsias/cheatsheets/` is a git-tracked directory). PROMOTED is observable via `cheatsheets/`'s git history with a commit message convention (`promote: <project> → <cheatsheet>`).

**Why this is a CRDT, not a state machine.** The states are not mutually exclusive in time: a single cheatsheet can simultaneously be LOADED in one forge instance, REFINED in another (different project), and being RE-VERIFIED on the host. The lifecycle accumulates evidence across replicas and converges by structured discipline (override discipline, manifest contracts, fingerprint comparisons). The "thinking service" the user mentioned for a future automation pass is exactly the agent that walks this loop without human intervention — collapsing MISS → PULLED → REFINED → PROMOTED into an automatic chain that increases the system's coverage over time.

**v1 scope (this change):** AUTHORED → BUNDLED-BAKED → LOADED → HIT/MISS → PULLED → REFINED. RE-VERIFIED is partial (manual `--refresh-sources` flag only; no scheduled job). PROMOTED is manual-only (`git mv`). Telemetry emission is in scope; consumption (turning telemetry into refresh decisions) is v2.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Forge image bloat from bundled sources | Per-domain budget (suggested: 50 MB per publisher, configurable in `cheatsheets/license-allowlist.toml`); single-page-HTML preference; auto-drop bundled sources whose cheatsheet's `last_verified` is > 365 days |
| Build-time fetch failures (CI network flake) | Reuse last-known-good `<cache-key>/` from build cache; emit WARN; do NOT fail the build; do NOT bump `last_verified` for failed fetches |
| Stub recipe wrong or stale | In-forge agent emits `resolved_via: pull-failed` telemetry; host-side refresh consumes; user-visible only via tray status if a pattern emerges (no per-failure popups — avoid unauthorized UX) |
| Drift fingerprint false negatives (semantic change in unchanged outline) | Accepted by design; `Last updated:` ≤ 90 days discipline catches it; v2 telemetry-driven refresh prioritization compounds |
| Project-committed cheatsheet shadows forge-bundled cheatsheet of same name | Name-collision detection in `populate_hot_paths()` extension; emit `forge-welcome.sh` warning line; project version takes precedence (project context > forge default) |
| Per-project pull cache exhaustion (RAMDISK budget) | LRU eviction within the per-project cache; cache lives on disk by default (the agent's *generated summary* lives in the 8 MB tmpfs `/opt/cheatsheets/`); soft cap configurable via `forge.pull_cache_max_mb` |
| License risk if in-forge agent caches pulled content beyond its session | Per-project ephemeral, never global; documented in the stub format; project-committed cheatsheets are SUMMARIES (the user's own work product), NOT verbatim copies of the upstream |
| Telemetry channel becomes noisy | EXTERNAL-tier auditor's existing 1 MB/min growth-rate alarm catches runaway emission; `lookups.jsonl` rotates at 10 MB |
| Repository churn from removing 48 verbatim files | One-shot cleanup commit; tombstone marker for 3 releases; CI's `check-cheatsheet-sources.sh --no-sha` is permissive during the migration window |

## Migration Plan

Phased so each phase is independently convergent:

**Phase 0 — this change (`cheatsheets-license-tiered`)**:
- Ship tier system: frontmatter v2 schema, three tiers, allowlist repurpose.
- Ship bundled-tier infrastructure: `scripts/fetch-cheatsheet-source.sh --tier=bundled`, build-time bake hook in `scripts/build-image.sh`.
- Ship pull-on-demand stub format and validator rules.
- Empty `cheatsheet-sources/` from git (tombstone, leave `.gitkeep-tombstone`).
- Existing cheatsheets: classify each into a tier (default: `bundled` if `source_urls[0]` domain is in the allowlist with `redistribution: bundled`, else `pull-on-demand`).
- Cheatsheets currently pointing at `do-not-bundle` domains (Oracle, Microsoft, etc.) get a stub `## Pull on Demand` section authored from the existing URL.

**Phase 1 — populate the long tail**:
- Classify the 139 unfetched URLs (and any others added since) into tiers.
- Author `## Pull on Demand` sections for the new pull-on-demand cheatsheets.
- Build the forge image; capture the resulting size delta and adjust per-domain budgets if needed.

**Phase 2 — distro-packaged tier wiring**:
- Add `java-21-openjdk-doc` (or whichever doc packages we want on board) to the forge image build (`flake.nix` contents or Containerfile).
- Author `cheatsheets/languages/jdk-api.md` with `tier: distro-packaged`.
- Validator confirms `package` is in image manifest.

**Phase 3 — telemetry v2 (consume)**:
- New change: `cheatsheet-telemetry-analytics`. Host-side aggregation of `lookups.jsonl` to surface top-N misses per cheatsheet.
- Refresh prioritization driven by miss rate.
- Optional: tray status-bar item showing "N cheatsheets due for refresh" (subject to user approval per `feedback_no_unauthorized_ux`).

**Phase 4 — project-committed cheatsheet promotion**:
- New change: `cheatsheet-promotion-flow`. Tooling around the `<!-- promotion-candidate -->` marker; `scripts/promote-project-cheatsheet.sh` validates and `git mv`s.
- Optional: agent self-prompts at end of session ("you generated jdk-api.md; promote to project cheatsheets/?").

## Open Questions

User-resolved defaults are recorded inline; questions remaining open are surfaced for follow-up.

1. **Forge image size budget for bundled sources.** **Resolved: ≤ 300 MB target.** Current 48 verbatim files are ~5 MB; expansion to ~150 cheatsheets × bundled sources lands in the 50–300 MB range. Per-domain budget enforcement (suggested 50 MB/publisher) lives in `cheatsheets/license-allowlist.toml`.
2. **Per-project pull-cache budget.** **Resolved: tiered by host class** — 64 MB modest / 128 MB normal / 1024 MB plentiful, auto-detected from `MemTotal`. Spill to disk is automatic. Per-tier overridable in `~/.config/tillandsias/config.toml` as `forge.pull_cache_ram_mb`. (See Decision 3 for full table.)
3. **Whether v1 ships the structural-drift fingerprint.** **Resolved: ship in v1.** Cheap, immediate value, the fetcher grows a heading-extractor (small dep — `htmlq` or a 30-line Python script).
4. **Naming-collision policy for project-committed vs forge-bundled cheatsheets.** **Resolved: project wins, BUT must declare CRDT override discipline** (`override_reason` + `override_consequences` + `override_fallback`). No silent shadowing — validator emits ERROR if a project shadow is missing any of the three fields. (See Decision 10.)
5. **Refresh cadence for bundled-tier sources.** **Resolved: per-release at minimum.** Local builds use cache-or-fetch with 30-day max age; CI passes `--max-age-days 7` so the release pipeline re-validates fresh content. Scheduled refresh script (independent of build) is v2 scope.
6. **In-forge agent write access to `/opt/cheatsheet-sources/`.** **Resolved: NO.** Agent only writes to per-project pull cache. The bundled tier is image-state, not user-state, per the existing `agent-cheatsheets` invariant ("Forge user cannot mutate cheatsheets" extends to their bundled sources).
7. **License coverage when a "bundled" cheatsheet's source domain license updates between forge releases.** **Resolved: tier-classifier re-evaluated on every build** (allowlist is a CRDT — Decision 13). A domain that was `bundled` at v0.1.172 becoming `do-not-bundle` at v0.1.173 triggers automatic flip to `pull-on-demand` with a WARN; the cheatsheet author confirms intent on the next refresh cycle.
8. **Per-URL allowlist exceptions.** **Resolved: per-domain default + per-cheatsheet tier override** (Decision 13). Per-URL entries in the TOML are not introduced in v1; mixed-license domains (raw GitHub: per-repo) are handled by the per-cheatsheet `tier:` override path.

**Still open (deferred to follow-up changes):**

- **Telemetry consumption (v2)**: aggregating `lookups.jsonl` to drive refresh prioritization. Schema is fixed in v1; analytics are out of scope.
- **Auto-promotion of project-committed cheatsheets (Phase 4)**: today the user does `git mv` manually. A self-prompting agent flow ("you generated jdk-api.md; promote?") needs the user-approval pattern from `feedback_no_unauthorized_ux`.
- **License-allowlist auto-merge from agent observations (v3)**: today the in-forge agent emits `license_drift` events; the host edits the TOML manually. v3 considers an opt-in auto-merge path with diff review.
- **Cross-project cheatsheet sharing**: violates `forge-cache-dual` today; deliberately deferred until the user articulates a shared-knowledge story that does not break per-project isolation.

## Sources of Truth

- `cheatsheets/runtime/cheatsheet-frontmatter-spec.md` — the existing frontmatter contract; v2 schema is an additive extension.
- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — the architectural rationale for the cheatsheet system as a whole.
- `cheatsheets/runtime/forge-hot-cold-split.md` — RAMDISK / disk path taxonomy; the tmpfs `/opt/cheatsheets/` and disk `/opt/cheatsheet-sources/` distinction.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — per-project ephemeral cache contract for the pull-on-demand tier.
- `cheatsheets/runtime/external-logs.md` — EXTERNAL-tier producer/consumer contract for the `cheatsheet-telemetry` role.
- `cheatsheets/utils/jq.md` — JSON Lines processing for the telemetry events; `lookups.jsonl` is `jq -c`-friendly.
- `cheatsheets/build/nix-flake-basics.md` — `dockerTools.buildLayeredImage` content path that lands `/opt/cheatsheet-sources/` in the image.
