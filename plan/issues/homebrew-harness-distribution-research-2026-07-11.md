# Research: Homebrew as a harness/tool distribution channel (operator-requested)

- Date: 2026-07-11
- Class: research
- Requested by: The Tlatoāni ("our curl installers are crapping all over the
  place... investigate who's behind brew, are there signed packages, can we
  move harness installs to brew + wire on-demand brew tool install")
- Related: order 284 (opencode-ai@latest breakage), order 181 (EVERY_LAUNCH
  npm installs), orders 129/130 (egress allowlist), antigravity pipe-to-shell
  installer note in Containerfile.base

## Who is behind Homebrew

- Community open-source project (BSD-2-Clause), led by an elected Project
  Leadership Committee (Mike McQuaid has been the long-time project leader).
- Fiscally hosted by the **Software Freedom Conservancy** (US 501(c)(3),
  est. 2006, hosts Git, Inkscape, etc.) — SFC holds Homebrew's funds and
  provides legal/administrative infrastructure; funding is donations
  (Patreon + one-off via SFC), plus GitHub-sponsored CI.
- All formula/cask definitions are public PRs on GitHub
  (Homebrew/homebrew-core, Homebrew/homebrew-cask) with maintainer review.

## Are packages signed?

Three very different supply-chain tiers — this is the crux:

1. **homebrew-core FORMULAE (bottles)**: since 2024, every bottle built by
   Homebrew CI carries a **Sigstore/in-toto build-provenance attestation**
   (SLSA Build L2): cryptographically binds the binary to the exact
   GitHub Actions workflow, commit, and run that built it (work funded via
   OpenSSF/Trail of Bits). Client-side verification via
   `HOMEBREW_VERIFY_ATTESTATIONS=1` (uses `gh attestation verify`).
   THIS is the strong tier. Bottles exist for x86_64 + arm64 **Linux**.
2. **CASKS**: macOS-ONLY. A cask is a scripted download of the VENDOR's own
   binary from the vendor's URL, pinned by sha256 in the cask definition.
   No Homebrew build, no attestation — trust = vendor + a checksum pin.
3. **Third-party TAPS** (e.g. `sst/tap`): arbitrary repos, no Homebrew
   review at all — the "strange places" the operator noticed. Avoid.

## Harness availability (checked 2026-07-11)

| Harness | Brew artifact | Tier | Linux? |
|---|---|---|---|
| opencode | `opencode` in homebrew-core | formula w/ Sigstore-attested bottles (upstream opencode.ai, MIT) | YES (x86_64+arm64 bottles) |
| codex | `codex` **cask** (migrated off the old formula) | vendor binary + sha pin | NO (cask = macOS only) |
| antigravity | `antigravity-cli` **cask** | vendor binary + sha pin | NO |
| claude-code | npm only (Anthropic ships npm; no core formula found) | — | n/a |

## Implications for the forge (Fedora containers)

- Homebrew-on-Linux works fully in userspace (`/home/linuxbrew/.linuxbrew`,
  no root) — compatible with our rootless containers, BUT:
  - `install.sh` is itself a curl|bash (policy conflict with our
    package-source rule) — mitigate by pinning a Homebrew release tarball
    (checked-out git tag) instead of HEAD install.sh.
  - Casks don't exist on Linux, so brew CANNOT be the Linux channel for
    codex/antigravity today; npm remains their only sane in-forge channel.
  - opencode IS a clean win candidate: core formula, Linux bottles,
    Sigstore attestation, and it decouples us from npm postinstall
    breakage (order 284 class).
- Brew traffic targets: github.com + ghcr.io (bottles) + formulae.brew.sh
  (API). ghcr.io/formulae.brew.sh need proxy-allowlist entries
  (order 129/130 work) before any in-forge brew is possible.
- Operator repro 2026-07-11: brew install from the maintenance terminal
  failed `curl: (5) Could not resolve proxy: proxy` — separate infra bug
  (shared proxy container torn down while a terminal lane still runs;
  filed as its own packet), NOT a brew problem.

## Recommendation (for Tlatoāni decision)

1. Slice 1 (cheap, high value): move the **opencode** harness install to a
   pinned-release Homebrew-on-Linux with `HOMEBREW_VERIFY_ATTESTATIONS=1`,
   keeping npm as fallback; gate behind the migration ladder
   (flag→soak→default) per methodology.
2. Slice 2: general **on-demand brew tool service** for forge agents
   ("install brew tools as needed"): a guarded `ensure_brew_tool <formula>`
   helper (allowlist of formulae, attestation verification on, proxy-aware)
   instead of ad-hoc curl installers.
3. Keep codex/claude/antigravity on npm on Linux (casks are macOS-only);
   revisit if upstreams publish core formulae. On the macOS guest, casks
   could replace the curl installers if we accept vendor-binary trust.
4. Prerequisite either way: egress allowlist entries for ghcr.io +
   formulae.brew.sh (fold into order 129/130).
