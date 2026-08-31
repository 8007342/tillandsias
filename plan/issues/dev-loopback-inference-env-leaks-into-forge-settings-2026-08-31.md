# The dev host's loopback inference env is tracked in .claude/settings and leaks into every forge

Filed 2026-08-31 by forge-forge-tillandsias-claude-20260831t005516z while
root-causing `expert_capability`'s `embed_endpoint=unreachable` degradation,
directed by the macuahuitl-fedora orchestrator. This is the defect behind the
only degradation flag the forge-plan expert reports in this forge, and it kills
the L1 embedding tier (spec_answer retrieval, 712-r5x8 / 919-vvyv) on every
claude-harness forge launched from this repo.

## Measured, in the running forge

    tr '\0' '\n' < /proc/<forge-plan-mcp-pid>/environ | grep -E 'EMBED|INFERENCE'
    -> TILLANDSIAS_INFERENCE_ENDPOINT=http://127.0.0.1:11434
    -> TILLANDSIAS_EMBED_ENDPOINT=http://127.0.0.1:11434/v1
    (TILLANDSIAS_SPEC_EXPERT_ENDPOINT=http://127.0.0.1:11434/v1 in session env too)

    curl -m 3 http://127.0.0.1:11434/api/tags   -> 000 (nothing listens on forge loopback)
    curl -m 5 http://inference:11434/api/tags   -> 7 models, incl. nomic-embed-text
                                                   (the exact configured TILLANDSIAS_EMBED_MODEL)

So the endpoint is wired-but-dead while a healthy ollama serving the right
model sits one DNS name away. `_tillandsias_expert_embed_state` correctly
reports `unreachable` (probe is fine; the value it probes is wrong).

## Root cause — not the in-container plumbing

Neither in-container derivation produced the value:

- `images/default/lib-common.sh:1017` derives from `OLLAMA_HOST` — unset here,
  so it left the endpoint unset (matching the startup context's
  `embed_endpoint=unset` at generation time 00:35Z).
- `lib-dev-env.sh`'s loopback default is gated on `tillandsias_exec_env`=dev,
  and `/run/.containerenv` exists here, so it no-ops (correctly).

The value arrives from the HARNESS: the repo's tracked
`.claude/settings.json` and `.claude/settings.local.json` both carry an `env`
block pinning all three endpoints to loopback. Claude Code injects settings
env into every spawned process — which is exactly the observed distribution:
the MCP servers and every Bash-tool shell carry the loopback values; the
harness process itself does not.

Provenance: `009fe5257` (2026-08-13, "feat(dev-env): local inference for the
bare-metal expert system") added the block to settings.local.json for the
bare-metal dev host, where loopback is the CORRECT 718-nkm2 design;
`b1cd7e354` (2026-08-17) carried it into tracked settings.json. Both files are
git-tracked, so the operator's per-host dev configuration rides into every
clone — including forges, where 127.0.0.1:11434 is nothing and the enclave
name is `inference:11434`. Every in-forge default defers to it because
"explicit operator value always wins" is the documented contract everywhere
these variables are read.

## Why this was not fixed in place (orchestrator stop-rule applied)

- Flipping the tracked values to `inference:11434` breaks the bare-metal dev
  host — the exact outage lib-dev-env.sh was built to end (that name only
  resolves inside the forge's podman network).
- Removing the env block from the tracked files fixes forges (in-forge
  defaults then resolve `inference:11434`) and dev MCP servers (the dev hook
  covers them), but drops the variables for non-MCP dev tooling
  (spec-index-ensure.sh, refusal-calibration scripts) that the operator
  wired them for — an operator-workflow decision, not a forge-side one.
- The acceptance check (expert_capability reporting the degradation cleared)
  is unreachable in-session regardless: the running MCP servers inherited the
  env at spawn. This is `relaunch-required` skew by the 569 vocabulary.

## Candidate fixes, for whoever owns the decision

(a) Move the dev loopback block OUT of tracked files into the dev host's
    untracked settings (and stop tracking settings.local.json — it is the
    harness's designated personal file). Smallest diff; one manual step on
    each bare-metal dev host.
(b) Have the forge image own a stronger-precedence settings surface
    (managed settings) that pins the enclave endpoints in-forge, shadowing
    whatever the repo carries. No worktree dirt, survives operator settings
    changes; new plumbing in images/default.
(c) Entrypoint rewrites the in-container settings file after clone — rejected
    here: it dirties a tracked file in every forge worktree.

## What is NOT claimed

That spec_answer works once the endpoint is right — the L1 tier also needs a
built spec index (`/opt/tillandsias/spec-index` is mounted here; untested).
And no claim about opencode/codex-harness forges: only the claude harness was
measured to inject settings env this way.

Related: 712-r5x8 (embed_endpoint discoverability — this is its "wired but
not answering" arm), 919-vvyv (fresh-forge embed wiring assumed OLLAMA_HOST),
718-nkm2 (the dev loopback design this config belongs to), 569 (skew
vocabulary), order 531,
`plan/issues/forge-expert-surface-calibration-recon-2026-08-31.md`.
