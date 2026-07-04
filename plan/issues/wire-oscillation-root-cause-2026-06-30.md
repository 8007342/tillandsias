# Wire oscillation root cause + transport overhead audit

**Order 138** — filed 2026-06-30

## Observed symptom

After GitHub Login succeeded and the VM is in `Ready + podman_up` state,
the tray still oscillates between:

```
🟢 Ready — tillandsias-in-vm
🔴 Wire unreachable
🟢 Ready
🔴 Wire unreachable   (repeating every ~30-60s)
```

This is NOT transport buffer underruns. Each oscillation = one `LIVE_CLIENT`
teardown (headless process died) + one reconnect (headless restarted).

## Architecture context

```
Host poll (every 30s)
  └── live_client_request()
       ├── LIVE_CLIENT is Some → reuse persistent HvSocket TcpStream
       │    └── send VmStatusRequest, await VmStatusReply
       └── LIVE_CLIENT is None → spawn_blocking(connect_control_wire)
            └── wsl_utility_vm_id → hcsdiag list → AF_HYPERV connect
```

The persistent `LIVE_CLIENT` means connection overhead is amortized. When
the headless crashes, the LIVE_CLIENT stream returns an IO error → `*guard = None`
→ next poll tries reconnect. If headless has restarted by then, it succeeds →
`mark_wire_recovered`. Headless restarts again shortly after → another cycle.

## What needs investigation

1. **Why is the headless crashing?** Possible causes:
   - Vault not yet provisioned / TLS cert missing when headless tries to
     connect to it (race between headless start and Vault bootstrap)
   - `XDG_RUNTIME_DIR` not set in the systemd unit for the headless service
     (podman requires it; headless panics without it)
   - A panic in the headless after handling a `GithubLoginStatusRequest`
     or `CloudRefreshRequest` that the handler isn't expecting yet
   - The vsock listener drops the connection after one request (keepalive
     not working; headless closes the stream after each response)
   - systemd restart policy restarting too aggressively

2. **Is the vsock connection per-request or persistent?**
   The host `LIVE_CLIENT` is persistent, but the in-VM headless vsock
   listener may close the connection after each request (one-shot pattern).
   If so, the LIVE_CLIENT loses its stream on the second request, causing
   apparent "wire down" even though the headless is healthy.

3. **Transport overhead is negligible** (confirmed):
   - AF_HYPERV → `tokio::net::TcpStream` (kernel-managed, no userspace copy)
   - Postcard framing: `postcard::from_slice` is zero-copy, no heap allocation
     in the steady-state path
   - 30s poll cadence: one VmStatusRequest per 30s while wire is healthy
   - SESSION_CHANNEL_CAPACITY=256 frames bounds PTY channel memory

## Investigation steps

1. In WSL: `journalctl -u tillandsias-headless -n 50 --since "5 minutes ago"`
   to see headless crash logs
2. `wsl -d tillandsias -u root -- systemctl status tillandsias-headless`
   to see restart count and last exit code
3. Check the headless vsock listener code: does it close the stream after
   each response, or keep it alive for subsequent requests?
4. Check `inject_bootstrap_logic` in `wsl_lifecycle.rs`: does the injected
   systemd unit have `XDG_RUNTIME_DIR` set?
5. Check `vault_bootstrap.rs`: is there a startup race where headless starts
   before Vault is ready?

## Exit criteria

- [ ] Root cause identified (crash log or code trace)
- [ ] Fix landed in-VM (headless no longer oscillates after Ready)
- [ ] Wire oscillations stop: status stays at `🟢 Ready` between polls
- [ ] Document: confirm vsock listener is long-lived (not per-request)
- [ ] Add litmus: `litmus:headless-keepalive` — headless vsock listener
      must not close the stream after each response (integration test or
      protocol assertion)
