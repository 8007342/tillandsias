# Brew harness strategy: keep brew, but only for officially-brew-documented tools; solve aarch64 Tier-2 reality

- Date: 2026-07-12
- Class: enhancement (promoted as plan/index.yaml order 316)
- Decision recorded: The Tlatoāni, 2026-07-12 attended smoke — "we need to
  revisit our brew support. It might still be the most compatible and
  reliable way for now to install the harnesses and the agents; let's keep
  it for those who provide brew installers in their official websites."
- Related: `brew-shim-attestation-requires-gh-token-2026-07-12.md` (P2,
  same surface), order 294 (brew shims), order 299 (loud first-run
  failures), `curl-install-first-launch-no-harnesses-2026-07-11.md`.

## Observed (macOS guest = Linux aarch64, live)

Homebrew on Linux/arm64 is Tier 2: "Your CPU architecture (arm64) is not
supported. We only support x86_64… You will be unable to use binary
packages (bottles)." In practice it then downloaded bottle manifests and
blobs anyway and died on attestation — but even with attestation fixed,
arm64 Linux gets NO first-class bottles: installs degrade to source
builds (slow, toolchain-heavy) or Tier-2 bottles with no support. Every
macOS-hosted guest is aarch64, so the current shim strategy is at its
weakest exactly on the platform we validated today.

## Scope (per the decision)

1. Inventory the harness/agent set (opencode, claude, codex, agy, support
   tools like direnv): which document brew as an OFFICIAL install channel
   on their websites? Brew stays for exactly that set — for the rest, use
   their official installer (npm, curl script, release binary) instead of
   forcing brew.
2. Per-arch policy in the shims: x86_64 Linux may use bottles; aarch64
   Linux must either accept source builds explicitly (with the loud
   "this will take a while" heartbeat, cf. order 299) or prefer the
   tool's non-brew official channel.
3. Silence/own the Tier-2 warning in the shim wrapper (state the policy
   in one line instead of Homebrew's "do not report issues" wall).
4. Depends on / folds in the attestation token fix
   (`brew-shim-attestation-requires-gh-token-2026-07-12.md`).

## Verifiable closure

On a pristine aarch64 guest: every harness in the inventory installs via
its designated channel with visible progress, or fails with one
actionable line; no silent 127s (litmus-extendable via the harness
rollback / name-filter shape tests).
