# Autonomous Codex / OpenCode forge validation

- Order: 1684-wtnn
- Status: research and reproduction in progress; no live harness pass claimed.
- Operator approval: bounded live forge tests and API-credit use; preserve project-configured default model. Forge-only permission bypass. No substrate reset.
- Related work: 1553-7uge (OpenCode auth compatibility), 1634-sab8 (isolated auth fixture service port), 1667-jna9 (already claimed host-browser registration).

## Bootstrap receipt

- Intent: code_implementation; roles: primary integration/verification, Sol Codex research, Astra OpenCode/vault research, Terra live-test research.
- Host/platform: yoga, immutable Linux; repository MCP fallback: **unavailable**, no repository tools exposed to this session.
- Read: `methodology.yaml`, `methodology/bootstrap/router.yaml`, `methodology/spec-system.yaml`, `methodology/ci.yaml`, `methodology/litmus.yaml`, `methodology/distributed-work.yaml`, `methodology/multi-host-development.yaml` work-ref/plan-only protocol, `plan.yaml`, folded ledger via `tillandsias-plan query`, `plan/steps/README.md`, `skills/join-the-fleet/SKILL.md`, `skills/initialize-bare-metal-host/SKILL.md`.
- Initial governing specs: `codex-tray-launcher`, `forge-opencode-onboarding`; additional launch/auth spec spans will be verified before source edits.
- Scope: dedicated forge launch/config/auth behavior and regression evidence, no tray UX changes, no already-claimed host-browser changes, no SPIFFE/SPIRE implementation claim.
- Verification: reproduce existing launch failures with bounded closed-stdin sessions; test effective configuration plus an actual tool execution; verify auth in a second fresh forge without /connect; run targeted regressions and `./build.sh --check` before every push.
- Initial sibling heads: linux-next `2247d052e35873638ed9fed5d6f5584c4ce72421`; main `643de7a396320f9b2a5e29918eeccff51d513697`; osx-next `49731c152273395cf95fd9f63249844cac707a57`; windows-next `b38f7105262afdd2805e947e50d126ea58a4cbfa`.

## Initial environment evidence

- Clean borrowed branch `work/888-3d6x` left unchanged; switched to existing `linux-next` and pulled fast-forward from `1cbf9869e` to `2247d052e`.
- Installed launcher reports `Tillandsias v56.10.9.1`; current checkout launcher built successfully with `scripts/with-tillandsias-builder.sh cargo build -p tillandsias-headless --bin tillandsias` (debug artifact, no install/version bump).
- Host Vault/proxy were stopped; ensure-shaped `--ensure-enclave` succeeded without a reset. Current checkout binary also reports `ok:enclave-ensured:proxy=running`.
- `scripts/cycle-preflight.sh` rebuilt the initially stale plan instrument, refreshed experts, restarted three stopped auxiliary services, and reported `ok:cycle-preflight:rebuilt+expert-refreshed+services-down3:ok:dev-inference-ready:qwen2.5:0.5b:nomic-embed-text`.

## Next action

Collect version-qualified research, reproduce Codex and OpenCode launch/auth behavior, and record the minimal changes and honest live verdicts here. No successful autonomous launch is evidenced yet.
