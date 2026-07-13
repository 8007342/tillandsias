# Bug: brew shim attestation verification requires a GitHub API token a pristine guest can never have

- Date: 2026-07-12
- Class: bug (P2, first-run tooling; egress was HEALTHY — distinct from
  `curl-install-first-launch-no-harnesses-2026-07-11.md`)
- discovered_by: operator attended m8 smoke (macOS arm64 guest = aarch64
  Linux VM, osx-next `374cb0b8`, pristine substrate)
- Related: order 294 (brew on-demand shims), order 299 (loud first-run
  failures), orders 129/130 (egress allowlist — NOT the cause here).

## Evidence (maintenance-lane screen capture, verbatim)

```
==> Downloading https://ghcr.io/v2/homebrew/core/ncurses/blobs/sha256:02abc7eacf
######################################################################### 100.0%
==> Verifying attestation for ncurses
Error: The bottle for ncurses could not be verified.
This typically indicates a missing GitHub API token, which you
can resolve either by setting `HOMEBREW_GITHUB_API_TOKEN` or
by running:
  gh auth login
tillandsias: brew install direnv failed (attestation verification is REQUIRED and may be the cause  that is by design).
tillandsias: 'direnv' is not installed.
Install it in userspace with: brew install direnv
```

Proxy/egress was fully alive: manifests and blobs downloaded from ghcr.io at
100%. The failure is purely that Homebrew attestation verification (which the
shim enforces "by design") needs an authenticated GitHub API call, and a
fresh guest has no `HOMEBREW_GITHUB_API_TOKEN` and no ambient gh auth at shim
time. Deterministic dead-on-arrival for every brew shim install on a pristine
substrate — the shim's own retry hint (`brew install direnv`) reproduces the
same failure.

## Also observed (fold into the same packet)

1. Homebrew prints the Linux-arm64 Tier-2 warning ("unable to use binary
   packages (bottles)") yet proceeds to download bottles anyway — noisy and
   confusing in the lane banner, worth suppressing or acknowledging in the
   shim wrapper.
2. Shim failure message is garbled: "…may be the cause  that is by design"
   (double space, missing punctuation/words). Tiny, fix alongside.

## Fix directions to evaluate (implementer's choice)

- Wire the Vault-stored GitHub token (present after `--github-login`) into
  the shim env as `HOMEBREW_GITHUB_API_TOKEN` at lane start; or
- fail-fast BEFORE downloading (probe token presence, print one actionable
  line: "brew attestation needs GitHub auth — run gh auth login first"); or
- decide attestation-off-with-checksum-pin is acceptable for the dev forge
  and document that decision in the spec (requires The Tlatoāni's call —
  security posture change, do not self-decide).

## Repro

Pristine substrate → maintenance lane → wait for banner → observe direnv
shim failure; or run `brew install direnv` at the forge prompt.
