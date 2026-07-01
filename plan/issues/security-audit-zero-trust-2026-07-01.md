# Zero-Trust Enclave Boundary Audit — 2026-07-01

- class: security-audit
- filed: 2026-07-01
- owner: linux
- status: open
- scope: host↔VM (vsock) · VM↔guest · guest↔podman · container↔container (enclave) · enclave↔proxy↔internet · Vault access · transparent exec/pipe chain
- trigger: post-`zeroclaw` / post-`vsock` / post-transparent-exec complexity growth; operator asked for "zero trust at every boundary, sound and complete for a fully isolated agent environment."

## Cold-start summary

The enclave *network* boundary (container↔container, proxy dual-homing) is
well-specified and matches code. The **new** surfaces added in the recent
concurrent wave — the vsock host↔guest transport and the transparent
host→VM→`podman exec` chain — are **unauthenticated end to end** and have **no
governing authorization spec or litmus**. The single largest risk is that any
peer able to open an AF_VSOCK connection to the guest can execute arbitrary
commands inside the deepest forge container and read a root Vault token. On a
1:1 single-CID VM this is bounded to host-local peers, but it is defense-in-depth
zero, is spec-sanctioned ("SHALL accept connections from any CID"), and does not
survive any future multi-CID / nested-VM / shared-hypervisor topology.

`zeroclaw` is **gone** (crate/image/binary removed after the order-114
unauthorized-release violation); only an empty orphan `images/zeroclaw/skills/`
directory remains. The Vault XOR init.envelope is **gone** and root.token is no
longer persisted to durable storage — but see P1-1 for a tmpfs residual.

---

## P0 findings

### P0-1 — vsock control wire has no peer authentication; transparent exec is unauthenticated end to end

**Boundary:** host↔VM (vsock) → guest → `podman exec` (deepest container).

**Evidence:**
- `crates/tillandsias-headless/src/vsock_server.rs:197` binds on
  `VMADDR_CID_ANY` and `:229` accepts every connection.
- `vsock_server.rs:266-277`: the only gate is the `Hello` frame; `hello_from`
  is a **self-reported, unvalidated string** (`ControlMessage::Hello { from, .. }`).
  There is no peer-CID check, no shared secret, no capability token. HelloAck is
  returned to anyone.
- `vsock_server.rs:499-508`: on `PtyOpen` the guest forks+execs the
  client-supplied `argv` verbatim (`pty_handler.rs::open`), with `env_clear`
  then `TERM` re-added.
- `crates/tillandsias-host-shell/src/pty/mod.rs:177-190`: for a project the host
  wraps `argv` as `podman exec -it tillandsias-<p>-forge <cmd>`. So a vsock peer
  controls both the container target and the command run in the **deepest**
  container — transparently, as designed, but with zero authZ.
- The wire protocol reserves but does not use auth:
  `crates/tillandsias-control-wire/src/lib.rs:349` — `Unauthorized` is
  "Reserved for future use; **v1 enforces auth via filesystem permissions**."
  That statement is false for vsock: vsock is a socket-address family, **not**
  filesystem-gated the way `$XDG_RUNTIME_DIR/tillandsias/control.sock` is. The
  auth model that protects the Unix transport does not extend to vsock, and
  nothing replaced it.
- Spec sanctions it: `openspec/specs/vsock-transport/spec.md:61` — "**it SHALL
  accept connections from any CID**." The spec contains no authentication or
  authorization requirement; grep for `authoriz|authenticat|peer|trust` in the
  vsock/host-guest/security specs returns nothing on this boundary.

**Impact:** Any local process that can reach the guest CID:port `42420` can (a)
run `/bin/bash` on the bare VM (the "debug escape hatch," `pty/mod.rs:139`), and
(b) `podman exec` into any `tillandsias-<p>-forge` container. Chained with P1-1,
it can read a Vault **root** token. This is the exact class of "any local process
can invoke host-level commands with no isolation" that got the zeroclaw MCP
socket killed in the order-114 violation report — reintroduced on vsock.

