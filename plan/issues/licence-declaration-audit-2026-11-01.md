# Licence declaration audit — 2026-11-01

Order 1958-yfib. Operator request (2026-11-01): "our files might have the wrong
licenses, some agents randomly hallucinate licenses for new files and we
rarely check. The other day I saw some MIT license in one of our own files."
Reference: `LICENSE` is GPL-3.0; `Cargo.toml` `[workspace.package].license` is
`GPL-3.0-or-later`. Audited on `origin/linux-next` at `c6e92749d`, host
macuahuitl, worktree outside the checkout.

## Where a licence is declared, and what it said

| Site | Population | Finding |
|---|---|---|
| `Cargo.toml` `license =` | 27 workspace crates | 23 `license.workspace = true`, 4 literal `GPL-3.0-or-later` (browser-mcp, headless, plan, msg). No mismatch. |
| `package.json` `"license"` | 3 of ours (`images/web-wrangler`, `observatorium`, `.opencode`) | none declares a licence (allowed). The one `"license": "MIT"` is `openspec/litmus-tests/groundtruth/fixtures/generic-project/git-project/package.json`, a fixture imitating a third-party repo, not shipped. Not ours. |
| `SPDX-License-Identifier:` headers | every tracked text file | none in the tree. |
| `LICENSE*` / `COPYING*` outside the root | tracked | only `crates/tillandsias-core/data/devices/upstream/{devtools,playwright}-LICENSE`: vendored upstream (BSD-3-Clause, Apache-2.0, read from the texts), kept, credited in the ledger. |
| OCI `org.opencontainers.image.licenses` | 19 `images/*/Containerfile*` + `observatorium/Containerfile` | **NONE set the label. Every built image inherits its base layer's.** Measured on the operator's host: `localhost/tillandsias-inference:latest` -> `MIT`, vendor `Fedora Project` (fedora-minimal's label); `localhost/tillandsias-imagegen:latest` -> `MIT`; `localhost/tillandsias-router:latest` -> `Apache-2.0`, vendor `Light Code Labs` (caddy's). **This is the MIT the operator saw.** |
| Third-party licence fields we record | `studios.json`, `images/studio/registry.lua`, `custom-nodes.toml`, `licence-register.tsv`, `models.tsv`, `tiers.tsv`, `cheatsheets/license-allowlist.toml` | describe UPSTREAM licences (GrapesJS BSD-3-Clause, Decap MIT, Tina Apache-2.0, Puck MIT, Onlook Apache-2.0, ComfyUI-GGUF Apache-2.0, models openrail++/apache-2.0). Correct as records; listed as vendored paths in the guard. |
| openspec / docs claims | `grep -ri licen openspec/specs` | `cheatsheets-license-tiered` and friends describe third-party tiers; no claim that Tillandsias is other than GPL. |

Mismatches of our own declarations: **20**, all the same shape (an image with
no licence label of its own), worst instance the forge-facing
`tillandsias-inference` and `tillandsias-imagegen` images labelled MIT.
Mislabelled source files of ours: **0**.

## What was fixed in this packet

- Each of the 20 Containerfiles now sets
  `LABEL org.opencontainers.image.licenses="GPL-3.0-or-later"` after its final
  `FROM`, with a comment that the label is Tillandsias's recipe and that base
  images and packages are credited in `docs/credits/stack.v1.json`.
- Guard `scripts/lua/check-own-licence-declarations.lua` (wired into
  `./build.sh --check`, fixture `scripts/lua/test-own-licence-declarations.lua`,
  `litmus:own-licence-declarations` bound to `ci-release`): red on the pre-fix
  tree (`violation:own-licence-declarations:20`), green after.
- Ledger generator `scripts/lua/build-stack-ledger.lua` ->
  `docs/credits/stack.v1.json` (901 nodes, 1941 edges, 51 components; licence
  families: permissive 665, weak-copyleft 27, strong-copyleft 2, model 3,
  service 15, unknown 188). `--check` is byte-stable and advisory in
  `./build.sh --check`; refreshed at each stable release (1958-jyfk).

## Ambiguous, for the operator

1. **Scope of the OCI label.** The label now says GPL-3.0-or-later for every
   image, meaning the Tillandsias recipe. The contents are mixed: the vault
   image is `FROM docker.io/hashicorp/vault:1.18` (HashiCorp moved Vault to
   BUSL-1.1 in 1.15 — not verified from a file in this tree, so the ledger
   says `unknown`); the CUDA imagegen image is `FROM nvidia/cuda` (NVIDIA
   EULA); the imagegen-studio image clones ComfyUI (GPL-3.0 per its repo,
   `unknown` in the ledger for the same reason). If the operator prefers
   compound labels (`GPL-3.0-or-later AND BUSL-1.1`), those three Containerfiles
   are the edit and the guard accepts any expression that starts with ours.
2. **188 `unknown` licences in the ledger**: 157 distro packages (fedora/
   alpine/debian — their licences live inside the image's package database,
   not in this tree), 13 base images, 3 pip packages (torch, torchvision, the
   ComfyUI requirements file), 5 studios' homepages, 11 cheatsheet publishers
   whose allowlist `license` value is a terms-of-use label. Reading the package
   databases at image build (`rpm -qa --qf '%{LICENSE}'`, `apk info -L`) would
   turn most of these into declared values; it is a follow-up, not a guess.
3. **Hashed cheatsheet publishers** (`docs:azure.microsoft.com` etc.) carry
   non-SPDX `license` strings from the allowlist; the page shows them as
   unknown family with the raw string. Fine or reclassify?

## Method notes

- The guard reads `git ls-files`, so untracked scratch never counts; it
  excludes `.claude/worktrees/` and `scratch/`.
- A guard that quotes `SPDX-License-Identifier: x` in its own header refuses
  itself once tracked (a guard cannot tell mention from use); the header now
  describes the pattern in prose.
- `verdict.emit` writes straight to stdout while `io.stdout:write` buffers, so
  findings printed before the verdict appeared after it; the guard flushes.
