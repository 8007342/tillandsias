# P1 [ROOT-CAUSED]: recipe headless unit's NoNewPrivileges+CapabilityBoundingSet hardening breaks ALL headless-driven podman; login/vault state never propagates (2026-07-12)

## DEFINITIVE ROOT CAUSE (supersedes the mechanism analysis below)

The recipe-path unit writer — `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs:523`
— ships the headless unit with:

```
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
```

Verified live: the headless ran as uid 0 with `CapEff: 0x400` (ONLY
CAP_NET_BIND_SERVICE) and `NoNewPrivs: 1`. Consequences, all confirmed on
the live guest:

- podman spawned by the headless has euid 0 but no CAP_SYS_ADMIN → podman
  selects ROOTLESS mode ("Using rootless single mapping"); NNP makes
  newuidmap file caps unusable → pause-process fatals; the rootless store
  is empty → "vault image missing" → on-demand build exits 125, liveness
  loops every 2s forever. Affects BOTH v0.3.260711.8 and v0.3.260712.1
  (the unit, not the binary, is the trigger — the earlier version-skew
  and restart-wedge theories below were partial views of this).
- Tray-driven flows (login one-shot, lane bring-up via `wsl.exe -d`) run
  with full root caps → work → containers genuinely healthy while the
  headless cannot even SEE them → tray stuck on "Ready — securing vault"
  with the GitHub Login item never flipping, exactly what the operator
  reported after two successful logins.
- Unattended e2e (provision + handshake) never exercises headless-driven
  podman on Windows, so the hardening regression shipped undetected; the
  zero-trust checklist item (selinux-zero-trust-vsock-policy-design
  §CapabilityBoundingSet) was applied without a podman-path validation.

Session recovery (validated): systemd drop-in override —
`NoNewPrivileges=no` + `CapabilityBoundingSet=~` (tilde form; note the
systemd gotcha that an EMPTY `CapabilityBoundingSet=` assignment means
the EMPTY SET, which we hit first and which made things worse) →
daemon-reload → restart → `CapEff: 000001ffffffffff` → vault ensured
healthy within seconds, events stream flowing, v0.3.260712.1 restored.

Product fix: remove the two directives from the wsl_lifecycle.rs unit
template (this cycle, windows-owned) + source pin test; file a follow-up
packet for reintroducing least-privilege correctly (split listener/
orchestrator units or podman socket delegation). The macOS vz.rs unit
must be audited for the same directives before its next release.

> macOS audit result (macos cycle, 2026-07-12): `grep -rn 'NoNewPrivileges\|
> CapabilityBoundingSet' crates/tillandsias-vm-layer/src/
> crates/tillandsias-macos-tray/src/` → no matches at osx-next `33da90ab`.
> The macOS unit templates do NOT carry the regression; audit ask satisfied.

---

# Original triage narrative (interim theories, kept for the record)

- class: bug (cross-host lifecycle/observability; Windows + likely macOS guests)
- found by: windows attended smoke (windows-bullo-fable5-20260712T1940Z) with the
  operator at the tray; supersedes-in-detail the same-day interim note
  headless-restart-wedges-guest-podman-2026-07-12.md (first observation of the
  same wedge before the mechanism was isolated)
- status: open
- trace: crates/tillandsias-headless (events watcher + vault bootstrap latch),
  images/vm bootstrap setcap step, WSL2/vz root-unit guests

## Operator-visible symptom

On a freshly provisioned Windows guest upgraded to headless v0.3.260712.1:
GitHub Login ran successfully TWICE (login one-shot container ran and exited
cleanly, credentials written), yet the tray stayed at "Ready — securing
vault" and kept showing the GitHub Login item — login state and
vault-secured never propagated. Meanwhile the guest journal filled with one
fatal every ~2s.

## Isolated mechanism (journal `_CMDLINE` metadata)

The failing process is the headless observability watcher:

```
_EXE=/usr/bin/podman  _CMDLINE="/usr/bin/podman events --format json"  _UID=0
Error: fatal error, invalid internal status, unable to create a new pause
process: cannot re-exec process to join the existing user namespace ...
warning: "Using rootless single mapping into the namespace"
```

UID 0 yet ROOTLESS mode: consistent with the watcher spawn dropping
capabilities (v0.3.260712.1 least-privilege hardening) — cap-stripped root
podman selects rootless mode. Rootless then needs the pause-process
machinery, which is doubly broken on the guest:

1. The Fedora Container Base strips newuidmap/newgidmap file capabilities;
   the provision's `setcap` repair (ensure_base_packages) DID NOT STICK —
   `getcap /usr/bin/newuidmap` was empty on a freshly provisioned guest
   (its failure is swallowed by `|| true`).
2. Even after manually restoring the caps, the live loop kept fataling on
   "join the existing user namespace" with NO pause.pid anywhere under
   /run or /tmp — pointing at inherited env state in the wedged headless
   (e.g. `_CONTAINERS_USERNS_CONFIGURED`) rather than an on-disk anchor.

The main lane spawns (vault/proxy/login containers) keep caps → rootful →
work fine; only the watcher is wedged. With the events stream dead, the
headless never observes the vault-secured / login-state transitions, so the
tray latches on "Securing vault" forever while the actual containers are
healthy. The watcher respawns unbounded every ~2s with no backoff and no
surfaced degradation.

## Compounding trigger observed earlier in the session

The first wedge instance appeared immediately after an in-place headless
binary swap + `systemctl restart` (podman pause-process state also survived
the restart; `podman system migrate` cleared THAT layer). A plain guest
reboot (`wsl --terminate` + tray auto-restart) is the operator-level
recovery for the watcher layer.

## Why P1 / cross-host

- Any Windows/macOS guest upgraded to v0.3.260712.1 (root systemd unit)
  can hit this; Linux hosts don't (headless runs as a user with working
  rootless podman).
- Breaks the primary first-run flow (login → cloud projects) invisibly.
- Unbounded 2s fatal loop = CPU + journal spam, never self-heals, never
  reports.

## Fix directions

1. Spawn the events watcher with the SAME privilege context as the lane
   spawns (rootful on root-unit guests) — the watcher must observe the
   store the containers actually run in (a cap-dropped rootless watcher on
   a rootful store would also see zero events even if it ran).
2. Make ensure_base_packages' setcap step fail loud (drop the `|| true`),
   and add a provisioning-time `getcap` assertion (order-297 pattern).
3. Watcher respawn needs backoff + a structured degraded signal on the
   control wire after N consecutive failures.
4. Vault-secured/login-state latch should have a poll fallback when the
   events stream is down (state was queryable all along).

## Repro

Fresh WSL2 provision → upgrade guest headless to v0.3.260712.1 → restart
unit → run GitHub Login. Login succeeds; tray never leaves "securing
vault"; journal shows the 2s `podman events` fatal loop.
