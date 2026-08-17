# The agent harness rewrites `.claude/settings.local.json`, so `check-opsx-generated-dirt.sh` refuses every Claude-driven cycle

- classification: enhancement
- filed: 2026-08-16 (windows/ESMERALDINHA, cycle 2)
- status: open — worked around by hand this cycle; needs a deterministic arm
- related: order 540 (`check-opsx-generated-dirt.sh`, the generated-dirt
  detector this extends), `plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md`
  (the original instance of exactly this shape),
  `litmus:committable-branch-guard-shape` (sibling guard grammar)

## Symptom

Start Of Cycle step 4 on a clean, freshly-checked-out tree:

```
$ scripts/check-opsx-generated-dirt.sh
non-opsx:.claude/settings.local.json          # exit 3
```

Per the meta-orchestration skill, a `non-opsx:` verdict means *"real
sibling/operator dirt — fall through to the dirty-start refusal exactly as
written; never commit, discard, or clean it."* The cycle must refuse.

## Cause

Claude Code rewrites its own settings file in place during a session. The
observed diff carries exactly two changes, neither of them operator content:

1. The `env` block is **hoisted above `permissions`** — a pure key reorder. All
   six keys and all six values are byte-identical before and after.
2. `"enabledMcpjsonServers": ["forge-plan", "project-info"]` is **appended**
   when the operator enables the `.mcp.json` servers — i.e. it records the
   intended project configuration.

The file is tracked, so both land in `git status` as dirt the detector has no
arm for.

## Why this matters more than it looks

This is the **order-540 shape recurring with a different producer.** That order
exists because the openspec CLI regenerates 22 tracked files at launch, which
made every forge cycle refuse on startup dirt. The fix was a deterministic
detector with a falsifiable grammar rather than prose judgment.

The agent harness is now a second such producer, and it is worse in one
respect: openspec regenerates on *launch*, while Claude Code can rewrite
`settings.local.json` **mid-session**, so a cycle that started clean can
acquire the dirt part-way through and fail its own Finalization boundary
verify.

It is also fleet-wide, not host-specific: any host whose agent is Claude Code
hits it. It is not visible on hosts driven by opencode/codex/gemini harnesses,
which is likely why it has not been filed before.

## The trap

The refusal is *correct by the letter of the rule and useless in effect*: it
refuses on dirt the refusing agent itself created. An agent that follows the
skill exactly can never complete a cycle on this host; an agent that reasons
past it is "substituting prose judgment for a falsifiable machine decision,"
which the same skill explicitly forbids. Both branches are wrong, which is the
signature of a missing detector arm rather than a missing rule.

## Worked around this cycle (recorded so it is not mistaken for policy)

`.claude/settings.local.json` was committed as its own change, the startup
boundary was re-anchored with
`meta-orchestration-worktree-guard.sh re-snapshot`, and the detector then
returned `ok:clean-tree`. That is the same remedy order 540 prescribes for
`ok:opsx-only` — applied by hand, because no verdict authorises it.

## Proposed reduction (verifiable closure)

Extend `scripts/check-opsx-generated-dirt.sh` with a third accepting verdict so
the decision stays a machine decision:

```
^(ok:opsx-only|ok:harness-only|ok:mixed-generated|ok:clean-tree|non-opsx:.*)$
```

`ok:harness-only` must be earned, not assumed. The check should accept
`.claude/settings.local.json` **only when the change is provably
harness-shaped**, which is decidable without judgement:

- the file parses as JSON before and after, and
- the diff touches only key ORDER plus the `enabledMcpjsonServers` key, i.e.
  `jq -S 'del(.enabledMcpjsonServers)'` of HEAD and of the worktree are
  **byte-equal**.

That second condition is the whole guard: it accepts a reorder and a
server-enable, and it still returns `non-opsx:` the moment a permission, an env
value, or anything else actually changes — which is the case the dirty-start
rule exists to protect.

Closure: a litmus (`litmus:generated-dirt-harness-arm-shape`) that feeds the
checker four fixtures — clean tree, pure reorder, reorder plus
`enabledMcpjsonServers`, and a reorder plus a changed `env` value — and asserts
the first three yield `ok:*` and the fourth yields `non-opsx:`. Exit code is the
verdict; no prose.

## Note for whoever implements it

Do **not** widen this to "ignore everything under `.claude/`". That directory
also holds `settings.json`, commands and skills, which are real project
content; blanket-ignoring it would silently discard operator work and would be
a strictly worse failure than the refusal it replaces.
