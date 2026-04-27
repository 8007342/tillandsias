---
tags: [list, of, kebab-case, keywords]
languages: [list-of-language-slugs]
since: YYYY-MM-DD
last_verified: YYYY-MM-DD
sources:
  - https://primary-authoritative-source.example/
authority: high                       # high | medium | community
status: current                       # current | draft | stale | deprecated

# v2 — tier classification (cheatsheets-license-tiered)
# Omit `tier` to let the validator infer from cheatsheets/license-allowlist.toml.
tier:                                 # bundled | distro-packaged | pull-on-demand
summary_generated_by: hand-curated    # hand-curated | agent-generated-at-build | agent-generated-at-runtime
bundled_into_image: true              # true iff tier in {bundled, distro-packaged}
committed_for_project: false          # true iff this lives under <project>/.tillandsias/cheatsheets/

# Tier-conditional fields — uncomment ONLY the row matching `tier`:
# image_baked_sha256:                 # bundled only — set at forge build time
# structural_drift_fingerprint:       # bundled only — set at forge build time
# local:                              # bundled OR distro-packaged — absolute path inside the forge image
# package:                            # distro-packaged only — OS package name
# pull_recipe: see-section-pull-on-demand   # pull-on-demand only

# Shadow-discipline fields — uncomment ALL FOUR ONLY when shadowing a forge default:
# shadows_forge_default: <relative/path/to/forge/cheatsheet.md>
# override_reason: |
#   This project doesn't FOO because BAR.
# override_consequences: |
#   Agents working on this project MUST NOT use FOO patterns. Cost: ...
# override_fallback: |
#   If the override conditions don't apply, do X instead.
---

# <Tool / Language Name>

@trace spec:agent-cheatsheets, spec:cheatsheets-license-tiered

**Version baseline**: <pinned version from images/default/Containerfile, e.g. "Python 3.13.x">
**Use when**: <one-line elevator pitch — the situation this cheatsheet covers>

## Provenance

- <https://primary-authoritative-source.example/> — what this source covers (the canonical reference)
- **Last updated:** YYYY-MM-DD

## Tier classification

Pick exactly one tier per cheatsheet. See `runtime/cheatsheet-tier-system.md` for the decision rule. Quick guide:

| If the upstream source is… | Tier |
|---|---|
| License-permissive AND domain in `cheatsheets/license-allowlist.toml` with `default_tier = bundled` | `bundled` |
| Shipped by the forge image's package manager (e.g., `java-21-openjdk-doc`) | `distro-packaged` |
| Redistribution-restricted OR off-allowlist (default) | `pull-on-demand` |

For `pull-on-demand`, ALSO add a `## Pull on Demand` section with the materialize recipe — see `runtime/cheatsheet-pull-on-demand.md`.

## Quick reference

| Command / Pattern | Effect |
|---|---|
| `cmd flag` | what it does |
| `cmd subcmd` | what it does |

(Replace the table with bullets if the content is more prose-shaped than tabular. Keep it scannable in <30 seconds.)

## Common patterns

### Pattern 1 — short title

```language
short snippet showing the pattern
```

What it does, when to reach for it.

### Pattern 2 — short title

```language
short snippet
```

(3–5 patterns total. Each ≤ 10 lines of code.)

## Common pitfalls

- **Pitfall 1** — concrete description of the trap. What goes wrong, and the fix.
- **Pitfall 2** — concrete description.
- (3–10 pitfalls. The most valuable section — agents read this first when something breaks.)

## See also

- `<category>/<other-cheatsheet>.md` — relationship in one phrase
- `<category>/<other-cheatsheet>.md` — relationship in one phrase
