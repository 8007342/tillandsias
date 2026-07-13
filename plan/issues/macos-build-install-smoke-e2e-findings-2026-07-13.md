# macOS local-build e2e + BigPickle in-forge meta-orchestration + resource-monitoring findings — 2026-07-13

- host: macOS arm64 (Tlatoanis-MacBook-Air, 10-core M-series, 16 GiB RAM), branch `osx-next`
- commit tested: `66d8b134` (osx-next fast-forwarded to linux-next head pre-build)
- installed version: `tillandsias-tray 0.1.0 (git 66d8b134)`, VERSION `0.3.260713.1`
- discovered_by: /build-install-and-smoke-test-e2e (macos) + operator-directed monitoring pass
- evidence: `target/build-install-smoke-e2e/20260713T224400Z/` (local host; key excerpts inlined — target/ is not committed)
- agent: macos-Tlatoanis-MacBook-Air-fable5-20260713T2243Z
- operator directive: drain macOS work, run full e2e with the goal "BigPickle
  successfully performs a /meta-orchestration cycle inside the forge", monitor
  host/guest resources and hot paths (ramdisk question), examine proxy/cache/
  router/git-mirror monitoring — metrics via idiomatic layers only, no
  VM-boundary hacks.

## Gate results

| Gate | Result |
|---|---|
| 1 build + codesign + install + freshness (embedded SHA == HEAD `66d8b134`) | PASS |
| 2 destroy substrate (5.5G VM dir + cache removed, verified absent) | PASS |
| 3 cold provision (528 MB rootfs download → convert → resize → `{"status":"provisioned"}`, exit 0; 250 GiB sparse disk) | PASS |
| 3b `--diagnose --json` post-provision | PASS (exit 0, `provisioned: true`) |
| 4a forge lane, attempt 1 (host path) | FAIL — "Project not found" (order 326 filed) |
| 4b forge lane, attempt 2 (guest path, cold images) | FAIL — 300s idle timeout killed VM mid-forge-base build (P1, order 327 filed) |
| 4c `--exec-guest … --init` pre-build (workaround, streamed) | images: ALL 10 built+tagged PASS; vault bring-up FAIL by design ("no root token delivered from host" — order 114 flow needs the tray) |
| 4d forge lane, attempt 3 (warm images) | **BigPickle ran a full /meta-orchestration cycle to a contract-clean exit 0** — cycle verdict BLOCKED `missing:no-credential-channel` (pre-existing filed blocker; evidence appended there) |
| ext parity: InteractiveStream attach cell | PASS live → order 257 CLOSED (matrix macOS column complete) |

## Was the goal met?

Partially — the infrastructure goal yes, the payload goal no:

- **PASS**: VM cold path, control wire, forge materialization, PTY attach,
  TUI in-band, opencode launch, prompt injection, full skill execution with
  correct mode detection/host classification (`forge`), credential guard
  execution, blocker re-derivation matching the filed blocker, disciplined
  exit, exit-code propagation to the host. BigPickle *performed* a
  meta-orchestration cycle inside the forge on macOS, end to end.
- **BLOCKED**: the cycle could do no committable work. Two stacked causes,
  both now evidence-annotated on `forge-credential-channel-missing-2026-07-12.md`:
  (1) shared-checkout `origin` is public GitHub — the entrypoint's mirror
  banner is aspirational on macOS (order 320 fix path); (2) cold substrate
  has no vault credential at all until a GitHub login runs (order 114
  design; orders 303/304). Unattended cold-substrate forge pushes are
  structurally impossible until those land.

## NEW FINDINGS (all filed as packets this cycle)

1. **Order 326** — `--opencode` passes host paths verbatim to the guest;
   "Project not found" after a ~60s boot. Translate `~/src/<n>` →
   `/home/forge/src/<n>`, fail fast pre-boot otherwise.
