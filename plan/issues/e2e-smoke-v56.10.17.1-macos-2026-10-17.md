# v56.10.17.1 e2e smoke — macos PASS (2026-10-17, macbookair)

**PASS** v56.10.17.1 on macOS. Reported by the macbookair-macos session to the coordinator on 2026-10-17 and recorded here verbatim in substance.

| Arm | Result |
|---|---|
| `install-macos.sh --channel unstable` | PASS: rc 0, sha256 ok; the installed app reports 56.10.17.1 (bf21de967) |
| SOFT reset on install | PASS: "derived state cleared (SOFT) — store and sign-ins kept" |
| Tray reaches Ready | PASS: phase=Ready at 20:31:12Z, 50 s after the old tray stopped |
| GitHub sign-in survives | PASS: `--list-cloud-projects` lists the operator's repos with the tray quit |
| Forge lane | PASS: `--opencode ~/src/tillandsias` built its images, booted, ran opencode, and the guest powered off cleanly (exit 0) |
| Cloudflare MCP tools advertised | PASS: scope_probe and workers_scripts_list return the named refusal `refused:cloudflare-mcp:not-signed-in` |

Not covered: the live Cloudflare tool check (1772), because this Mac has no Cloudflare sign-in stored. The installer stopped the running tray, ending an open Codex session.
