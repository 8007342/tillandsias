## ADDED Requirements

### Requirement: a converge pass runs once per installed stable version

After a stable release is installed (by `tillandsias --update`, the background
install, or a manual install), the new binary SHALL run a converge pass once,
recorded by a `state/converged-<version>` marker. A host already marked SHALL
skip it. An interrupted pass SHALL resume at the next start. Prereleases SHALL
NOT trigger it automatically. The pass SHALL be triggered by the install event
and SHALL NOT add a timer.

#### Scenario: the same version twice

- **WHEN** the tray restarts after a converge pass has completed for this version
- **THEN** no component is upgraded or rebuilt again

#### Scenario: interrupted pass

- **WHEN** the host stops during a converge pass
- **THEN** the next start runs the remaining steps, and the marker is written
  only after all of them finish

### Requirement: every reused component is upgraded fully or rebuilt from scratch

For each reused component the converge pass SHALL upgrade it fully in place and
verify it. On an upgrade failure, a verify failure, or a component that has no
in-place path, it SHALL throw that one component away and rebuild it from
scratch. A rebuild failure SHALL be reported as `converge-failed:<component>`
and SHALL NOT escalate to a HARD reset.

#### Scenario: an image fails to rebuild

- **WHEN** the proxy image build fails during a converge pass
- **THEN** the proxy image is removed and rebuilt from scratch, and if that
  also fails the tray reports `converge-failed:proxy-image` while every other
  component keeps running

### Requirement: the converge order is binary, guest OS, enclave images, shared stack, forge images, prune

The converge pass SHALL run its steps in this order:
1. the binary handoff;
2. the guest OS upgrade (macOS VM and Windows distro);
3. the enclave images;
4. the shared-stack swap;
5. the forge base images;
6. pruning by label;
7. a pending guest-kernel restart.

#### Scenario: guest OS before images

- **WHEN** a converge pass runs on macOS
- **THEN** `dnf upgrade` completes in the guest before any enclave image is
  rebuilt

### Requirement: running forges are never stopped by a converge pass

A converge pass SHALL NOT stop a running forge. A running forge SHALL keep its
image until it exits. A shared-stack swap and a guest-kernel restart SHALL wait
until no running forge depends on them.

#### Scenario: a forge is running during the upgrade

- **WHEN** a converge pass runs while a forge is attached
- **THEN** the forge keeps running on its old image, and only new launches use
  the new image

### Requirement: the converge pass never throws away operator data

A converge pass SHALL be a SOFT operation. It SHALL NOT delete or rewrite:
- the Vault store or its keyring share and root token;
- the model cache;
- project mirrors;
- `downloads/` or `config/`.

On Windows, where the Vault store lives inside the distro, a failed guest-OS
upgrade SHALL NOT regenerate the distro automatically.

#### Scenario: Windows guest upgrade fails

- **WHEN** `dnf upgrade` fails in the Windows distro during a converge pass
- **THEN** the distro is kept, `converge-failed:guest-os` is reported, and the
  Vault store is untouched

### Requirement: converge failures are fixed forward, never rolled back

A converge pass SHALL NOT downgrade any component, and SHALL NOT restore a
previous version. A component that cannot converge SHALL stay rebuilt or be
marked failed, and SHALL be fixed by a later release.

#### Scenario: a failed converge

- **WHEN** a component stays `converge-failed` after a stable install
- **THEN** no older binary or image is reinstalled, and the next stable release
  runs the converge pass again
