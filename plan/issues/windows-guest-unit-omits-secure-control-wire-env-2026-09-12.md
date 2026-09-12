# The WSL guest unit omits `Environment=TILLANDSIAS_SECURE_CONTROL_WIRE`, which macOS writes — so any operator use of that variable on Windows is a silent one-sided flip and an outage

**Filed:** 2026-09-12 · **Kind:** bug · **Priority:** p1 · **Capability tags:** windows, control-wire, provisioning, security-posture
**Host:** ESMERALDINHA (Windows 11 + WSL2), found while bisecting 1084-x8ya
**Ordered by:** macuahuitl-fedora (coordinator), 2026-09-12

trace: crates/tillandsias-vm-layer/src/vz.rs `provision_user_data` (macOS — writes it)
       crates/tillandsias-windows-tray/src/wsl_lifecycle.rs `inject_bootstrap_logic` (Windows — omits it)
       crates/tillandsias-vm-layer/src/wsl.rs `headless_unit` (WSL — omits it)
       crates/tillandsias-control-wire/src/secure_wire_mode.rs (order 972-umik, the ONE reader)

**This defect stands regardless of what ultimately caused 1084-x8ya.** It was
found during that bisect, but it is not contingent on it.

## Claim

`TILLANDSIAS_SECURE_CONTROL_WIRE` decides whether the control wire runs the
Noise handshake or passes plaintext. On macOS the host's resolved mode is
substituted into the guest's systemd unit, so both ends agree. On Windows/WSL
that line is simply not written, so the host's value reaches the host only.

macOS, `vz.rs` `provision_user_data`:

```
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200
Environment=TILLANDSIAS_SECURE_CONTROL_WIRE=__SECURE_CONTROL_WIRE__   <-- substituted from the host's mode
ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420
```

Windows, `wsl_lifecycle.rs` `inject_bootstrap_logic`:

```
Environment=HOME=/root
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200
{low_power_env}ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420
```

The three sibling variables are present on both. Only the secure-wire line
differs. `wsl.rs` `headless_unit` writes the same shorter set.

## Why this is a defect and not a cosmetic gap

`secure_wire_mode.rs`'s own module documentation states the rule this breaks:

> "flipping one side of it is not a smaller version of flipping both, it is an
> outage."

and describes the macOS behaviour as load-bearing:

> "its value PROPAGATES INTO THE GUEST through the systemd unit it writes, so a
> host-side silent default becomes the guest's default too."

That sentence is true of `vz.rs` and false of the WSL path. So on Windows:

- An operator who sets `TILLANDSIAS_SECURE_CONTROL_WIRE=off` (to disable
  encryption for debugging, or on any documented guidance) flips the host to
  plaintext while the guest stays secure. The wire fails. Nothing in the error
  names the variable, the asymmetry, or the guest's mode.
- The same applies in reverse for any future non-default value.
- The failure surfaces as `hvsocket open: secure handshake failed: noise: input
  error` — a message that points at the transport and tells the operator
  nothing about the actual cause.

Today both sides default to On when the variable is absent (972-umik made
absent mean On), so the DEFAULT path happens to agree by coincidence rather
than by construction. The agreement is not maintained by anything: it survives
only while nobody sets the variable and while both binaries share the same
default. That is exactly the "looks-configured-does-nothing" shape the
neighbouring comment in `wsl_lifecycle.rs` says it exists to remove.

## Measured

Established by reading both unit writers at the cited lines, and confirmed
operationally: an attempt to use the host-side variable as a diagnostic lever
on this host cannot work, which is why the coordinator's proposed test A was
redesigned to edit the guest unit directly. A host-side export alone is
untestable on Windows by construction.

## Exit criteria

- "the WSL/Windows guest unit carries the host's resolved secure-wire mode, as the macOS unit does; pre-fix result: FAILS (line absent from `inject_bootstrap_logic` and `headless_unit`)"
- "setting TILLANDSIAS_SECURE_CONTROL_WIRE=off on a Windows host and re-provisioning produces a working plaintext wire, not a handshake failure; pre-fix result: FAILS (host-only flip, guest unchanged, wire down)"
- "NEGATIVE CONTROL: with the variable unset, the Windows guest still runs SECURE — the fix must propagate the resolved mode, never weaken the default to whatever the guest happens to do"
- "a check refuses a guest unit writer that omits the variable, so the two platforms cannot drift apart again; pre-fix result: FAILS (no such check — `build.sh`'s `check-secure-wire-single-reader.sh` step guards only against NEW READERS of the variable, not against writers that fail to propagate it)"

## Note on the existing guard

`build.sh`'s `check-secure-wire-single-reader.sh` step refuses "a new reader of TILLANDSIAS_SECURE_CONTROL_WIRE
appeared (972-umik)" and `scripts/check-secure-wire-single-reader.sh` enforces
the one-reader rule. Both police READERS. Neither notices that one of the two
guest-unit WRITERS does not pass the value on, which is how this survived the
order that unified everything else.
