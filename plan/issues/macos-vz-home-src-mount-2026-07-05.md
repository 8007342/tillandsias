# macOS P0: VZ must mount host ~/src at /home/forge/src — 2026-07-05

- class: bugfix (macOS VM provisioning)
- owner: macos
- status: blocked
- order: 193
- trace: plan/issues/embedded-guest-binary-linux-build-2026-07-05.md,
  plan/issues/multi-host-secure-wire-integration-freeze-2026-07-05.md

## Finding

The macOS path assumes the Fedora 44 guest can see the host workspace tree at
`/home/forge/src`, but the VZ configuration audit found no actual virtio-fs device
or guest mount despite comments/features claiming it.

This can break several user-visible paths even when the secure wire itself works:

- embedded guest binary staging into the VM;
- local project enumeration;
- cloud checkout persistence;
- project source mount into the deepest forge container;
- top-host terminal attach to an agent harness launched by
  `tillandsias-headless --cloud <project> --<agent>`.

## Work

Add a real macOS VZ virtio-fs share for host `~/src` and mount it in the Fedora 44
guest at `/home/forge/src` before the `tillandsias-headless` service starts.

## Acceptance Evidence

- VZ config includes the virtio-fs device/share.
- Guest boot evidence shows `/home/forge/src` mounted before headless starts.
- `~/src/.tillandsias/guest-bin/tillandsias-headless` is consumed without any
  `releases/latest` network fetch.
- `EnumerateLocalProjects` sees host projects.
- A packaged cold boot can launch a cloud project into a forge agent from the
  top-host terminal.

## Ownership

macOS owns the code changes in `crates/tillandsias-vm-layer/src/vz.rs` and the
tray packaging path. Linux owns only the guest-binary artifact contract consumed
by this path.

## macOS meta-orchestration run 2026-07-05T18:53Z

Attempted `/meta-orchestration` -> `/advance-work-from-plan` selection on macOS.
This packet was the top macOS-owned implementation packet, but implementation
was not claimed because:

- local `osx-next` has uncommitted tracked and untracked tray/VM/package work;
- branch drift is above Dmax, so new platform feature work must wait for merge
  integration;
- Linux order 190 has not yet produced the staged two-arch guest-binary contract
  that this packet consumes.

Smallest next actions:

- Linux: complete order 190 (`scripts/build-guest-binaries.sh` + static/version
  litmus evidence).
- macOS: checkpoint or clean the existing `osx-next` WIP, merge `origin/linux-next`
  into `osx-next`, then claim this packet.
