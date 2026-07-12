# Bug: fresh curl-install forge comes up with dead egress and ZERO harnesses (terminal fine, agents 127)

- Date: 2026-07-11 (operator repro, local; filed 2026-07-12T00:50Z)
- Class: bug (two packets: orders 298, 299)
- Reported by: The Tlatoāni ("I just did a curl install, and none of the
  harnesses launched, however the terminal launched")
- Release under test: v0.3.260711.8 (contains the order-289 fix a7dad73e)
- Related: order 289 (proxy teardown vs live terminal lane — residual
  explicitly asked for a follow-up with trace evidence if the repro
  recurred), order 181 (EVERY_LAUNCH harness installs), order 284
  (harness rollback), order 294 (brew shims), orders 129/130 (egress
  allowlist).

## Operator log (verbatim excerpts)

```
tillandsias: bootstrapping userspace Homebrew (4.5.8) for on-demand tools...
fatal: unable to access 'https://github.com/Homebrew/brew/': Could not resolve proxy: proxy
tillandsias: Homebrew bootstrap failed (network/proxy?).
forge@forge-tillandsias ~/s/tillandsias (linux-next)> opencode
fish: Unknown command: opencode
... (agy, claude, codex — all 127)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
curl: (5) Could not resolve proxy: proxy
```

The forge welcome banner rendered fully (services listed as present:
proxy, git-service, inference) — i.e. the lane LOOKS healthy while every
egress path is dead and no agent harness exists.

## Root-cause chain (as understood from the released code)

1. Inside the maintenance-terminal container, proxy env is baked
   (`https_proxy=http://proxy:…`) but the hostname `proxy` did not
   resolve → the `tillandsias-proxy` container was absent/unreachable at
   first launch. This is the order-289 failure signature RECURRING on a
   build that already contains the 289 predicate fix — either the
   proxy was never started on this launch path, or the (now
   unconditionally traced) teardown fired anyway. Order 289's residual
   says exactly this: capture the new trace line to identify the actor.
2. `entrypoint-terminal.sh` backgrounds `ensure_forge_harnesses`
   (order 181), which is deliberately fail-soft: "if npm is offline or
   the proxy is unreachable, the baked/cached version is used silently".
   On a PRISTINE curl-install there IS no baked/cached harness, so
   fail-soft degrades to fail-SILENT-with-nothing: opencode/claude/codex
   all exit 127 and nothing tells the operator why.
3. The brew on-demand shim (order 294) correctly fail-softed to its
   hint, but the hint (`brew install direnv`) is unactionable while
   egress is down — cosmetic, folded into order 299's loud-failure work.

## Also observed (minor, noted not packeted)

- The brew bootstrap ran TWICE back-to-back (the direnv shim fires per
  shell init); each attempt re-clones nothing but re-prints the failure.
  A negative-result backoff stamp would silence the repeat. Fold into
  order 299 or the order-294 follow-ups.

## Reduction

- Order 298 (bug): evidence-gathering + fix for proxy-absent-at-first-launch;
  terminal/lane egress must re-ensure the proxy on demand or the launcher
  must prove proxy liveness before handing the lane to the operator.
- Order 299 (enhancement): first-run harness bootstrap must fail LOUD when
  no harness binary exists after the install attempt (banner + terminal
  message naming the blocked egress), while staying silent for the
  update-only path.
