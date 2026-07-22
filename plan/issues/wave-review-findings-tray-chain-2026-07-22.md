# Final-wave adversarial review findings: tray-chain (reset / crashloop / login) residuals

- Date: 2026-07-22
- Class: bug (platform-behavior residuals in cfg-gated tray code)
- Source: read-only adversarial review (Fable) of ff4cff37 + 246b7a0e +
  cc8925b6. Compile-surface verdict was CLEAN (symbols/signatures/ownership
  resolved); the new CI windows/macos typecheck lanes now compile these
  bodies on every push. Findings below are BEHAVIORAL and platform-gated —
  most are best verified/fixed alongside the order-455 live smokes.

## Open findings

1. MAJOR (dormant since the leaf removal) — macOS reset path never clears
   the live in-memory crashloop detector (action_host.rs ~1736): a
   post-reset tray session keeps the pre-reset verdict. Only reachable via
   reset_guest_async (now dead_code) — fix when/if a reset ever regains an
   approved UX or auto-reset surface on macOS; mirror Windows'
   reset_crashloop_state().
2. MAJOR — Windows login fast-poll can revert LoggingIn -> LoggedOut
   mid-flow (notify_icon.rs ~3288): guard apply_github_login against
   downgrading a fresh LoggingIn (LOGIN_STARTED_AT grace window).
3. MAJOR — Windows auto/CLI reset during an ACTIVE provisioning run spawns
   two concurrent provision drivers (notify_icon.rs ~2666): abort the
   in-flight provisioning task (AbortHandle, KeepaliveGuard pattern) at the
   top of spawn_guest_reset.
4. MAJOR — Windows --reset-guest CLI lacks the live-tray gate macOS has
   (main.rs ~80): try-acquire the SingletonGuard non-blocking and refuse
   with guidance when the tray is running.
5. MINOR — macOS login flips to LoggingIn before attach_pty's no-VM gate
   (~1421): gate the flip on vm.is_some().
6. MINOR — macOS reset wipe-failure leaves chip stuck "Resetting guest…"
   with no error surface (~1758) [UX-text change requires operator
   approval per tray-ux governance].
7. MINOR — macOS vm_busy gate makes CLI-era reset silently no-op during an
   in-flight boot (~1701): queue or surface the refusal [same governance
   note].
8. INFO — diagnose.rs doc-comment splice: provision_main's docs attached to
   reset_guest_main (~397).
9. INFO — Linux tray hashed project ids can collide with low static ids
   (tray/mod.rs ~3188): floor hashed ids at >=1000.

## Exit criteria

2/3/4 fixed (typecheck lanes cover compilation; live behavior confirmed in
the order-455 Windows smoke); 5-9 fixed or rejected with events; 1 recorded
as dormant-by-design unless a reset surface returns.