2. **Order 327 (P1)** — first-use `--opencode` structurally dead: silent
   forge-base build > 300s trips `IDLE_TIMEOUT_SECS` and `vz.stop()` kills
   the build mid-flight (3 duplicated constants, vsock_exec.rs). Workaround
   validated: `--exec-guest … --init` streams podman build output (proving
   the fix is output routing / wire heartbeat, not a bigger timeout).
3. **Order 328 (P1)** — BigPickle's blocked cycle ran
   `git checkout -- plan/index.yaml && git clean -fd plan/issues/` on the
   virtiofs-SHARED checkout, targeting sibling uncommitted work; survived
   only because e84ba192 was pushed minutes earlier. Exit-contract
   cleanliness must scope to cycle-created artifacts; macOS forge lane
   should get a forge-owned worktree (order 321 adjacency).
4. **Orders 323-325** (operator-directed monitoring architecture):
   guest/container metrics over the control wire; hot-path ramdisk
   placement decided with data; git-mirror observability + off-the-shelf
   mirror evaluation (declared order-315 audit input).

## Resource-monitoring results (host side, 15s sampler, 82 ticks)

- **Attribution**: VM resources land on Apple's
  `com.apple.Virtualization.VirtualMachine` XPC helper, NOT the tray
  process (tray: 14 MB RSS, ~0% CPU as pure driver). Any future host-side
  tray metrics must sample the XPC process.
- **CPU**: guest pinned at ~200% (of 400% = 4 vCPUs, vz.rs cap) through
  image builds, peak 264.9%, average 118.5% over the cycle. Host load never
  exceeded ~3.7 on 10 cores — **the guest vCPU cap, not the host, is the
  build-phase bottleneck**. dnf download phases dropped to 21-34% CPU
  (network-bound). Corroborates (did not isolate) the known TUI spinner
  burn finding during provider waits.
- **Memory**: XPC RSS = full 4 GiB guest allocation; host mem free 63-69%
  throughout, swap 0.00M the whole run. Comfortable at 16 GiB host — but
  the 4 GiB guest is the budget every tmpfs/ramdisk proposal spends
  (order 324's constraint).
- **Disk**: VM dir grew 0 → 12.0 GiB across provision + image builds
  (~800 MB/15s during pull phases); host has 785 GiB free — no host disk
  pressure. Per-path attribution inside the guest is impossible from the
  host — that is order 323's job.
- **Ramdisk reality check** (operator's stated intent vs shipping code):
  the forge checkout on macOS is **virtiofs to host SSD, not ramdisk**
  (vz.rs:479-491); Linux forges get per-launch tmpfs clones; the pull-cache
  "tmpfs-overlay lane" is a userspace disk LRU whose real-tmpfs upgrade was
  explicitly deferred pending profiling that has never existed
  (lib-common.sh:1539-1560). Orders 323/324 make the decision measurable.

## Litmus recurrences (known classes, not refiled)

Instant pre-build suite on this host: 127/131 after syncing the two
order-315 cheatsheets into the tracked image mirror (that sync IS part of
this cycle's commit). Remaining 4 failures are pre-existing non-macOS-gated
checks: `guest-binary-embed-integrity` (expects an x86_64 staged binary on
an aarch64-guest host), `git-delta-wait-shape` step 8, `forge-liveness-
probe-shape` step 9 (ISO-8601 via BSD date), `smoke-lock-fd-isolation-
shape` step 2 (flock fd semantics, already filed linux-specific in
windows-litmus-strict-exit-fallout-2026-07-11.md). Same class as
headless-integration-tests-not-macos-gated-2026-07-10.md / order 285's
podman gate — host-gating for shape litmuses remains open there.

## Dedupe notes

- OpenSpec init warning in forge: already filed
  (optimization/forge-openspec-init-fails-warning-2026-07-12.md) — observed
  again, no refile.
- Vault "no root token delivered from host" via exec-guest --init: designed
  behavior (order 114), recorded as evidence on the credential blocker, not
  a new packet.
