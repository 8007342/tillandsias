# vsock-exec-authz

The host-to-guest-to-container exec path crosses a critical trust boundary: the host shell or tray uses the vsock control wire (`PtyOpen`) to spawn arbitrary commands in the VM guest. Without an authorization boundary, any process that can write to the control wire could execute arbitrary code as the VM root.

## Policy

1. **Allowlist Enforced:** The `tillandsias-headless` vsock server MUST validate the `argv` in a `PtyOpen` envelope against an explicit allowlist before calling `fork()` + `exec()`.
2. **Permitted Executables:** The only permitted targets are:
    - `/bin/bash`
    - `tillandsias`
    - `podman`
    - `tillandsias-headless`
3. **Project Name Validation:** When `podman exec` is requested, the target container name MUST follow the format `tillandsias-{project}-forge`. The `{project}` name MUST be validated against a strict alphanumeric-and-hyphen character set (`^[a-zA-Z0-9-]+$`).
4. **Proxy Exemption:** All in-VM child processes executed via this boundary MUST inherit the proxy exemption pattern (`no_proxy` and `NO_PROXY` set to `enclave_no_proxy()`) so that direct-to-enclave service requests bypass external routing.

## Rejection

Violations of the allowlist MUST return `ErrorCode::Internal` via the `PtyOpenError::Spawn(PermissionDenied)` path, terminating the PTY launch sequence before any OS processes are created.
