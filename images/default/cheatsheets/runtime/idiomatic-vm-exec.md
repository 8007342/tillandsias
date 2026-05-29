---
tags: [vm, exec, wsl, vz, idiomatic, contract, runtime]
languages: [rust, bash, powershell]
since: 2026-05-23
last_verified: 2026-05-23
sources:
  - openspec/specs/vm-idiomatic-layer/spec.md
  - openspec/specs/host-shell-architecture/spec.md
  - cheatsheets/runtime/podman-idiomatic-patterns.md
  - https://learn.microsoft.com/en-us/windows/wsl/basic-commands
  - https://developer.apple.com/documentation/virtualization
authority: medium
status: proposed
tier: bundled
---

# The idiomatic VM-exec layer

@trace spec:vm-idiomatic-layer
@cheatsheet runtime/podman-idiomatic-patterns.md, runtime/vsock-transport.md

**Use when**: writing host-shell code that needs to invoke a process inside the VM, debugging an exit-code or stdio mismatch between host and guest, or adding a new VM backend (e.g. KVM on Linux desktop).

## Provenance

- `cheatsheets/runtime/podman-idiomatic-patterns.md` — the prior-art contract this mirrors
- Microsoft Learn `basic-commands` — `wsl --exec`, `--distribution`, `--cd`, `--user`
- Apple Developer `Virtualization` — VZ process attach semantics (indirect; we tunnel via vsock)
- `openspec/specs/vm-idiomatic-layer/spec.md` — Tillandsias contract

## Why an idiomatic layer

The `tillandsias-podman` crate exists to keep raw `podman` shell-outs out of the rest of the codebase. The same discipline applies to `wsl.exe` and Apple's Virtualization.framework: every code path that needs to "run something in the VM" goes through `tillandsias-vm-layer::VmRuntime`. There are exactly **zero** sanctioned `Command::new("wsl")` or `vmrun`-equivalent invocations outside `crates/tillandsias-vm-layer/src/wsl.rs` and `crates/tillandsias-vm-layer/src/vz.rs`.

The reasons mirror the podman layer:

- **Stable surface.** Backends change (WSL minor versions, VZ updates). Callers should not care.
- **One choke point for env passthrough.** Env scrub rules are centralized; nothing leaks.
- **One choke point for exit-code propagation.** Backend-specific quirks (WSL eats some signals) are normalized.
- **Testability.** A `MockRuntime` impl is trivial; integration tests on Linux can stand in for both WSL and VZ.

## Trait surface

```rust
// crates/tillandsias-vm-layer/src/lib.rs
#[async_trait::async_trait]
pub trait VmRuntime: Send + Sync {
    /// First-run provisioning. Idempotent: repeated calls are no-ops.
    async fn provision(&self, opts: ProvisionOpts) -> Result<(), VmError>;

    /// Start the VM. Returns once the in-VM headless is reachable on vsock.
    async fn start(&self) -> Result<VmHandle, VmError>;

    /// Stop the VM. Honors `drain_timeout` for graceful shutdown of forges
    /// (via vsock → tillandsias-headless), then sends ACPI/poweroff.
    async fn stop(&self, drain_timeout: Duration) -> Result<(), VmError>;

    /// Execute a process inside the VM. Stdout/stderr stream back to caller.
    async fn exec(&self, spec: ExecSpec) -> Result<ExitStatus, VmError>;

    /// Block until the VM's tillandsias-headless answers vsock handshake.
    async fn wait_ready(&self, timeout: Duration) -> Result<(), VmError>;

    /// Backend tag for diagnostics ("wsl" | "vz" | "kvm" | "mock").
    fn backend(&self) -> &'static str;
}

pub struct ExecSpec {
    pub program: String,           // e.g. "podman"
    pub args: Vec<String>,         // e.g. ["exec", "-it", "tillandsias-foo-forge", "bash"]
    pub stdin: Stdio,              // Inherit | Piped | Null
    pub stdout: Stdio,
    pub stderr: Stdio,
    pub envs: Vec<(String, String)>, // explicit allow-list (see below)
    pub working_dir: Option<String>,
    pub tty: bool,                 // request PTY allocation in the VM
}
```

## Backend 1 — WSL (`wsl --exec`)

The Windows backend wraps `wsl.exe --distribution tillandsias --exec <program> <args>`. Notable behaviors:

