# Knowledge Base

Project-agnostic source of truth for the tech stack powering Tillandsias.
Cheatsheets live under `cheatsheets/` organized by domain. They capture
hard-won operational knowledge so debugging sessions are never repeated.

## Cheatsheet format

Every cheatsheet is a Markdown file with YAML frontmatter:

```yaml
---
id: infra/podman-rootless
title: "Podman rootless networking"
upstream: "https://docs.podman.io/..."
version_pinned: "5.4"
last_verified: "2026-03-29"
authority: official        # official | community | derived
tags: [podman, rootless, namespaces]
---
```

The body is focused Markdown: short intro, then sections with commands,
flags, gotchas, and cross-references. No tutorials -- just the facts.

## Adding a new cheatsheet

1. Pick the right subdirectory (`infra/`, `lang/`, `frameworks/`, etc.).
2. Create the `.md` file with valid frontmatter (see above).
3. Add a matching entry in `manifest.toml` under `[cheatsheets.<id>]`.
4. Keep it under 200 lines. Split if it grows beyond that.

## Verifying freshness

Each cheatsheet pins an upstream version. When upstream ships a new
release, update `version_pinned` and `last_verified` in both the
frontmatter and `manifest.toml`. The `last_full_audit` field in
`manifest.toml` tracks the last time all cheatsheets were checked.

## Directory layout

```
cheatsheets/
  infra/        # Container runtimes, namespaces, networking
  lang/         # Rust, Nix expressions, shell
  frameworks/   # Tauri, tokio, notify
  packaging/    # Nix flakes, OCI images
  formats/      # TOML, postcard, OCI spec
  ci/           # GitHub Actions, release workflows
```
