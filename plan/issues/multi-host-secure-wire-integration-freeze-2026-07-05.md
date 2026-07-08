# Coordination: freeze sibling drift and integrate secure-wire + embedded-guest branches — 2026-07-05

- class: coordination+integration
- owner: any coordinator, with macOS and Windows evidence from their hosts
- status: ready
- order: 191
- trace: methodology/multi-host-development.yaml, methodology/convergence.yaml,
  plan/issues/secure-channel-maturity-ladder-2026-07-04.md,
  plan/issues/embedded-guest-binary-linux-build-2026-07-05.md

## Finding

`origin/osx-next` is 12 commits ahead of `origin/linux-next` and
`origin/windows-next` is 6 commits ahead. Both exceed the distributed-work drift
threshold Dmax=5 while the active product path spans all three branches:

- secure host<->guest control wire behind `TILLANDSIAS_SECURE_CONTROL_WIRE`;
- embedded source-matching Linux guest binary selection and injection;
- Fedora 44 VM initialization and Podman control-plane bring-up;
- top-host terminal launch of forge harnesses in the deepest forge container.

New platform feature work should pause until each sibling branch first merges
`origin/linux-next` and records either smoke evidence or exact conflicts.

## Non-negotiables

- Cross-branch integration is merge-only. Do not cherry-pick or rebase published
  `osx-next` / `windows-next` commits into `linux-next`.
- Shared `plan/`, `methodology/`, `openspec/`, and cheatsheet edits land directly
  on `linux-next`.
- macOS tray / VZ implementation code remains on `osx-next`; Windows tray / WSL
  implementation code remains on `windows-next` until the integration merge.
- No host credential/config material may enter a forge container while validating
  the top-host terminal launch path.

## Required evidence

macOS:
- merge `origin/linux-next` into `osx-next`;
- rebuild the tray with current embedded Linux guest assets;
- boot a cold Fedora 44 VZ guest;
- prove flag OFF still runs the plaintext path;
- prove flag ON reaches GitHub login, remote-project listing, and forge launch
  over the secure host<->guest wire, or file the exact failing boundary.

Windows:
- merge `origin/linux-next` into `windows-next`;
- preserve the hvsocket secure-wrapper and embedded-binary work already on the
  sibling branch;
- run WSL2 flag-OFF and flag-ON smoke evidence, or file the exact failing boundary.

Linux/coordinator:
- do not integrate sibling code from a dirty worktree;
- merge sibling branches in a clean worktree and run the focused verification gate;
- if conflicts hit shared ledgers, keep `linux-next` as the authoritative
  coordination source and preserve sibling notes as semantic upserts.

## Exit criteria

- Branch drift is back under Dmax or has a named conflict packet.
- M1 secure-channel evidence is recorded per platform, or the missing hop is
  explicitly assigned.
- Embedded guest binary work is aligned around order 190 as the Linux artifact
  contract consumed by macOS and Windows.

## Windows run result 2026-07-06T06:05Z — evidence slice COMPLETE

Agent `windows-bullo-fable5-20260706T0535Z` on `windows-next`:

- **Merge**: `origin/linux-next` (c50bdf3a) merged into `windows-next` as
  0794510a and pushed. The hvsocket secure-wrapper
  (`open_and_wrap_hvsocket_stream`, gated by `TILLANDSIAS_SECURE_CONTROL_WIRE`)
  and embedded-binary injection path in `wsl_lifecycle.rs` survived the merge;
  `cargo check --locked` and the 48 tray unit tests are green on the merged tree.
- **Flag OFF (plaintext no-regression)**: `e2e_hvsocket_handshake` negotiated
  `wire_version=2` and `e2e_vm_status_over_hvsocket` round-tripped
  `VmStatusReply { phase: Ready, podman_ready: true }` — verified against BOTH
  the previously deployed guest (v0.3.260704.2) and the rebuilt v0.3.260705.6
  guest with the flag off.
