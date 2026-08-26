# enhancement: proxy container unstartable after VM reboot (tmpfs CA mount) + no in-VM egress for dev builds — 2026-07-06

- class: enhancement
- owner: linux (headless provisioning); windows evidence
- status: open
- found_by: windows-bullo-fable5-20260706T0535Z during order-191 flag-ON smoke
- trace: plan/issues/multi-host-secure-wire-integration-freeze-2026-07-05.md,
  plan/issues/enclave-container-lifecycle-races-2026-07-02.md (R5 supervisor ownership)

## Finding

While producing the order-191 Windows flag-ON evidence, the in-VM guest rebuild
needed crates.io egress. Two independent fragilities surfaced:

1. **`tillandsias-proxy` cannot be started by hand after a VM reboot.**
   `podman start tillandsias-proxy` fails with
   `crun: cannot stat /tmp/tillandsias-ca/intermediate.key: No such file or
   directory` — the container bind-mounts the CA material from `/tmp` (tmpfs),
   which is wiped on every WSL VM teardown. Only the headless's
   `ensure_proxy_running` path (which regenerates the CA) can bring it back.
   Any operator or sibling process that reasonably runs `podman start` on the
   existing container gets a confusing OCI error. Options: persist the CA under
   `/var/lib/tillandsias/ca` (0700) instead of `/tmp`, or have the container
   regenerate missing CA material in its entrypoint, or label the container
   `ephemeral` and let the supervisor recreate rather than restart it (aligns
   with R5 supervisor-ownership in order 162).

2. **The distro's default DNS (`10.255.255.254` WSL NAT proxy) did not resolve**,
   so even direct (non-proxied) egress failed until `/etc/resolv.conf` was
   pointed at a public resolver. If proxied egress is the design intent, cargo/
   dnf inside the VM should be documented to go through the squid proxy
   (`.crates.io` is already allowlisted) once (1) is fixed.

## Workaround used (documented for the next agent)

Offline in-VM build loop: `cargo fetch --locked` on the Windows host, mount the
host `.cargo` into the distro (`mount -t drvfs C:\Users\<u>\.cargo /mnt/hostcargo`),
copy `registry/{cache,index}` to `/root/.cargo/registry/`, then
`cargo build --release --offline` under `systemd-run --collect`. ~4 min warm.

## Smallest next action

Linux owner: move the proxy CA bind source off tmpfs (or regenerate in the
entrypoint) and add a litmus that `podman start tillandsias-proxy` succeeds on a
freshly booted VM without the headless ensure path having run.

## 2026-08-23 — second host reproduction (yoga, Silverblue, bare metal — not a VM)

Same shape outside any VM: after a host reboot (~9h before), `podman start
tillandsias-proxy` failed with `crun: cannot stat /tmp/tillandsias-ca/
intermediate.crt: No such file or directory` — tmpfs wiped the CA, the
container definition still binds it. `tillandsias-vault` was also down
(SIGKILL at shutdown, `restarts=0`) but started cleanly by hand; the asymmetry
is precisely the /tmp bind. cycle-preflight's fail:enclave-service-dead caught
vault; the proxy only rated a note. Re-running `scripts/orchestrate-enclave.sh`
regenerated the CA and brought the proxy up, but that script is a full
lifecycle harness: its cleanup step REMOVED the proxy (and git mirror and
inference containers) on exit, so the "remedy" leaves the host with no proxy
container at all — recreated on demand by the product's ensure_proxy_running.
Two open questions this adds to the original: (a) enclave services on a
durable dev host have no restart policy or unit, so every reboot leaves
vault/proxy dead until a cycle's preflight notices; (b) the documented remedy
path for the proxy (orchestrate-enclave.sh) is not a service-repair tool.
Second independent host observation of the /tmp CA bind — promotion candidate,
noted for the Tlatoāni, not promoted (2026-08-19 ruling).
