# Chromium framework `--no-sandbox` probe is a false negative

Date: 2026-08-05 (America/Los_Angeles)
Status: ready
Plan: `chromium-framework-no-sandbox-probe-false-negative` (order 612-nvf3)
Release: v0.5

## Reproduction

The clean local-build E2E for generated version `0.4.260806.1` rebuilt the
Chromium framework image and ran it with the product hardening boundary:
network disabled, read-only root, all capabilities dropped,
`no-new-privileges`, rootless keep-id, bounded PIDs, and ephemeral `/tmp`.

The image entrypoint tries to decide whether to add Chromium's internal
`--no-sandbox` switch by searching `chromium --help` for that spelling. Fedora
44 Chromium 150 accepts and requires the switch under this container boundary,
but does not advertise it in that help output. The entrypoint therefore omitted
the switch and Chromium exited 139 after:

```text
FATAL:content/browser/zygote_host/zygote_host_impl_linux.cc:221
Check failed: . : Permission denied (13)
```

The otherwise identical invocation with an explicit `--no-sandbox` returned
zero and emitted the expected DOM. Outer containment remained unchanged. This
is a capability-probe false negative, not evidence that the container should
gain capabilities, writable root, or network access.

## Contract mismatch

`spec:browser-isolation-tray-integration` says the image entrypoint owns this
switch and adds it only after verifying support. The current implementation
equates “not printed by `--help`” with “unsupported”, which is false for the
shipped Fedora Chromium. A caller workaround would violate the same spec's
parser/ownership boundary and leave normal tray launches broken.

## Exit contract

- Replace the help-text substring test with a bounded support decision that is
  correct for the shipped Chromium and fails closed for wrappers that genuinely
  reject the switch.
- Add a fixture for both shapes: accepted-but-unadvertised (Fedora current) and
  explicitly rejected wrapper.
- A product-shape hardened container launch succeeds without the caller adding
  `--no-sandbox`, while still using network-none, read-only root,
  `CAP_DROP=ALL`, `no-new-privileges`, keep-id, and ephemeral writable state.
- The top-level Tillandsias parser continues to reject `--no-sandbox`; no UX or
  outer isolation policy changes.
- Preserve the clean E2E reproduction and retry receipts in the Linux smoke
  report.
