# Windows code-signing for the GitHub-release channel: SignPath Foundation decided, Azure Artifact Signing fallback, Store MSIX option

- classification: research
- filed: 2026-08-16 (windows/Yolanda, operator-attended session)
- status: decided — SignPath Foundation is the signing path (operator decision below)
- related packets: 722-w7a2 (windows-signing-identity-provisioned, reshaped by
  this decision), 776-it8u (repo-osi-license-decision), 776-t8hs
  (signpath-foundation-application), 776-g6r3
  (store-msix-free-signing-research)

## Operator decision (2026-08-16)

- who: The Tlatoāni (operator), attended session on windows/Yolanda
- what: **SignPath Foundation is the signing path for the GitHub-release
  channel.** Packet 722-w7a2 is reshaped, not closed: its deliverable changes
  from "an Azure Trusted Signing account" to the SignPath Foundation chain,
  with Azure **Artifact Signing** as the recorded fallback.
- prerequisite chain filed: 776-it8u (OSI license decision — operator-owned)
  → 776-t8hs (SignPath Foundation application). 776-g6r3 (Store MSIX channel)
  is research-recommended, **NOT yet operator-approved**.

## Load-bearing facts (preserve these — they shaped the decision)

- **SAC (Smart App Control) passes immediately** with ANY signature chaining
  to a Trusted Root: sign ALL PE files, use RSA not ECC, and timestamp the
  signature. No reputation wait for SAC.
- **SmartScreen reputation always accrues over weeks**, regardless of
  certificate type. There is no purchasable instant bypass anymore.
- **EV's instant SmartScreen bypass was removed in 2024**; Microsoft states
  the EV premium is no longer justified.
- **sigstore is not honored by Windows** — cosign-style keyless signatures do
  nothing for SmartScreen/SAC.

## Option 1 (DECIDED): SignPath Foundation — free OSS signing

- Cost: $0 for qualifying open-source projects.
- Requirements: an **OSI-approved license** (the repo currently has NO LICENSE
  file — hence 776-it8u), no proprietary components, no commercial
  dual-licensing (signpath.org/terms).
- Process: publish a code-signing policy page + attribution, apply, expect a
  **days-to-weeks lead time**, and **per-release manual approval** thereafter.
- The publisher name on signed binaries will read **"SignPath Foundation"**,
  not the project's own name — accepted by the operator.

## Option 2 (FALLBACK): Azure Artifact Signing

- Renamed from "Trusted Signing"; GA January 2026 (devclass 2026-01-14).
- Basic tier $9.99/month; a **paid Azure subscription is required**.
- **Individual (non-organization) validation is limited to US/CA residents.**
- Short-lived certificates, CI-friendly via federated OIDC — the original
  722-w7a2 design; retained as the recorded fallback if SignPath declines or
  stalls.

## Option 3 (research-recommended, NOT operator-approved): Microsoft Store MSIX

- **Microsoft re-signs MSIX packages submitted through the Store: $0**, and
  Store-delivered packages get **no SmartScreen/SAC warnings**.
- Both Partner Center registration fees are **waived** (individual developer
  fee waived 2025-09-10; company fee waived 2026-05-07, per Windows Dev Blog).
- The operator **already holds a Store listing**.
- Scope if approved (776-g6r3): MSIX-package the tray (`runFullTrust` +
  startup task), drive the Store submission API from CI.
- Complementary to, not a replacement for, the GitHub-release channel.

## Provenance

| Source | Date |
|---|---|
| learn.microsoft.com — code-signing-options | 2026-04-20 |
| learn.microsoft.com — smartscreen-reputation | 2026-05-04 |
| learn.microsoft.com — Artifact Signing quickstart | 2026-08-11 |
| learn.microsoft.com — Artifact Signing FAQ | 2026-08-14 |
| Windows Dev Blog (individual fee waiver) | 2025-09-10 |
| Windows Dev Blog (company fee waiver) | 2026-05-07 |
| signpath.org/terms | consulted 2026-08-16 |
| devclass (Trusted Signing → Artifact Signing GA) | 2026-01-14 |
| textslashplain (EV/SmartScreen analysis) | 2026-04-28 |
