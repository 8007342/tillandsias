# Brew harness strategy: keep brew, but only for officially-brew-documented tools; solve aarch64 Tier-2 reality

- Date: 2026-07-12
- Class: enhancement (promoted as plan/index.yaml order 317 `brew-aarch64-harness-strategy`; coordinator-renumbered from 316)
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

## Inventory (exit criterion 1 — recorded 2026-08-23, macOS host, order 317)

Measured by a two-agent pass: in-repo channel audit (file:line) + official-docs
provenance (URLs). Full agent evidence in the 317 progress event of this date.

### The headline

**No harness installs via brew, and none should.** The brew shim path
(`images/default/brew-shim-exec.sh` + `brew-tools-allowlist.txt`) carries zero
harness entries — it is strictly the order-294 general-dev-tool channel. Every
harness already uses its official channel with runtime arch detection, which is
the deliberate aarch64 strategy (`Containerfile.base:43-48`: build-time baking
froze the wrong arch on the macOS guest).

### Harness rows: official channels, brew-documented?, designated aarch64 channel

| Tool | Installed today (in-repo provenance) | Brew officially documented? | Designated aarch64-Linux channel |
|---|---|---|---|
| Claude Code | vendor curl `claude.ai/install.sh`, every launch, arch-detects (`lib-common.sh:2799,2828-2929`; left npm 2026-07-21, order 459) | YES — but as a **cask** (macOS-only): code.claude.com/docs/en/setup | vendor curl installer (npm `@anthropic-ai/claude-code` explicitly ships linux-arm64) |
| OpenCode | vendor curl `opencode.ai/install`, every launch (`lib-common.sh:2567-2617,2931-2978`) | YES — vendor's own tap, but Homebrew-on-Linux has no aarch64: opencode.ai/docs | vendor curl (pulls `opencode-linux-arm64[-musl].tar.gz`); npm equal alternative |
| Codex CLI | npm `@openai/codex@latest`, every launch (`lib-common.sh:2247-2278,2993-2996`) | YES — but as a **cask** (macOS-only): github.com/openai/codex | npm; standalone `chatgpt.com/codex/install.sh` names `codex-aarch64-unknown-linux-musl` |
| Gemini CLI | **not installed** — only a provider credential via Vault→opencode auth (`lib-common.sh:1833-1862`) | YES in vendor README (homebrew-core formula) — but Homebrew-on-Linux is x86_64-only | npm `@google/gemini-cli` (pure Node, arch-portable) — if ever added |
| Antigravity (agy) | vendor script `antigravity.google/cli/install.sh`, install-if-missing, 3 retries (`lib-common.sh:3005-3026`) | NO — official download page documents no brew channel | vendor script (download page offers ARM64 Linux builds, glibc ≥ 2.28) |
| openspec | npm `@fission-ai/openspec@latest`, every launch (`lib-common.sh:2247-2251,2988-2991`) | n/a (npm-only vendor docs) | npm |
| direnv (order-294 set) | brew shim, on-demand (`brew-tools-allowlist.txt:59`) | YES — direnv.net scopes it "macOS Homebrew" | distro package or official `direnv.linux-arm64` release binary; brew shim stays with the owned Tier-2 warning |
| gh, node/npm | Fedora microdnf, baked per-arch (`Containerfile.base:20-21`) | n/a | distro (already arch-correct) |

Vendor-docs caveat recorded: a formula existing in homebrew-core is not vendor
documentation; the Codex docs page renders install tabs client-side and was
cross-confirmed from the openai/codex README; community dnf/deb guides for
Antigravity are not official and were excluded.

### Per-arch policy status (scope items 2-3)

The shim now owns the Tier-2 statement in one line, printed on the aarch64
install path only (order 317; pinned by scripts/test-brew-shim-tier2-warning.sh,
8 checks incl. per-arch and per-path negative controls and a cmp-verified
mutant arm, wired into litmus:brew-ondemand-tools-shape). Constraint noted for
any official-channel-only tightening: the floating-@latest + last-good-rollback
machinery (orders 181/284) and the proxy egress allowlist entries per vendor
domain must survive any channel change.

### Remaining (exit criterion 2)

In-guest verification on a pristine aarch64 guest — every inventoried harness
installs via its designated channel with visible progress or one actionable
failure line, no silent 127s — belongs to a cycle that runs the macOS
local-build e2e; recorded as the packet's next_action.
