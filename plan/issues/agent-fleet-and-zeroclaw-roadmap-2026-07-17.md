# Agent fleet roadmap: Zen siblings today, model-split fleet next, zeroclaw LAST (local-only, experts-gated)

- Date: 2026-07-17
- Source: operator (The Tlatoāni) session directive, distilled verbatim-close
  by windows-bullo-fable5-20260717 (host session)
- Related: forge-local-experts-milestone (order 391), inference-startup-cleanup
  (order 392), tier packets 401/402,
  `images/default/config-overlay/opencode/instructions/model-routing.md`
  (fleet naming), `plan/archive/zeroclaw-unauthorized-release-violation-2026-06-27.md`
  (why zeroclaw left), inforge-meta-orchestration-transparent-push-2026-07-16.md
  (BigPickle/Hy3 in-forge lane).

## Operator context (2026-07-17)

1. **Hy3 is BigPickle's big brother** — a larger free Zen model in the same
   opencode pool (`opencode/big-pickle` is the default; Hy3 is the heavier
   sibling). Other free Zen models may be trialed for work; performance will
   decide their roles.
2. **Model-appropriate splitting is the trajectory**: as local models land in
   the inference container (EXPERTS milestone, orders 391-402) and work is
   split to appropriate LOCAL models, REMOTE work will likewise split across
   several agents (Zen siblings and beyond) by capability.
3. **Zeroclaw returns LAST, as a container, local-only**: a zeroclaw
   container will be reintroduced — but NOT yet. Sequence is deliberate:
   local inference must be figured out first so the reintroduced zeroclaw
   can be **local-inference-only**. Zeroclaw will likely be the **main
   consumer of the experts** (plan/methodology/code experts answering
   instantly instead of file browsing). Experts must work RELIABLY before
   zeroclaw comes back.

## Guardrails the reintroduction MUST carry (from the 2026-06-27 violation)

The original zeroclaw was removed as a CRITICAL violation (order-114 report,
archived): it shipped as an unauthorized second release binary and ran as a
host-resident, unisolated Unix-socket MCP server executing arbitrary
host-level tool invocations. The reintroduction inverts both failures by
construction:

- **Container, never a host binary**: lives in the enclave under the same
  isolation/dependency-graph regime as every other stack container. The ONE
  SINGLE TINY BINARY release principle is untouched — no new release
  artifact.
- **Local-only**: talks to `inference:11434` experts and enclave services
  exclusively; no remote provider credentials, no external egress beyond the
  enclave policy.
- **Tlatoāni-gated**: filing the packet is not authorization. Implementation
  starts only on explicit operator approval AFTER the experts milestone
  (391) demonstrates reliability (its exit criteria green). Any release
  surface change needs separate explicit approval per the standing rule.

## Plan wiring

- Pending packet `zeroclaw-local-only-container-reintroduction`
  (provisional windows-260717-1) holds the gate; depends_on
  forge-local-experts-milestone. Status stays `pending` until The Tlatoāni
  flips it — reliability of experts is the precondition, not calendar time.
- Fleet naming recorded agent-facing in model-routing.md (Zen siblings
  section).
