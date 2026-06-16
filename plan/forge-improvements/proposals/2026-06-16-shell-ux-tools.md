---
title: Install shell UX tools (tmux, fzf, eza, starship, zoxide, lazygit)
gap: "missing_tools: tmux, fzf, eza, starship, zoxide, lazygit — developer shell experience enhancements"
category: shell-tool
status: proposed
proposed_at: 2026-06-16T08:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install shell UX tools: tmux (microdnf), fzf (microdnf or git),
      eza (microdnf as eza), starship (curl-sh or cargo install),
      zoxide (cargo install), lazygit (go install or GitHub release).
      Add to existing shell configs to enable automatic integration.
---

## Gap

Multiple diagnostic runs (`diagnostics_20260603T044258Z-summary.md`,
`diagnostics_20260603T220627Z-summary.md`,
`diagnostics_20260614T062505Z-summary.md`,
`diagnostics_20260614T160501Z-summary.md`,
`diagnostics_20260614T230648Z-summary.md`) report missing shell UX tools.

These tools significantly improve the interactive development experience:
- **tmux**: Terminal multiplexer for persistent/resumable sessions
- **fzf**: Fuzzy finder for file/command search
- **eza**: Modern `ls` replacement with icons and color coding
- **starship**: Fast shell prompt with contextual information
- **zoxide**: Smarter `cd` command with learning
- **lazygit**: Terminal UI for Git operations

## Evidence

- Reported across 5+ diagnostics files
- Tools consistently appear in `missing_tools` arrays
- These are standard in modern developer environments

## Privacy/Isolation Assessment

- tmux, fzf, eza available via microdnf — same envelope as existing packages
- starship, zoxide, lazygit install as static binaries via cargo/go
- All tools run as the forge user; no daemon or root requirements
- starship prompt may need env var configuration; ensure no network queries
- **Safe within the existing privacy/isolation envelope**