```rust
// crates/tillandsias-vm-layer/src/wsl.rs (sketch)
async fn exec(&self, spec: ExecSpec) -> Result<ExitStatus, VmError> {
    let mut cmd = Command::new("wsl.exe");
    cmd.arg("--distribution").arg("tillandsias");
    if let Some(dir) = &spec.working_dir {
        cmd.arg("--cd").arg(dir);
    }
    cmd.arg("--user").arg("forge");
    if spec.tty {
        // PTY allocation is opt-in via the --shell-type variant; bare --exec
        // is non-interactive.
        cmd.arg("--shell-type").arg("login");
    } else {
        cmd.arg("--exec").arg(&spec.program);
        for a in &spec.args { cmd.arg(a); }
    }
    cmd.env_clear();
    for (k, v) in &spec.envs { cmd.env(k, v); }
    cmd.stdin(spec.stdin).stdout(spec.stdout).stderr(spec.stderr);

    let status = cmd.status().await?;
    Ok(status.into())
}
```

### WSL exit-code gotchas

- **Signals are swallowed.** A program killed by SIGTERM inside the VM does not propagate `128+15` back to `wsl.exe`. The host sees exit code `1` or `0` depending on whether the program installed a signal handler. **The idiomatic layer documents this as known-lossy** and exposes a separate `exec_with_exit_signal` variant that wraps the command with `sh -c 'cmd; echo $? > /tmp/exit'` and polls the file — used only when the caller specifically needs signal-vs-exit fidelity (rare).
- **Path translation.** `wsl.exe` resolves `--cd` against the WSL fs root, but a Windows-style path leaks if you pass `C:\Users\<user>\...`. The layer rejects backslash paths in `working_dir`.
- **PTY:** `wsl.exe --shell-type login` allocates a PTY; `--exec` does not. The trait method `tty: bool` picks the right form.

### WSL stdio piping

`wsl.exe` inherits stdio by default. The Rust `tokio::process::Command` plumbing works as expected. Two quirks:

- **Stderr can interleave with stdout** during early boot if the distro is starting; the layer waits for `wait_ready` before issuing any `exec`.
- **UTF-8 BOMs** sometimes appear on stdout when output is piped through `wsl.exe`. The layer strips a leading `\xEF\xBB\xBF` on the first read.

## Backend 2 — VZ (in-VM agent over vsock)

VZ has no direct "exec a process in the guest" call. Instead, the in-VM `tillandsias-headless` runs an **exec dispatcher** over vsock, and the macOS host's `VzRuntime::exec` opens a fresh vsock connection per call.

```rust
// crates/tillandsias-vm-layer/src/vz.rs (sketch)
async fn exec(&self, spec: ExecSpec) -> Result<ExitStatus, VmError> {
    let stream = self.vsock.connect_port(EXEC_PORT).await?;       // EXEC_PORT = 42421
    let req = ExecRequest {
        program: spec.program,
        args: spec.args,
        envs: spec.envs,
        working_dir: spec.working_dir,
        tty: spec.tty,
    };
    write_envelope(&mut stream, &Control::Exec(req)).await?;

    loop {
        match read_envelope(&mut stream).await? {
            Control::ExecStdout(bytes) => /* forward to caller */,
            Control::ExecStderr(bytes) => /* forward to caller */,
            Control::ExecExit { code, signal } => return Ok(ExitStatus { code, signal }),
            other => return Err(VmError::Protocol(other)),
        }
    }
}
```

The in-VM agent runs the actual `Command::new(program).args(args).envs(envs).spawn()` and pipes output back over the same vsock connection. PTY allocation is performed on the guest side via `nix::pty::openpty` when `tty == true`.

### Why a dispatcher rather than vsock-per-exec from raw fork

VZ does not let the host fork into the guest; even with `Hypervisor.framework`, host processes are host processes. A guest-side dispatcher is the standard pattern. We co-locate it in `tillandsias-headless` so we have exactly one in-VM binary to maintain.

## Env passthrough — explicit allow-list

**Never** pass `cmd.envs(std::env::vars())`. The allow-list is hardcoded:

```rust
const PASSTHROUGH_ENVS: &[&str] = &[
    "PATH",
    "HOME",
    "LANG",
    "LC_ALL",
    "TERM",
    "TILLANDSIAS_PROJECT",
    "TILLANDSIAS_PROJECT_HOST_MOUNT",
    "TILLANDSIAS_DEBUG",
    // Per-mode entrypoints add their own (e.g. GIT_AUTHOR_NAME) via ExecSpec.envs.
];
```

The rationale matches the security flags in `podman-idiomatic-patterns.md`: ambient env is a credential leak vector. The host shell builds `ExecSpec.envs` deterministically; anything not on the list is explicitly added by the caller or absent.

