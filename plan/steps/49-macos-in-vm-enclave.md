# Step 49 — macOS in-VM enclave provisioning (the keystone the macOS tray is missing)

- **Status**: open (ready to claim)
- **Owner host**: macos (primary) + linux/recipe (coordination — enclave recipe is Linux-owned)
- **Branch**: osx-next (macOS wiring) / linux-next (recipe contract)
- **Depends on**: []
- **Blocks**: `macos-tray/github-login-pty-hangs-gray`, `macos-tray/empty-project-lists-and-poll-error-masking`, macOS m8 release-acceptance gate
- **Specs**: vm-provisioning-lifecycle, vm-idiomatic-layer, macos-native-tray, forge-as-only-runtime
- **Audit origin**: `plan/issues/macos-m8-interactive-smoke-failures-2026-06-16.md` (finding F2, CRITICAL)

## Why this exists (the finding and its consequence)

The first **user-attended (m8) smoke** of the macOS `Tillandsias.app` (2026-06-16)
FAILED. The status chip showed **"VM Failed"** even though the guest OS booted
cleanly. Root cause, diagnosed from `crates/tillandsias-vm-layer/src/vz.rs`:

> The macOS cloud-init user-data provisions ONLY `tillandsias-headless-fetch.service`
> + `tillandsias-headless.service`. It has **zero podman / forge / enclave / dnf
> setup** (`grep -cE 'podman|dnf|enclave|forge' vz.rs` = 0). The headless agent
> boots and answers vsock, but finds no podman and no forge enclave inside the
> guest → `podman_ready=false` → reports `Failed`.

**Consequence — the macOS tray is non-functional at the interaction layer.**
Everything a user clicks needs the in-VM enclave that was never provisioned:
- local/cloud project lists are empty (F5),
- GitHub-Login opens a terminal that hangs gray (F4 — no forge container to attach to),
- agents / Attach Here / Open Shell all have nothing to attach to.

On Linux, podman runs on the host. On macOS (and Windows), the enclave MUST run
INSIDE the guest VM. That path was specced but never wired into the macOS
first-boot. `images/vm/bootstrap/30-enclave.sh` (the recipe enclave step) exists
but is NOT invoked by the macOS cloud-init.

## Goal

Make a freshly-provisioned macOS VM bring up the full forge enclave inside the
guest so the headless reports `podman_ready=true` / phase `Ready`, and the tray's
projects / agents / attach / github-login features work — i.e. the m8
user-attended smoke passes.

## Where to look

- `crates/tillandsias-vm-layer/src/vz.rs` (~lines 360-437) — the macOS cloud-init
  `user-data` heredoc; this is where the enclave setup must be added/invoked.
- `images/vm/bootstrap/30-enclave.sh` + `images/vm/Recipefile` + `images/vm/manifest.toml`
  — the Linux-owned enclave recipe to reuse rather than re-implement.
- `crates/tillandsias-headless/` — the in-VM agent: does it self-bootstrap podman,
  or assume podman is present? This decides the strategy below.
- Container security invariants (`--cap-drop=ALL`, `--security-opt=no-new-privileges`,
  `--userns=keep-id`, `--rm`) must hold for the in-VM forge too.

## Design decision required (record in this step before implementing)

Pick ONE and document the trade-off:

1. **Cloud-init installs + builds the enclave**: extend the macOS user-data to
   `dnf install podman` (+ deps) and run the `30-enclave.sh` recipe on first boot.
   Pro: reuses the recipe; Con: heavy first-boot (dnf + image builds inside a
   nested VM), long provision, network-dependent.
2. **Headless self-bootstraps podman+forge** on first run (the agent owns enclave
   lifecycle in-VM). Pro: single owner, host-agnostic; Con: moves recipe logic
   into the agent; must not duplicate the Linux host enclave path.
3. **Bake podman+enclave into the materialized rootfs** at provision time (host
   materializes a richer image, not bare Fedora Cloud). Pro: fast cold boot; Con:
   macOS can't run the Linux image build toolchain natively (the existing
   materialize/macos.rs note) — would need the recipe pre-built and fetched.

Coordinate with the Linux/recipe owner: the in-VM enclave contract (image
digests, network, vault) must match Linux so trays converge.

## Tasks (implement in order)

- [ ] 49a — **Decision**: choose the enclave strategy above; write it into this
      step + `openspec/specs/vm-provisioning-lifecycle` (or macos-native-tray).
- [ ] 49b — Wire the chosen path into the macOS cloud-init (`vz.rs` user-data):
      podman present + enclave started on first boot. Keep security flags.
- [ ] 49c — Headless must report `podman_ready=true` / phase `Ready` once the
      enclave is up; verify over vsock from the host (vm-status poll).
- [ ] 49d — Re-run the macOS m8 user-attended smoke; projects list, github-login
      terminal yields a working shell, Attach Here opens a forge shell.
- [ ] 49e — Add an automated post-provision assertion (host-side) that the VM
      reaches `Ready` within a bound, so this can't silently regress to "Failed"
      again (the autonomous smoke must catch enclave-down, not just disk-present).

## Acceptance

- Fresh `--provision` + tray launch → chip reaches **Ready** (podman_ready=true),
  verified from the host vsock poll (not just guest OS boot).
- m8 7-step user-attended smoke passes (projects populate; github-login + attach
  open working forge shells).
- Container security invariants verified on the in-VM forge.
- An automated gate fails loudly if the VM stays `Failed`.

## Cross-host coordination

The enclave recipe (`images/vm/`) is Linux/recipe-owned; the in-VM enclave must
match the Linux host enclave (same images, network, vault contract). File the
recipe-side asks on `linux-next` and the macOS wiring on `osx-next`; do not fork
a second enclave definition (tombstone/supersede, never duplicate).
