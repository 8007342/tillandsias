# enhancement: a forge installs neither the pre-push local gate nor the pre-commit guards, so trunk protection is convention-only inside it

- **Date**: 2026-09-02
- **Classification**: enhancement (forge lane; trunk protection)
- **Status**: ready
- **Discovered by**: forge meta-orchestration cycle 2026-09-02T21:41Z (macuahuitl-tillandsias-forge), while verifying whether an order-966-7umc push actually took the plan-only lane
- **Related**: order 448 (this is what makes its guard inert in a forge), order 668-2xeh (the plan-only lane), order 964-fwvh

## Measured

```
$ ls ~/.cache/tillandsias/git-hooks/
post-commit  prepare-commit-msg
```

That directory is the value of `core.hooksPath`, set globally by
`images/default/lib-common.sh:375` so the forge's own agent-trailer and
expert-refresh hooks run. Setting it globally REDIRECTS EVERY REPO'S HOOKS away
from `.git/hooks`, and nothing in the forge launch runs
`scripts/install-hooks.sh`, so the two guards that matter are simply absent:

- **`pre-push`** — `scripts/hooks/pre-push-local-gate.sh`, which enforces the
  `./build.sh --check` stamp. Push CI no longer exists on any working branch
  (litmus:github-actions-budget), so this hook is the ONLY automated trunk
  protection. In a forge it does not exist.
- **`pre-commit`** — the OpenSpec trace/cheatsheet guards, including the
  order-448 commit-time cheatsheet re-sync landed today.

## Why this matters more than it looks

**Trunk protection in a forge is currently convention.** This cycle ran
`./build.sh --check` before every push and the trunk is fine — but it was fine
because the agent chose to, not because anything required it. An agent that
skips the gate gets no refusal, and `--no-verify` is not even needed. The
"pre-push refused" experience that other hosts rely on does not exist here.

**And order 448's guard is inert in exactly the environment that motivated it.**
The measured incident was *a forge* landing an authored cheatsheet without its
derived copy, three times. The fix is a pre-commit hook. A forge has no
pre-commit hook. So today's fix helps every host EXCEPT the class of host that
caused all three instances — which is worth saying plainly rather than letting
the packet read as closed.

## The subtlety worth recording

`scripts/install-hooks.sh` resolves its target with
`git rev-parse --git-path hooks`, which RESPECTS `core.hooksPath` — so running
it inside a forge would install into the forge's hooks dir correctly and
compose with the two hooks already there. The gap is not incompatibility; it is
that nothing invokes it.

## Reduction candidates

1. **Run `scripts/install-hooks.sh` in the forge lifecycle**, after the
   `core.hooksPath` block that creates the dir. Cheapest, and it makes the
   forge's guarantees match every other host's. Needs care that the installer's
   marker-based upgrade path composes with the two hooks lib-common writes
   directly rather than overwriting them.
2. **Have the launch REPORT hook state** in the startup context, one line, the
   way `experts:` and `inference_state=` are reported — so "this forge has no
   pre-push gate" is a stated fact rather than something an agent discovers by
   accident while checking something else. Even without (1), an agent that
   knows it has no gate knows to run it.
3. Decide whether a forge SHOULD carry the pre-push gate at all. There is a
   defensible position that an ephemeral forge is exactly where the gate
   matters most (its work is pushed and then the container dies), and a weaker
   one that a forge is a scratch environment. This issue assumes the former;
   the decision is the Tlatoāni's.

## Verifiable closure

A freshly launched forge reports its hook state in the startup context, and a
`git push` from that forge with a deliberately red tree is REFUSED by a
pre-push hook rather than succeeding — with a litmus arm that would fail if the
hooks directory carried only the two lifecycle hooks again.
