# Tasks — stable-upgrade-converge

Depends on `hot-upgrade-live-stack` (1490-gttj) landing its handoff, labels and
updater first. Nothing is filed until the operator answers the open questions
in `design.md`. Each task becomes one packet with a test that fails today.

## 1. Pass and marker
- [ ] 1.1 `tillandsias --converge` and the post-install trigger, with a
      `state/converged-<version>` marker, resumable, run only on stable.

## 2. Guest OS
- [ ] 2.1 macOS: run the #801 upgrade block on an existing VM, not only at
      provision; verify with dnf and rpm; on failure rebuild `rootfs.img`
      keeping the identity disk.
- [ ] 2.2 Windows: the same upgrade in the distro; on failure report, never
      regenerate (Q2).
- [ ] 2.3 A pending kernel restart at the next zero-forge moment (Q1).

## 3. Images and stack
- [ ] 3.1 Rebuild enclave and forge images for the new version, with
      remove-and-rebuild on failure.
- [ ] 3.2 Shared-stack swap through the 1490-gttj skew policy, never stopping
      a running forge.
- [ ] 3.3 Prune old images and stale owned objects by label.

## 4. Reporting
- [ ] 4.1 `converge-failed:<component>` in the tray and `--diagnose`; no
      automatic HARD reset.
