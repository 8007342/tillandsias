---
tags: [git, attribution, agents, provenance, co-authored-by, trailers, dco]
languages: [bash]
since: 2026-06-16
last_verified: 2026-06-16
sources:
  - https://github.blog/news-insights/product-news/commit-together-with-co-authors/
  - https://docs.github.com/en/pull-requests/committing-changes-to-your-project/creating-and-editing-commits/creating-a-commit-with-multiple-authors
  - https://git-scm.com/docs/git-interpret-trailers
  - https://git-scm.com/docs/SubmittingPatches
  - https://aider.chat/docs/git.html
  - https://github.com/microsoft/vscode/issues/314311
  - https://datatracker.ietf.org/doc/html/draft-morrison-identity-attributed-commits-01
  - https://bence.ferdinandy.com/2025/12/29/dont-abuse-co-authored-by-for-marking-ai-assistance/
  - https://fabiorehm.com/blog/2026/03/02/our-coding-agent-commits-deserve-better-than-co-authored-by/
authority: high
status: current
tier: committed
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: true
---
# Git commit identity & attribution for agentic work

@trace spec:cheatsheet-tooling

**Use when**: deciding how AI-agent / LLM-authored commits are attributed in git
so the real human stays accountable AND which agent/model produced the work is
transparent and machine-traceable (GitHub contributor graphs, `git blame`,
provenance audits).

> **Provenance caveat:** sources below are primary/authoritative (GitHub, git
> upstream docs, tool docs, an IETF draft). The deep-research adversarial
> re-verification pass on 2026-06-16 was cut short by an account session limit,
> so claims are cited-but-not-independently-reverified this round. Re-verify
> against the linked canonical sources before treating any single detail as
> settled.

## Provenance

- github.blog "Commit together with co-authors" — origin of the GitHub
  `Co-authored-by` trailer (2018).
- docs.github.com "Creating a commit with multiple authors" — canonical format
  + the email-must-match-a-GitHub-account rule for attribution.
- git-scm `git-interpret-trailers` / `SubmittingPatches` — the trailer grammar.
- aider.chat/docs/git.html — Aider's author/committer `(aider)` model.
- github.com/microsoft/vscode#314311 — Copilot's `Co-authored-by: Copilot`.
- datatracker.ietf.org draft-morrison-identity-attributed-commits-01 — proposed
  `Acted-By:`/`Executed-By:`/`Drafted-With:` tiers.
- bence.ferdinandy.com / fabiorehm.com — the "don't abuse Co-authored-by for AI"
  argument (an AI is not a legal co-author).
- **Last updated:** 2026-06-16

## Quick reference

| Mechanism | Format | Notes |
|---|---|---|
| GitHub co-author | `Co-authored-by: NAME <EMAIL>` | In the **trailer block**; blank line before it; one per line, no blank lines between co-authors. Email must be the one on the GitHub account (or `<id>+<user>@users.noreply.github.com`) to render/attribute. |
| Git trailer grammar | `Key: value` (RFC-822 style) | Trailer block = group of `Key: value` lines at the **end** of the message, preceded by a blank line. Key has no spaces; capitalize-first convention (`Signed-off-by`, not `Signed-Off-By`). |
| DCO sign-off | `Signed-off-by: Human <email>` | A human attestation (Developer Certificate of Origin). An autonomous agent must **not** forge a human's sign-off. |
| Parse trailers | `git log --format='%(trailers:key=Co-authored-by)'` / `git interpret-trailers --parse` | Machine-readable extraction. |

### What current tools actually emit

- **Claude Code** (this repo's convention): `Co-Authored-By: Claude <noreply@anthropic.com>`.
- **GitHub Copilot**: `Co-authored-by: Copilot <copilot@github.com>` (VS Code setting `git.addAICoAuthor`). Microsoft has signalled moving toward explicit consent, applying it only to AI changes, possibly an `Assisted-by` trailer, and adding model info.
- **Aider**: appends `(aider)` to the git author/committer **name** by default; `--attribute-co-authored-by` switches to a `Co-authored-by` trailer instead; author and committer identities are independently toggleable (`--no-attribute-author` / `--no-attribute-committer`).
- **OpenAI Codex CLI**: has its own commit-attribution behavior (see source).

## Recommended pattern for this project

Goal (operator direction, 2026-06-16): **keep the real GitHub-login human
identity as the commit AUTHOR** (preserves contributor graph, streaks, blame,
and accountability) **and mark the agent + model transparently in a
machine-parseable trailer**.

```
<subject>

<body>

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Generated-By: tool=claude-code model=claude-opus-4-8 ctx=1m
```

- **Author/committer** = the human (`git config user.name/.email` from the
  GitHub login). Do **not** anonymize — agentic work should be transparent, not
  hidden.
- **Per-agent distinction**: vary the human-readable co-author name + a
  structured `Generated-By:`/`Assisted-By:` trailer so Claude vs ChatGPT vs
  OpenCode vs Antigravity vs a local model are distinguishable, e.g.
  `Generated-By: tool=opencode model=llama-3.1-70b params=q4` for local models
  (encode size/quant/params where they matter for backtracking origins).
- **Machine-parseable**: keep it to `Key: value` trailers (no spaces in keys)
  so `git log --format='%(trailers:key=Generated-By)'` and audits work.

## Common pitfalls

- **`Co-authored-by` attribution silently fails** if the email isn't tied to a
  GitHub account — use the account email or its `…@users.noreply.github.com`.
- **Trailer block breaks** if there's no blank line before it, or if non-trailer
  prose is interleaved (git needs the tail to be ≥25% recognizable trailers).
- **Don't let an agent emit `Signed-off-by` for a human** — DCO sign-off is a
  human legal attestation; agents use a separate provenance trailer.
- **The "Co-Authored-By: Claude" convention is contested** — some argue an AI is
  not a co-author (use `Assisted-by`/`Generated-by` instead); the IETF draft
  proposes `Drafted-With:` for AI and reserves co-author/`Acted-By` for humans.
  This project keeps `Co-Authored-By: <model>` for GitHub rendering **plus** a
  structured trailer; revisit if a standard converges.
- **Free-form model strings aren't parseable** — prefer `key=value` tokens
  inside the trailer value over prose.

## See also

- `concurrent-git/agent-handoff.md`
- `concurrent-git/branches.md`
- `agents/claude-code.md`
