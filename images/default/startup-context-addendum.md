<!--
  Checkout-sourced startup-context addendum (order 743-y5wh).

  inject_startup_context() appends this file VERBATIM to
  .forge-startup-context.md at launch, reading it from the MOUNTED CHECKOUT
  rather than from the image. Everything in the generator's own heredoc is baked
  at image-build time and reaches running forges only after a rebuild; anything
  written HERE is live on the next launch.

  So: put fail-loud guidance here, not in the heredoc. Descriptive live state
  (inference readiness, expert skew, accelerator envelope) belongs in the
  generator, which can compute it. Rules an agent must not miss belong here,
  where they cannot be stale.

  Keep it short. This is appended to a file every in-forge agent reads first,
  and a long addendum is one nobody finishes.
-->

## Before you exit: a finding you did not PUSH is a finding you destroyed

This workspace is a `git clone` into the container. When the forge tears down it
goes with it, and nothing warns you.

Writing a fragment to `plan/index.d/` and validating it with `tillandsias-plan
check` proves it is WELL-FORMED. It does not prove it SURVIVES. Those are
different claims, and only the second one matters to the host that launched you.

On 2026-08-15 a review agent here found four real defects, minted three order
tokens, wrote three valid fragments, confirmed the ledger accepted them (857
packets), and exited. Every fragment was destroyed. They reached the ledger only
because a human happened to be reading this container's stdout and re-filed them
by hand. Unattended — the normal case for `./repeat --agent opencode` and every
litmus-launched forge cycle — all four findings would have been lost while the
launcher returned zero (order 741-3y48).

**Commit and push every finding before you exit.** Git push routes through the
enclave mirror and needs no configuration. Then prove it:

```bash
scripts/check-forge-findings-persisted.sh
```

`ok:no-findings` (you filed nothing, or everything is on the remote) ·
`ok:findings-persisted` (with `--since <ref>`) · `unpersisted:<why>` means work
already done is about to be thrown away.

It is a GATE, not advice. A non-zero exit is unrecoverable once this container
stops. It covers the whole `plan/` tree and catches what `git status` cannot: a
COMMITTED fragment that was never pushed looks exactly like a pushed one. A cycle
that legitimately files nothing prints `ok:no-findings` and is silent, so a clean
run stays quiet.

If you genuinely cannot push, say so loudly in your final output and reproduce
each finding there in full so the launching host can re-file it. Do not exit
quietly.
