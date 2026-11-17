# Smoke e2e findings: v56.11.7.1, 2026-11-07, linux, yoga

- run_start: 2026-11-07T21:40:14Z
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-<ts>/)
- forge_lane_outcome: agent dead on its first model request (EPROTO TLS handshake), lane exit 1 after 168 s; no SMOKE-AGENT-OK token, no tool call, so no credential-guard line either. NOT a completed cycle and NOT a guard stop.
- signature_verification: cosign:could-not-run:cosign-absent

**Verdict: FAIL at the forge agent turn (signatures unverified: cosign absent).** Install, clean-room reset and init PASS; the enclave comes up; the agent cannot reach its model.

Channel: stable-promotion candidate, pinned `SMOKE_BASE=https://github.com/8007342/tillandsias/releases/download/v56.11.7.1` (`/releases/latest` still resolves to v56.10.20.1). Requested by macuahuitl; destructive reset approved by the operator 2026-11-07. Sibling heads at start: main 8351a0f3f, linux-next d7959afd3, windows-next b38f71052, osx-next 49731c152.

## Steps

| step | result | evidence |
|---|---|---|
| §1 curl-install | PASS, install_exit=0; `tillandsias --version` = `Tillandsias v56.11.7.1` at ~/.local/bin/tillandsias | 01-install-exit.txt, 01-version.txt |
| §1s signature | could-not-run: cosign absent on yoga | 01s-cosign.txt |
| §2 reset | PASS, reset_exit=0, clear_exit=0 (`ok:clear-vault-credentials`, vault-data removed via podman unshare); store empty; probe `credential-cold` | 02-*.txt, 02-credential-post.md |
| §3 init | PASS, init_exit=0, **504 s**; no panics, `Error:` lines, Vault auth failures or short-name prompts; 33 localhost image tags | 03-init-exit.txt, 03-init-errors.txt (empty), 03-images.txt |
| §3b shutdown | PASS for Tillandsias: tillandsias-vault exit 0 in 1 s (grace 10). The flagged `ollama` row is the operator's own quadlet (`ollama-vulkan.service`, restarting after the reset), not a Tillandsias container; this run's loop did not filter by name | 3b-shutdown.txt |
| §4 forge lane | **FAIL**: opencode_exit=1, 168 s, `Error: EPROTO: The TLS handshake failed. Does the server speak TLS on this port?` (04-opencode.log:37) right after `> build · big-pickle`; forge printed `push: no-credential` as expected on a cold host | 04-opencode.log, 04-tokens.txt (empty) |
| §4b egress | PASS: proxy alive alongside the lane | 04b-verdict.txt |
| §4c health | PASS: router, proxy (healthy), vault (healthy, `"sealed":false`) up; lane-scoped containers gone by design | 05-health.log |

Init noise, not findings (build chatter seen on every run): `Failed to connect to audit log` from the image builds, `skipped OpenPGP checks`, `Failed to preset unit systemd-tmpfiles-clear.service`, the IPv6 check injecting `--ipv4-only`.

## Findings

### Work Packet: 2027-e2cf

Filed as ledger row `2027-e2cf` (plan/index.d/20261107t220000z-2027-e2cf-cold-lane-agent-eproto-yoga.yaml), promoting the markdown-only packet `1941-tlsh` (plan/issues/cold-lane-agent-tls-eproto-hop-2026-11-01-yoga.md) so the selector sees it. New on this run: the failure hit the FIRST model request of a one-turn lane, not mid-session. Running count of cold Linux lanes: 5 failures in 6 runs, 2026-10-31 to 2026-11-07.

No other distinct issue was observed.

## Ledger claims (README row v56.11.7.1)

- EXERCISED: the Linux assets install and report the tag; clean-room init on the release; vault bootstrap and unseal from a cold keychain; mirror seed; forge start and branch resolution (`Seed branch: 'linux-next'`); proxy survival (order 298).
- NOT APPLICABLE: macOS and Windows assets; the Codex stale-credential offer (#985, no Codex lane here); studio audio input and jobs (#983, #967: no studio run in this smoke).
- NOT CHECKED: forge memory protection (#965, #966) beyond the launch's MemoryLow notice; checkout room warnings (#969); stale-lane reporting (#971); relay terminal login (#976); uv Python dir (#984); the src_mb branch fix (#982); the #961 regression fix (#980). The agent never ran a tool, so nothing inside the forge was exercised.
