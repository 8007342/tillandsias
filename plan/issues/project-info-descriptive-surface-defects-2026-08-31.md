# project-info's descriptive surface: three defects that leave the expert unable to say what the project is

Filed 2026-08-31 by forge-forge-tillandsias-claude-20260831t005516z from
in-forge probes against seed main@341ab0010, directed by the macuahuitl-fedora
orchestrator. The mechanical surface is accurate where verified (git_status
22/22 exact vs porcelain; search_code correct with a 50-of-53 truncation
notice; project_type git,nix,rust,rust-workspace all present). The descriptive
surface is not — an agent asking this expert "what am I looking at?" gets
nothing usable from any of its three describing tools. Filed for a HOST
session to drain: the answer engine is IMAGE-BAKED (project_engine:
state=ready baked=engine-contract-v4), so per 619-pfsj only an image rebuild
ships a fix.

## 1. description is the literal string "```text"

`project_info`, `project_metadata`, and `project_list` all report
description="```text" — the first line of README.md, which opens with an
ASCII-art code fence. A first-line grab needs to skip fence markers and blank
lines, or fall back to a marked description elsewhere. Verified against
`head README.md`.

## 2. name is "." or "unknown"

`project_info` reports name="."; `project_metadata` reports name="unknown".
Neither says "tillandsias" while standing in
/home/forge/src/tillandsias with TILLANDSIAS_PROJECT=tillandsias exported.

## 3. project_structure at depth=1 lists 37 files and ZERO directories

crates/ (23 crates), plan/, scripts/, methodology/, openspec/, images/,
cheatsheets/ — all omitted. The tool answers "what does this workspace look
like?" with a file listing that makes a 23-crate Rust workspace look like a
directory of loose scripts. Directories must appear at their own depth
(and the 100-entry cap should say what it dropped).

## 4 (adjacent). project_answer refuses with the wrong refusal

The canonical question ("what does this project do and what are its main
components?") returned the plan-ledger token-match refusal — verbatim the
same text as forge-plan's plan_answer refusal — instead of either an answer
or its own designed typed refusal
(`unsupported: synthesis question — missing_capability=local-inference ...`).
Two wrongs in one: the refusal names the wrong engine, and its premise is
stale here (inference_state=ready, 7 models warm). NOTE: the synthesis tier
reads TILLANDSIAS_INFERENCE_ENDPOINT, which in this forge is poisoned to
loopback by the tracked settings env leak — re-measure after
`plan/issues/dev-loopback-inference-env-leaks-into-forge-settings-2026-08-31.md`
is resolved before treating the routing as the whole story.

## What is NOT claimed

That these are regressions — no earlier baseline was probed; they may have
shipped broken. And no claim about non-Tillandsias projects, where the
generic index may behave differently.

Related: 619-pfsj (engine-vs-checkout skew — the ship vehicle for any fix),
`plan/issues/forge-expert-surface-calibration-recon-2026-08-31.md`,
`plan/issues/dev-loopback-inference-env-leaks-into-forge-settings-2026-08-31.md`.
