---
tags: [meta, cheatsheet-system, tier, license, bundled, pull-on-demand, distro-packaged]
languages: []
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://spdx.org/licenses/
  - https://docs.fedoraproject.org/en-US/packaging-guidelines/LicensingGuidelines/
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Cheatsheet tier system

@trace spec:cheatsheets-license-tiered, spec:agent-cheatsheets
@cheatsheet runtime/cheatsheet-frontmatter-spec.md

**Use when**: You're authoring a cheatsheet and need to pick a tier, or reading a cheatsheet and need to know what `tier:` in its frontmatter implies for runtime behavior.

## Provenance

- SPDX license list: <https://spdx.org/licenses/> — canonical short-IDs used in `cheatsheets/license-allowlist.toml`'s `license` field
- Fedora packaging licensing guidelines: <https://docs.fedoraproject.org/en-US/packaging-guidelines/LicensingGuidelines/> — distro-packaged tier inherits package-manager license acceptance
- `openspec/specs/cheatsheets-license-tiered/spec.md` — normative spec for the three-tier model
- `openspec/changes/archive/2026-04-27-cheatsheets-license-tiered/design.md` Decision 1 — three-tiers-not-two rationale
- **Last updated:** 2026-04-27

## Quick reference — three tiers

| Tier | Source location at runtime | License constraint | Build-time work | Runtime work |
|---|---|---|---|---|
| `bundled` | `/opt/cheatsheet-sources/<host>/<path>` (image-baked, RO) | Redistribution permitted (allowlisted SPDX in `cheatsheets/license-allowlist.toml`) | Fetch + SHA-pin at forge build | None — agent reads locally |
| `distro-packaged` | OS-installed (e.g., `/usr/share/javadoc/java-21-openjdk/api/index.html`) | Vendor-shipped via the package manager; license accepted at install | Validate package is in the forge image manifest | None — agent reads OS-installed file |
| `pull-on-demand` | `~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>` (per-project ephemeral; tmpfs-overlay lane with disk spillover) | Redistribution forbidden or unclear | Validate stub completeness only | Agent fetches via proxy when depth is needed |

## Common patterns

### bundled — Rust documentation (canonical example)

```yaml
---
tier: bundled
local: /opt/cheatsheet-sources/doc.rust-lang.org/book/index.html
source_urls: [https://doc.rust-lang.org/book/]
image_baked_sha256: <16-byte hex>      # set at forge build
structural_drift_fingerprint: <16 hex> # set at forge build
---
```

`doc.rust-lang.org` is in `cheatsheets/license-allowlist.toml` with `redistribution = "bundled"`, `default_tier = "bundled"`. The forge build fetches the URL into the image at `/opt/cheatsheet-sources/...` and pins the SHA. Agents read the local file with zero network.

### distro-packaged — JDK API docs

```yaml
---
tier: distro-packaged
package: java-21-openjdk-doc
local: /usr/share/javadoc/java-21-openjdk/api/index.html
source_urls: [https://docs.oracle.com/en/java/javase/21/docs/api/]   # upstream truth
---
```

The package manager handled both the license acceptance (at install) and the bytes (under `/usr/share/...`). The cheatsheet declares the package; the validator confirms it's in the forge image's `flake.nix` `contents` or `Containerfile` `dnf install` lines. **Reuses bytes the OS already has — no duplicate `/opt/cheatsheet-sources/` copy.**

### pull-on-demand — Oracle JDK API (the upstream side)

```yaml
---
tier: pull-on-demand
pull_recipe: see-section-pull-on-demand
source_urls: [https://docs.oracle.com/en/java/javase/21/docs/api/]
---
```

`docs.oracle.com` is in `cheatsheets/license-allowlist.toml` with `redistribution = "do-not-bundle"` (Oracle FTC forbids redistribution). The forge image carries only this cheatsheet's hand-curated summary plus a `## Pull on Demand` recipe. When an agent needs depth, it runs the recipe to materialize the source into the per-project pull cache. See `runtime/cheatsheet-pull-on-demand.md` for the recipe format.

## Common pitfalls

- **Forgetting to set `tier`** — the validator infers from `cheatsheets/license-allowlist.toml`, but the safe default for unknown domains is `pull-on-demand`. If you meant `bundled`, the forge image will lack the source and the agent will hit the recipe instead. Set `tier:` explicitly when in doubt.
- **Claiming `tier: bundled` for an off-allowlist domain** — validator emits ERROR (license risk). Add the domain to `cheatsheets/license-allowlist.toml` with the right `redistribution` field, OR change the cheatsheet's `tier` to `pull-on-demand`.
- **Declaring `tier: distro-packaged` without the package in the image manifest** — validator confirms the `package` field appears in `flake.nix` `contents` (or sibling sources). If not present, ERROR. Add the package to the forge image first.
- **Setting `local:` in a `pull-on-demand` cheatsheet** — forbidden. The cache path is per-project ephemeral, not author-knowable. Validator emits ERROR.
- **Editing a `bundled` source's bytes directly inside the forge** — the forge user (UID 1000) cannot write to `/opt/cheatsheet-sources/` (image-state, not user-state). Refresh happens at forge build time, not at runtime.
- **Treating the tier as immutable** — license-allowlist.toml is a CRDT (see `cheatsheet-crdt-overrides.md` for the discipline). A domain that flips from `bundled` to `do-not-bundle` between forge releases auto-flips its cheatsheets to `pull-on-demand` at the next build, with a WARN.

## See also

- `runtime/cheatsheet-frontmatter-spec.md` — full v2 schema
- `runtime/cheatsheet-pull-on-demand.md` — stub format for the third tier
- `runtime/cheatsheet-crdt-overrides.md` — project-committed shadow flow
- `runtime/cheatsheet-lifecycle.md` — the convergence loop across all tiers
- `runtime/forge-hot-cold-split.md` — RAM/disk taxonomy; `/opt/cheatsheet-sources/` is image-baked COLD, the pull cache is the tmpfs-overlay lane
- `cheatsheets/license-allowlist.toml` — the tier classifier
