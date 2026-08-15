# The proxy's TLS-interception CA private key is world-readable in /tmp (755-qcxh)

- Date: 2026-08-15
- Host: linux_mutable (coordinator), answering question packet 657-vqxz
- Class: research/ → promoted security packet 755-qcxh in
  `plan/index.d/20260815t0605z-755-ca-key-worldreadable-linux-mutable.yaml`

## The determination 657-vqxz asked for

- `ensure_ca_bundle` (crates/tillandsias-headless/src/main.rs:2366) generates
  `intermediate.key` with `openssl req -nodes`, sets it to **0644**
  (`set_permissions(..., 0o644)` on the tmp file before rename), and
  **re-asserts 0644 on every pass** (`let _ = set_permissions(&key, 0o644)`)
  — the relaxation is deliberate, not an openssl default.
- `CA_DIR = "/tmp/tillandsias-ca"` (main.rs:1242): the key lives in the
  host's world-traversable `/tmp`.
- Production launches the proxy with a **bind mount**
  (`build_proxy_run_args`, main.rs:~2685: `-v …/intermediate.key:…:ro`).
  No launcher ever creates a `tillandsias-ca-key` podman secret — every
  `--secret` in main.rs carries the Vault token, not the CA. So in
  `images/proxy/entrypoint.sh` the SECRET branch (which chowns+chmods 600)
  is the unreachable one, and the bind-mount "fallback" is the only path
  the product takes. The packet's framing had it inverted.
- Why 0644 "works": under `--userns=keep-id` squid drops to the container
  `proxy` user, which is not the mapped owner of the host file; a 0600 key
  is unreadable to it (the filer's probe repro) and a 0644 key is readable
  to it — and to **every other uid on the host**.

## Why this outranks the startup failure (the real finding)

Any local process/user on the host can read the private key of the CA that
the enclave trusts for SSL-bumped traffic, and can therefore mint
certificates the enclave accepts. Scope limiter: the CA is locally
generated, 30-day, enclave-only — not a public trust root — and typical
hosts are single-user dev machines. It is still a private key with a
0644 mode sitting in /tmp.

## Fix directions (packet 755-qcxh)

1. Preferred: deliver the key as a podman secret (the entrypoint's secret
   branch already handles ownership correctly and becomes REACHABLE), or
2. Keep the bind mount but tighten to 0640 with a dedicated group mapped
   through keep-id, and move CA_DIR out of /tmp to the user cache dir
   (0700 parent), or
3. At minimum: 0600 + `--userns` uid-mapping so the container proxy user
   maps to the host owner.

Any fix must keep the 2026-07-22 field repro green (vault-cli's
require_cacert gate) and the SELinux relabel semantics (main.rs:7714).