**Why bounded today / why it still matters:** VZ/WSL give the VM a single guest
CID and the host connects from `VMADDR_CID_HOST=2`; on a default single-tenant
laptop the only peer that can reach the CID is the host itself. But zero-trust
means *don't rely on the topology for authZ*. There is no failure-closed default,
no litmus asserting rejection of an unauthenticated peer, and the invariant that
"only the host tray may drive exec" is unenforced and untested.

**Shaped packet:**
1. Add a per-boot shared authentication token to the `Hello`/`HelloAck`
   handshake (host injects it into the guest at provision time via the existing
   Vault/handover tmpfs, not via argv). Reject connections whose `Hello` lacks
   the token with `ErrorCode::Unauthorized` and close.
2. Add a spec requirement to `vsock-transport` + `host-guest-transport`:
   "the guest MUST authenticate the peer before serving any `PtyOpen`/exec;
   unauthenticated peers MUST be rejected failure-closed."
3. Bind a litmus (`litmus:vsock-exec-requires-auth`): an unauthenticated peer
   sending `Hello` then `PtyOpen` MUST receive `Unauthorized` and no child is
   spawned.
4. Consider an allowlist of legal exec targets (see P1-2) so even an
   authenticated peer cannot run arbitrary argv on the bare VM outside the
   Shell debug intent.

---

## P1 findings

### P1-1 — Vault root token persists in container tmpfs, never shredded after host capture

**Boundary:** secrets (Vault) access path.

**Evidence:**
- `images/vault/entrypoint.sh:108-115`: on first boot, `operator init` writes
  `$ROOT_TOKEN` to `/run/vault-handover/root.token` (tmpfs, dir mode 077).
- `crates/tillandsias-headless/src/vault_bootstrap.rs:1556-1566`: the host reads
  it back via `podman exec vault cat /run/vault-handover/root.token`.
- **No shred/unlink anywhere.** grep for `shred|rm .*handover|unlink` in the
  entrypoint and `vault_bootstrap.rs` finds nothing. The file survives for the
  container's lifetime (until the tmpfs is torn down on container stop/reboot).

**Impact:** A root Vault token sits readable inside the vault container for as
long as it runs. Anyone who can `podman exec` into `vault` (see P0-1) reads
full-privilege Vault credentials. The XOR-envelope / durable-root.token P0 from
the 2026-06-05 pre-vault audit was fixed, but the *ephemerality* half is
incomplete: the token is ephemeral in *storage* but not *shredded after use*.

**Good news confirmed:** on subsequent boots `ROOT_TOKEN=""` and the token path
is skipped (`entrypoint.sh:120-155`); the durable `init.envelope`/root.token
persistence is gone. This finding is only about the first-boot handover residual.

**Shaped packet:** after the host confirms capture (keychain write succeeds),
send a control message (or have the entrypoint self-shred after a bounded
handover window) to `shred -u /run/vault-handover/root.token
/run/vault-handover/unseal.key`. Add a litmus asserting the handover files are
absent within N seconds of a successful first-boot bootstrap.

### P1-2 — No governing spec or litmus for the transparent exec authorization boundary

**Boundary:** guest↔podman transparent exec.

**Evidence:** `host-guest-transport` spec defines the *primitives*
(`InteractiveStream`, `ExecOneShot`) and their framing, but says nothing about
**who may invoke exec, against which containers, with which argv**. The
`podman exec -it tillandsias-<p>-forge` wrapping lives only in
`pty/mod.rs:177` with no spec backing and no litmus binding. `security-privacy-isolation`
mentions exec only at `:67` ("MUST NOT be the runtime execution path") — which
this arguably contradicts, since the tray now *is* driving an interactive exec
path into the forge. This is spec/code drift: a new trust boundary exists in
code with no authoritative intent.

