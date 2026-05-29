---
title: Install dev quality-of-life tools (bat, git-delta, git-lfs, httpie, yq)
gap: "missing_tools: bat, delta, httpie, yq, git-lfs; essential modern developer terminal utilities absent"
category: runtime-tool
status: implemented
proposed_at: 2026-05-29T10:08:00Z
approved_at: 2026-05-29T10:08:00Z
implemented_at: 2026-05-29T10:16:00Z
evidence: "Containerfile line 21: bat, git-delta, git-lfs, httpie, yq via microdnf; line 29: git lfs install --system"
changes:
  - file: images/default/Containerfile
    description: |
      Install bat, git-delta, git-lfs, httpie, yq via microdnf at image build time.
      Run git lfs install --system to register LFS filters globally.
approval_required: orchestrator
approved_by: Antigravity (Orchestrator)
---

## Gap

A batch of high-leverage, modern developer quality-of-life and terminal utilities are missing from the default forge image:

- `bat` — syntax-highlighted cat alternative.
- `delta` — syntax-highlighting pager for git, diff, and grep output.
- `git-lfs` — Git extension for versioning large files.
- `httpie` — user-friendly command-line HTTP client.
- `yq` — portable command-line YAML processor.

Installing these tools directly at image build time significantly improves the coding agent and user terminal experience, ensuring smooth navigation of YAML-heavy configurations (OpenSpec, methodology, plan) and efficient file/HTTP diagnostics.

## Evidence

From the live diagnostics runs (`diagnostics_20260529T080843Z-summary.md` and `diagnostics_20260529T081135Z-summary.md`):
- `missing_tools` list includes: `bat`, `delta` (git-delta), `httpie`, `yq`, `git-lfs`.
- Distilled summaries and diagnostic prompt evaluations consistently identify these tools as key gaps in the terminal experience.
- The `curated-toolchain-backlog` updates specifically proposed this "Dev quality-of-life batch" for approval.

## Privacy / Isolation Assessment

- **All tools are installed as static/native packages via Fedora's official repositories (microdnf).**
- No new egress boundaries are created (httpie utilizes standard HTTP/HTTPS egress via the existing proxy rules; git-lfs routes through the standard git proxy/mirror controls).
- No new secrets, credentials, or mounts are introduced.
- **Strictly preserves the container isolation envelope (--cap-drop=ALL, no-new-privileges, keep-id, etc.).**
