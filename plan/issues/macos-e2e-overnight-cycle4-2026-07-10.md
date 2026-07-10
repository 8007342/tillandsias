# macOS overnight cycle 4/8 — local-build e2e PASS + order 155 slice 4 live (2026-07-10T07:57Z)

- host: macos, osx-next @ 34838feb, unattended (overnight 4 of 8)
- preflight: `eligible`
- gate: build+codesign v0.3.260710.8 → install (~/Applications, SHA == HEAD
  34838feb) → DESTRUCTIVE substrate wipe (also cleared order 281's corrupt
  podman overlay store from cycle 3) → cold provision (528MB Fedora image
  download + convert, exit 0) → first-boot cloud-init → tray auto-boot to
  phase Ready.

## Order 155 slice 4 (LocalProjects push) — live evidence

- Establish line: `push subscription established (vm-status/login/cloud/local
  polls demoted to fallback, SC-07)` — the four-topic subscription (order 260
  cleared the LocalProjects blocker in cycle 1).
- `local-projects: menu_state updated (4 entries)` — the reader loop consumed
  the LocalProjectsReply (from the new initial-sync EnumerateLocalProjects
  prime) via the shared `apply_local_projects`, NOT the steady-state tick
  poll. The tick loop's whole slow-cadence block is now inside the SC-07
  fallback gate.
- Clean SIGTERM.
- Note: the ~/src menu SECTION is auth-gated (logged-out shows only "GitHub
  Login" — the Linux golden menu emits exactly one of {login} XOR
  {~/src+cloud}), so the 4 entries render post-login; the data path this
  slice wires is verified independently of that gate.

## Substrate note

Cycle 3's order-281 corruption is CLEARED — this cycle's destructive
re-provision rebuilt a clean rootfs + fresh cloud-init. Tray SIGTERM'd, not
left running (unattended). Morning operator gets a clean provisioned VM.