- **Flag ON (secure handshake)**: guest headless rebuilt in-VM from the merged
  windows-next tree (version-matched v0.3.260705.6, dev PSK seed both sides),
  run with `TILLANDSIAS_SECURE_CONTROL_WIRE=on`; the new ignored probe
  `e2e_secure_vm_status_over_hvsocket` (commit 8644b8ea) completed the Noise
  NNpsk0 handshake and a Hello/HelloAck + VmStatusRequest round-trip over the
  encrypted stream: `VmStatusReply { phase: Ready, podman_ready: true }`.
- **Failure-closed**: with the guest gate ON, a plaintext client's Hello is
  dropped (`early eof`) — no downgrade path.
- Guest was reverted to flag-OFF default after the smoke so the installed tray
  keeps working until the order-145 atomic cutover.

Method note: the version-matched guest was produced with the in-VM offline build
loop (host `cargo fetch` + registry cache copied into the distro) because the
VM's egress proxy could not be started manually after a VM reboot (its
`/tmp/tillandsias-ca` bind source is tmpfs and was wiped) — filed as a finding.

## macOS run result 2026-07-05T18:53Z

MacOS meta-orchestration did not merge or implement because the local `osx-next`
worktree has uncommitted tracked and untracked implementation/package changes.
This is a local macOS blocker, not a Linux blocker. Linux should continue with
order 190 while macOS checkpoints/cleans WIP before attempting the merge.

## macOS merge result 2026-07-05T22:25Z

- `origin/linux-next` merged into `osx-next` (34 commit catch-up, no feature loss)
- 3 conflicts resolved (vsock_server.rs, 2 plan files — linux-next authoritative)
- `cargo fmt --all --check`, `cargo check -p tillandsias-macos-tray`, all 53+12 tests green
- Pushed to `origin/osx-next` at `39e9df27`
- Branch drift from linux-next resolved. Order 193 (macos-vz-home-src-mount) unblocked.

## macOS evidence slice 2026-07-08T22:10Z — merge + build + test complete

Agent `opencode-big-pickle-20260708T2210Z` on `osx-next`:

- **Merge**: `origin/linux-next` (baf52d88) merged into `osx-next` (9308cf5c). One conflict in `plan/loop_status.md` — resolved keeping both sides' cycle entries.
- **Verification**: `cargo test` results on the merged tree:
  - `tillandsias-macos-tray`: 58 passed, 1 ignored (e2e VM entitlement), 0 failed
  - `tillandsias-vm-layer`: 50 passed, 1 ignored (live network), 0 failed
  - `tillandsias-secure-channel`: 12 passed, 0 failed
  - `tillandsias-control-wire`: 37 passed, 0 failed
- **`./build.sh --check`**: formatting check, type-check, and strict clippy all PASS
- **macOS tray binary build**: `cargo build -p tillandsias-macos-tray` PASS
- **Secure-wire code intact**: `GuestTransport` facade (`transport_macos.rs`), `EncryptedStream` primitive (`secure_channel`), secure-or-plain opener (`action_host.rs`, `diagnose.rs`) all confirmed present and compiling. `TILLANDSIAS_SECURE_CONTROL_WIRE` gate (default OFF) present on all macOS call sites.
- **VM provisioning improvements**: applied two stashed fixes — network wait loop before dnf install in VZ cloud-init (`vz.rs`), `HOME=/root` in fetch-headless/headless systemd units (`vz.rs`), and `TILLANDSIAS_HOST_KIND` + hostname-based VM detection (`vault_bootstrap.rs`).
- **Remaining for full live VM evidence**: `scripts/e2e-preflight.sh eligibility` → `skip:no-podman-user-session` (no functional Podman machine on this dev host — `krunkit` not installed, see `plan/issues/macos-embedded-guest-runtime-smoke-2026-07-05.md`). Flag-OFF/flag-ON live VM smoke requires a macOS host with working Podman machine + VZ entitlement to boot a Fedora 44 guest and prove the encrypted control wire end-to-end.
