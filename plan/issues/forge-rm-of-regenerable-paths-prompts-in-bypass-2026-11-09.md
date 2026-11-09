# PROPOSAL: no rm prompt inside the forge's safe roots (order 2065-baby)

Filed 2026-11-09 from the demon_attack forge session (demon-attack-3e),
relayed by macuahuitl-fedora. **This is a policy change and needs operator
approval before anything lands.**

## Observed (reported by the forge session)

`rm` needed manual approval even in bypass mode, for regenerable paths:
`.dart_tool`, `build/*`, `.claude/worktrees` (via
`git worktree remove --force`), and scratchpad files. With src at 89–100%
full (2065-5vcv), every cleanup waited on a human.

## Which layer prompted

The forge's command policy did not. On 2026-11-09 I fed the four command
shapes to `tillandsias-plan policy classify-bash --hook`, which is the
decider behind `images/default/bash-policy-hook`. The binary was built from
linux-next on tlatoanis-macbook-air, and the cwd was
`/home/forge/src/demon_attack`.

```
rm -rf .dart_tool                                 => silent allow, rc=0
rm -rf build/web                                  => silent allow, rc=0
git worktree remove --force .claude/worktrees/a   => silent allow, rc=0
rm -f /tmp/claude-1000/x/scratchpad/a.png         => silent allow, rc=0
```

The forge's `config-overlay/claude/settings.json` has no `permissions`
block. So the prompt most likely came from Claude Code's own built-in check
on recursive or forced deletion, which bypass mode does not skip. Two things
remain unconfirmed:

- that the session's image ships the same policy binary;
- the exact prompt text.

Both need the session transcript.

## Proposal

- Inside the safe roots, do not prompt: the session scratchpad,
  `/work/tmp`, and a project's `build/`, `.dart_tool/`, `.cache/` and
  `.claude/worktrees/`.
- Outside the workspace, keep the prompt.
- If the prompt is Claude Code's own, the lever is forge-shipped
  `permissions.allow` rules (or a PreToolUse hook that returns `allow`)
  scoped to those roots. That is a change to the forge's harness settings,
  so it needs the operator's approval.

## Closure

The operator rules on the proposal. If approved, a forge agent removes
`.dart_tool` and a worktree without a prompt, and `rm -rf ~/` still
prompts.