**Shaped packet:** author the authorization contract as a spec requirement
(complements P0-1), and record the `security-privacy-isolation:67` tension
explicitly (is tray-driven `podman exec` an approved runtime path or a debug
path?).

### P1-3 — Project name is interpolated into the exec target without validation

**Boundary:** guest↔podman.

**Evidence:** `pty/mod.rs:184` — `format!("tillandsias-{p}-forge")` where `p`
comes from the host-selected project. It becomes a single argv element (no
shell), so classic shell injection does not apply, and podman treats it as a
container name. But there is no allowlist tying `p` back to the local scanner's
enumerated projects, so a malformed/attacker-influenced `p` could target an
unexpected container name or probe container existence.

**Shaped packet:** validate `p` against `EnumerateLocalProjects` output (or a
`^[a-zA-Z0-9._-]+$` allowlist) before building the exec argv; reject otherwise.

---

## P2 findings

### P2-1 — Proxy-exemption pattern unverified on the new direct-to-enclave paths; no e2e gate

The order-116/118/119 P0 pattern requires every direct-to-enclave-service / build
/ exec path to **explicitly exempt** the proxy (`NO_PROXY`/`no_proxy`). The new
vsock/exec surfaces (`vsock_exec.rs`, `cloud_projects.rs`, the `podman exec`
wrapper) do not set proxy env themselves — they inherit process env. Only
`vault_bootstrap.rs:664` references the proxy issue. There is still **no e2e gate
for the github-login→list-cloud-projects chain** (memory: `enclave-proxy-exemption-pattern`).
`gh` egress legitimately needs the proxy; direct `vault:8200` / `podman` calls
must be exempted. Verify each new path's inherited proxy env and add the missing
e2e gate.

### P2-2 — `images/zeroclaw/` orphan directory remains

`images/zeroclaw/skills/` is an empty orphan left after the order-114
zeroclaw removal. The `litmus-no-dangling-removed-component-refs` litmus greps
file *contents*, so an empty dir slips through. Cosmetic drift, not a security
hole. Remove the directory; consider extending the litmus to flag orphan
component dirs.

### P2-3 — Verify SELinux parity between macOS guest and native Linux

macOS recently landed `vault_container_t` SELinux enforcement in the guest
(osx-next commits `1325bea9`, `c8460739`). `images/selinux/` ships
`tillandsias_vault.te`/`.fc` and `tillandsias_headless.te`/`.fc`. Confirm the
native-Linux runtime **loads and enforces** the same policy (not just ships the
files), so the isolation guarantee is identical across hosts. If Linux runs
permissive while macOS runs enforcing, that is a silent boundary asymmetry.

---

## P3 / observations

- **P3-1 `podman_ready` is a file-existence check** (`vsock_server.rs:112`,
  `podman_socket.exists()`) — reports ready on socket *presence*, not
  functionality. Readiness-only, not security-critical, but a compromised or
  half-started podman would still report Ready.
- **Confirmed clean:** enclave network isolation (`enclave-network` spec
  `:39-51` matches the dual-homed proxy design); Vault loopback addr inside the
  container (`https://127.0.0.1:8200`); no tokens in vsock `ControlMessage`
  variants (spec `no-tokens-in-messages` invariant, honored — the github-login
  flow delivers the token via PTY `/dev/tty` input, not argv,
  `vsock_exec.rs:106-118`, `vault_bootstrap.rs:1829-1863`).

---

## Priority order for remediation

1. **P0-1** — authenticate the vsock/exec chain (failure-closed) + litmus. Root
   blocker; unlocks a truthful "fully isolated" claim.
2. **P1-1** — shred the Vault root-token handover after capture.
3. **P1-2 / P1-3** — spec + validate the transparent exec authZ boundary.
4. **P2-1** — verify proxy exemption on new paths; add the github-login→list e2e gate.
5. **P2-2 / P2-3 / P3-1** — cleanup, SELinux parity check, readiness hardening.
