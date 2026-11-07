# Smoke e2e findings — Windows (yolanda) — release 56.11.1.1 — COLD clean-room — FAIL

## Run 2026-11-02T17:08Z→17:22Z — **FAIL** (tag v56.11.1.1, tray 05341632f)

The operator approved the cold run in this session ("I approve cold smoke tests").
Clean-room per SKILL §2 Windows: tray stopped, `wsl --terminate` + `--unregister
tillandsias`, runtime cache purged by name, and `vault-shamir-share-v1` +
`vault-root-token-v1` cleared from Credential Manager (`tillandsias-vm-uuid` kept).
The builder distro survived (03-builder-vhdx-after.txt). No agent turn.
Evidence: target/smoke-e2e/ on yolanda; tray.log 17:09–17:22Z.

| step | verdict | evidence |
|---|---|---|
| 1 pinned install | ok | install_exit=0; `tillandsias-tray 56.11.1.1 (05341632f)` |
| 2 clean-room reset | ok | 02-reset.txt reset_ok; both vault credentials verified absent |
| 3a cold provision | ok | provision_exit=0; `bringup: step=wsl-boot ms=67597`; fresh vhdx postdates marker |
| 3b status polled to Ready | FAIL | wire closed during `GetVaultHandover` at 17:11:15Z and the guest stopped; 60 s poll unreachable (WSA 10060) |
| 4 vault on a share-less store | ok | 17:14:36Z "WIPING … vault-data … initialised afresh" after the 1658-6ca6 90 s wait; Initialized true, Sealed false |
| 5 host collects the new share | FAIL | the running tray did not store it in 6+ minutes; one `--status-once` stored both at once |
| 6 GitHub sign-in reset | ok | 17:15:19Z `github sign-in state resolved from="unknown" to="signed-out"` |

### Work Packet: smoke-finding/windows-tray-never-collects-a-fresh-vault-handover

- owner_host: windows
- status: ready
- priority: p1
- discovered_by: `/smoke-curl-install-and-test-e2e` cold run, v56.11.1.1
- evidence: the vault initialized at 17:14:37Z ("handover artifacts written to tmpfs").
  The running tray (wire up at 17:13:13Z, "vm status push subscription established
  (polls suppressed, SC-07)") logged nothing more, and
  `cmdkey /list:vault-shamir-share-v1` read `* NONE *` until 17:20:45Z. A single
  `tillandsias-tray.exe --status-once --json` then stored both credentials.
  `deliver_credentials_and_check_handover` runs only from the request and
  monitor-poll paths (notify_icon.rs 1904/2181/3466, wsl_lifecycle.rs 2344).
  With polls suppressed by the push subscription, nothing calls it after a
  vault init that happens after connect.
- impact: until something triggers a request, the new unseal share lives only
  in guest tmpfs. A guest restart in that window leaves a store with no share,
  so the 1658-6ca6 path wipes it again and every credential stored in it is lost.
- exit_criteria: when the guest reports a vault init or handover-ready event
  after the wire is up, the running tray collects the handover without a poll
  or user action, and a test pins that it happens under push-subscription mode.

### Work Packet: smoke-finding/windows-provision-once-first-vault-init-is-discarded

- owner_host: windows
- status: ready
- priority: p2
- discovered_by: same run
- evidence: `--provision-once` exited at 17:11:00Z with the handshake at
  phase=Starting. The first boot initialized a vault at 17:11:11Z. The SKILL's
  `--status-once` poll reached the guest at 17:11:15Z, but the wire closed
  during GetVaultHandover ("[vsock] vault bootstrap after DeliverCredentials
  failed: … VM is draining/stopping (order 234 phase gate)"). The guest then
  stopped, so the poll never saw Ready. The next boot found that store without
  its share and wiped it after the 90 s wait. Every cold provision pays an
  extra init and 90 s, and the SKILL's 60 s status poll cannot pass.
- exit_criteria: on a cold host, `--provision-once` collects the first
  handover before it exits (or holds the guest until it does), and the SKILL
  §3 Windows status poll reaches Ready.
