# Change: fix-podman-machine-host-aliases

## Why

User-reported failure on Windows 11 + podman 5.8 / WSL machine:

```
[forge@dc11fe398f99 src]$ git clone git://localhost:9418/test1
fatal: unable to connect to localhost:
localhost[0: 127.0.0.1]: errno=Connection refused
```

Root cause: the previous Windows/macOS port-mapping fix (commit `df4c63c`) made two changes that compounded into a broken setup:

1. `--add-host alias:127.0.0.1` was injected for `proxy`, `git-service`, and `inference`. Inside the forge container, `127.0.0.1` is the container's own loopback — not the host. Nothing is listening on the forge's loopback, so `proxy`, `git-service`, `inference` all resolved to dead ends.
2. The env-var rewrites (`HTTP_PROXY=http://localhost:3128`, `TILLANDSIAS_GIT_SERVICE=localhost`, `OLLAMA_HOST=http://localhost:11434`) re-targeted everything at the same broken `localhost` from inside the container.

The user's observed symptom was the git clone retry loop falling through to `[forge] WARNING: DEGRADED — git clone failed, dropping to shell without project code`.

## What Changes

- `--add-host alias:127.0.0.1` → `--add-host alias:host-gateway` in `src-tauri/src/launch.rs`. `host-gateway` is the magic value Podman/Docker resolve at runtime to the container's gateway IP — which on a podman-machine WSL setup is the WSL VM's gateway and is reachable from inside the container.
- Revert the env-var rewrite. The friendly aliases now route correctly via `--add-host`, so containers can use `proxy:3128`, `git-service:9418`, `inference:11434` exactly as they would on Linux with the real enclave network. `rewrite_enclave_env` is left in place as a no-op hook for hypothetical future setups that need different values.
- Keep `EnclaveCleanupGuard` (CLI mode) and `shutdown_all` (tray mode) unchanged.
- Update tests to assert the friendly-alias env-vars + the `--add-host alias:host-gateway` flags appear in podman args under port-mapping mode.

## Capabilities

### Modified Capabilities
- `enclave-network`: under podman machine, friendly enclave aliases (`proxy`, `git-service`, `inference`) resolve via `--add-host alias:host-gateway` instead of `127.0.0.1`. Env vars use the alias names, not `localhost`.

### New Capabilities
None — pure defect fix.
