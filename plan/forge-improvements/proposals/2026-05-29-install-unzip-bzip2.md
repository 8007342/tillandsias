---
title: Install unzip and bzip2 for archive extraction
gap: unzip and bzip2 are not installed in the forge image; needed for extracting downloaded SDKs and archives
category: shell-tool
status: proposed
proposed_at: 2026-05-29T10:50:00Z
changes:
  - file: images/default/Containerfile
    description: Add `unzip bzip2` to the microdnf install RUN layer. unzip is a near-universal requirement for extracting tool archives (SDKs, binaries, etc). bzip2 handles .bz2 compressed archives.
approved_by: null
---

## Gap

The forge image does not include `unzip` or `bzip2`. These are basic utilities needed for:

1. **Extracting SDK archives**: Flutter SDK, Android SDK command-line tools, and many other tool distributions ship as `.zip` files.
2. **Extracting compressed archives**: `.bz2` files are commonly used for toolchain distributions.
3. **Agent-driven setup workflows**: Agents that need to download and install tools must be able to extract standard archive formats.

Currently only `tar`, `gzip`, and `xz` are installed (line 18 of Containerfile). The Fedora Minimal base does not include `unzip` or `bzip2` by default.

## Evidence

- `images/default/Containerfile` line 18: `tar gzip xz` are installed — no `unzip` or `bzip2`
- Many SDKs (Flutter, Android cmdline-tools, Gradle distributions) ship as `.zip` archives

## Safety

- Standard Fedora Minimal packages — no untrusted downloads.
- Minimal size impact (~2 MB total).
- No credentials or secrets are involved.
