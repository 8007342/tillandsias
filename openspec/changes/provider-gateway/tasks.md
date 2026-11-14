## 1. Spikes (order 2081; no code ships beyond a throwaway probe)

- [ ] 1.1 Claude: subscription mode through a forwarding gateway; record yes/no, the CLI version, the env/config, and the failure
- [ ] 1.2 Codex: same
- [ ] 1.3 Copilot: same
- [ ] 1.4 OpenCode: same

## 2. Gateway core (built by the first provider's build packet)

- [ ] 2.1 Write the failing test first: a forge-network request carrying a placeholder reaches a mock upstream with the real token
- [ ] 2.2 Listen-only-on-forge-network test; a loopback or 0.0.0.0 configuration is refused
- [ ] 2.3 In-memory TTL cache and serialized refresh with Vault write-back
- [ ] 2.4 Log-content test: no header or body bytes appear in the log
- [ ] 2.5 README.md (one page, how it works) and THREAT-MODEL.md beside the source

## 3. Per-provider upstreams (one build packet each, gated on the spike's yes)

- [ ] 3.1 Claude
- [ ] 3.2 Codex
- [ ] 3.3 Copilot
- [ ] 3.4 OpenCode

## 4. Cleanup (one per provider, after 2080-7euu and that provider's build)

- [ ] 4.1 Claude: the forge no longer receives the sign-in file, only the placeholder and base URL
- [ ] 4.2 Codex: same
- [ ] 4.3 Copilot: same
- [ ] 4.4 OpenCode: same