This also blocks the host's `http_proxy`/`https_proxy` from leaking into the VM. The in-VM proxy env is set by the forge entrypoint, not inherited.

## Mapping callers (typical usage)

```rust
// Bring up a forge container inside the VM.
runtime.exec(ExecSpec {
    program: "podman".into(),
    args: vec![
        "run".into(), "--rm".into(), "-it".into(),
        "--name".into(), format!("tillandsias-{}-forge", project),
        // ... cap-drop, security-opt, etc. via the existing podman layer
        "tillandsias-forge:v0.2.260523.0".into(),
        "/usr/local/bin/entrypoint-forge-claude.sh".into(),
    ],
    envs: vec![("TILLANDSIAS_PROJECT".into(), project.into())],
    tty: true,
    ..Default::default()
}).await?;
```

The caller does not know whether the runtime is `WslRuntime` or `VzRuntime`. The podman invocation is identical — the layer underneath handles transport.

## Terminal attach (interactive)

The tray's "Attach Here" path:

```
host tray
  └─ VmRuntime::exec(ExecSpec {
        program: "podman", args: ["exec", "-it",
                                  "tillandsias-<project>-forge", "bash"],
        tty: true,
     })
       ├─ Windows: wsl.exe --distribution tillandsias --user forge \
       │           --shell-type login podman exec -it ... bash
       │             (PTY allocated by wsl.exe; tray's parent terminal
       │              becomes the user-facing window)
       └─ macOS:   vsock to in-VM dispatcher → openpty → exec podman
                   → host stitches /dev/ttysX of Terminal.app/iTerm2 to
                     the vsock stream via a small relay
```

This is the "Terminal attach" decision (#10 in the host-shell plan). No SSH; the path is `vm-exec → podman exec -it`.

## Failure mode → error variant

```rust
pub enum VmError {
    NotProvisioned,        // start() called before provision()
    StartTimeout,          // wait_ready exceeded
    Transport(io::Error),  // vsock / wsl.exe pipe error
    BackendUnavailable,    // wsl.exe missing; VZ entitlement absent
    ExecFailed { code: i32, stderr_tail: String },
    Protocol(Control),     // unexpected envelope from the dispatcher
}
```

`BackendUnavailable` is the early-init signal that the host doesn't support the chosen backend — surface to the user as the menu line `🥀 Tillandsias requires WSL2 (Windows) or macOS 13+`.

## What this layer is NOT

- **Not a shell.** The trait doesn't take a `command_line: String`. Callers pass `program + args` explicitly. No `bash -c`.
- **Not a podman wrapper.** Podman calls go through `tillandsias-podman::PodmanClient`, which itself emits `ExecSpec` values into the VM runtime. The two layers stack; they do not merge.
- **Not transparent.** `exec` is **not** drop-in for `Command`. It always crosses the VM boundary, even on Linux where the runtime is degenerate. Callers should plan for the hop.

## Testing strategy

A `MockRuntime` impl records `ExecSpec` values into a `Vec`, returns canned `ExitStatus`. Integration tests on Linux substitute it for `WslRuntime` / `VzRuntime`. The CI lanes (`.github/workflows/build-windows.yml`, `build-macos.yml`) run a litmus test that performs a single `exec("/bin/true")` end-to-end on the real backend; failure of that litmus blocks the release.

## Common pitfalls

- **Forgetting `--user forge`** on the WSL backend. Default user is root, which breaks rootless podman inside the VM.
- **Passing `--exec` with `tty: true`** — `--exec` is non-interactive; use `--shell-type login`.
- **Passing `envs: vec![]` and assuming PATH is inherited** — `env_clear()` runs first. Always include `PATH` if the program isn't an absolute path.
- **Ignoring the vsock handshake on VZ exec** — every `exec` call must wait for the dispatcher's `ExecReady` envelope before piping stdin.
- **Mixing the layer with raw `wsl.exe`** — once any module in the codebase shells out directly, the audit guarantee is gone. Add a clippy/justfile lint that forbids `Command::new("wsl")` outside `crates/tillandsias-vm-layer/`.

## See also

- `runtime/podman-idiomatic-patterns.md` — the prior-art discipline this cheatsheet mirrors
- `runtime/vsock-transport.md` — the transport `VzRuntime` rides on
- `runtime/wsl2-provisioning.md` — provisioning that must complete before `start()`
- `runtime/vz-framework-provisioning.md` — sibling on macOS
- `openspec/specs/vm-idiomatic-layer/spec.md` — normative contract
- `openspec/specs/host-shell-architecture/spec.md` — shared host-shell contract
