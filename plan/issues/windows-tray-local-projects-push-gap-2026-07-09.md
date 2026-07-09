# LocalProjects is the last poll-only topic — blocks tick-loop retirement (enhancement)

- **Filed**: 2026-07-09T23:10Z, windows host (`windows-bullo-fable5-20260709T2238Z`),
  during order 154 slice 2.
- **Classification**: enhancement
- **Promoted**: `plan/index.yaml` order 260 (`windows-tray-local-projects-push-gap`,
  linux-owned).

## Observation

Order 154's exit criterion "No `tokio::time::sleep` in notify_icon.rs transport
path (SC-01, SC-02)" cannot be met yet. After slice 2:

- `VmStatus`, `LoginState`, `CloudProjects` all arrive as change-gated pushes on
  the dedicated reader-task connection; their requests are fallback-only.
- `EnumerateLocalProjects` has **no push topic** — `SubscriptionTopic` has only
  the three variants above, and the headless has no push source for the VM-side
  project reconciliation that backs `LocalProjectsReply`.

So the windows tray's 30s tick loop must survive solely to poll local projects
(and to host the fallback polls while the subscription is down). The same will
hold for the macOS tray when order 155 lands.

## Smallest next action

Land order 260 (linux): additive `SubscriptionTopic::LocalProjects` +
`LocalProjectsPush` wire variant, plus a change-gated push source in
`vsock_server.rs` following the `set_login_state` / `set_cloud_projects`
pattern (744f4749). Then a small windows slice widens
`vm_status_subscribe_topics()` and deletes the last steady-state poll,
reducing the tick loop to a subscription-health-gated fallback.

## Note on the host-side `~/src` scanner

The host-side filesystem scanner (immediate local updates without a VM) is
independent of this wire topic and stays — only the *wire poll* cadence is in
scope here.
