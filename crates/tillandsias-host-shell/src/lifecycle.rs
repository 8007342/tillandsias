//! VM lifecycle orchestration for the host-side trays.
//!
//! Sits above `tillandsias-vm-layer` and adds the tray-facing policy:
//! start the VM on tray launch, stop it on tray exit, drain forges before
//! stopping the VM, surface a single condensed status line.
//!
//! The drain contract (from
//! `vm-provisioning-lifecycle.shutdown.graceful-drain@v1`) is:
//! 1. Emit `VmShutdownRequest { drain_timeout_ms: 10_000 }` over the
//!    control wire. The in-VM headless `podman stop --time=10` each forge.
//! 2. Wait up to 30s total for the VM to report stopped.
//! 3. If the 30s wall is breached, force-stop via `VmRuntime::stop`.
//!
//! @trace spec:host-shell-architecture, spec:vm-provisioning-lifecycle

#![allow(dead_code)]

use std::sync::Arc;
use std::time::{Duration, Instant};

use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
use tillandsias_control_wire::transport::Transport;
use tillandsias_vm_layer::VmRuntime;

use crate::vsock_client::{connect_with_handshake, DEFAULT_HANDSHAKE_TIMEOUT};

/// Default per-forge graceful drain budget passed to the in-VM headless.
pub const DEFAULT_FORGE_DRAIN_TIMEOUT_MS: u32 = 10_000;
/// Total wall-clock budget for the VM to report stopped before the host
/// shell escalates to a hard stop.
pub const HARD_STOP_DEADLINE: Duration = Duration::from_secs(30);
/// Budget the host gives `VmRuntime::wait_ready` after `start`.
pub const READY_DEADLINE: Duration = Duration::from_secs(60);

/// Coarse-grained lifecycle phases the tray menu can render via a single
/// status line. Mirrors `tillandsias_control_wire::VmPhase` but lives in
/// the host shell so non-vsock callers don't need the control-wire dep.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LifecyclePhase {
    Idle,
    Provisioning,
    Starting,
    Ready,
    Draining,
    Stopping,
    Failed,
}

/// Wraps a `VmRuntime` and exposes start/stop/drain operations the native
/// trays call from button handlers.
///
/// `transport` carries the wire used to send `VmShutdownRequest` during
/// drain. The host shell sets it from the VM's vsock CID + the standard
/// control port; the Linux dev loop wires a Unix-socket fake for tests.
pub struct VmLifecycle {
    runtime: Arc<dyn VmRuntime>,
    transport: Transport,
    phase: LifecyclePhase,
}

impl VmLifecycle {
    pub fn new(runtime: Arc<dyn VmRuntime>, transport: Transport) -> Self {
        Self {
            runtime,
            transport,
            phase: LifecyclePhase::Idle,
        }
    }

    pub fn phase(&self) -> LifecyclePhase {
        self.phase
    }

    pub fn transport(&self) -> &Transport {
        &self.transport
    }

    /// Boot the VM. Sequence:
    /// 1. `VmRuntime::start` to wake the guest.
    /// 2. `VmRuntime::wait_ready` (60s budget) until the in-VM headless
    ///    reports the vsock listener is bound.
    /// 3. Phase transitions: Idle → Starting → Ready (or Failed).
    pub async fn start(&mut self) -> Result<(), String> {
        self.phase = LifecyclePhase::Starting;
        if let Err(err) = self.runtime.start().await {
            self.phase = LifecyclePhase::Failed;
            return Err(format!("VmRuntime::start failed: {err}"));
        }
        if let Err(err) = self.runtime.wait_ready(READY_DEADLINE).await {
            self.phase = LifecyclePhase::Failed;
            return Err(format!("VmRuntime::wait_ready failed: {err}"));
        }
        self.phase = LifecyclePhase::Ready;
        Ok(())
    }

    /// Graceful drain followed by VM stop. Drains forges through the
    /// control wire (10s each), then asks the runtime to stop. If the
    /// runtime hasn't reported stopped within 30s wall clock, force-stops.
    ///
    /// @trace spec:vm-provisioning-lifecycle.shutdown.graceful-drain@v1
    pub async fn stop(&mut self) -> Result<(), String> {
        let started = Instant::now();
        self.phase = LifecyclePhase::Draining;
        // Best-effort drain; if the control wire is already dead we move
        // straight to stop.
        let _ = self
            .drain(Duration::from_millis(DEFAULT_FORGE_DRAIN_TIMEOUT_MS as u64))
            .await;
        self.phase = LifecyclePhase::Stopping;
        let remaining = HARD_STOP_DEADLINE.saturating_sub(started.elapsed());
        if remaining.is_zero() {
            // Already past the deadline; force-stop.
            let _ = self.runtime.stop(Duration::from_secs(0)).await;
            self.phase = LifecyclePhase::Idle;
            return Ok(());
        }
        match tokio::time::timeout(remaining, self.runtime.stop(remaining)).await {
            Ok(Ok(())) => {
                self.phase = LifecyclePhase::Idle;
                Ok(())
            }
            Ok(Err(err)) => {
                self.phase = LifecyclePhase::Failed;
                Err(format!("VmRuntime::stop failed: {err}"))
            }
            Err(_) => {
                // 30s wall breached; escalate to a forced stop.
                let _ = self.runtime.stop(Duration::from_secs(0)).await;
                self.phase = LifecyclePhase::Idle;
                Ok(())
            }
        }
    }

    /// Send `VmShutdownRequest` over the control wire so the in-VM headless
    /// SIGTERMs every forge before the host stops the VM. Returns Ok even
    /// if the wire was already dead — the caller will follow up with
    /// `VmRuntime::stop` regardless.
    pub async fn drain(&mut self, drain_timeout: Duration) -> Result<(), String> {
        let mut client =
            match connect_with_handshake(self.transport.clone(), DEFAULT_HANDSHAKE_TIMEOUT).await {
                Ok(c) => c,
                Err(err) => {
                    tracing::warn!(?err, "drain: control wire unreachable, skipping VmShutdownRequest");
                    return Ok(());
                }
            };
        let seq = client.allocate_seq();
        let envelope = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: ControlMessage::VmShutdownRequest {
                seq,
                drain_timeout_ms: drain_timeout.as_millis().min(u32::MAX as u128) as u32,
            },
        };
        // Best-effort: emit the shutdown request, then drop the connection.
        // The in-VM headless will exit after draining; we don't await its
        // reply because the wire dies as soon as it exits.
        match client.request(&envelope).await {
            Ok(_reply) => Ok(()),
            Err(err) => {
                tracing::warn!(?err, "drain: VmShutdownRequest send failed (expected if VM already exited)");
                Ok(())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::ExitStatus;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use tillandsias_vm_layer::ProvisionManifest;

    struct CountingFake {
        started: AtomicBool,
        stopped: AtomicUsize,
        stop_should_fail: bool,
    }

    impl CountingFake {
        fn new() -> Self {
            Self {
                started: AtomicBool::new(false),
                stopped: AtomicUsize::new(0),
                stop_should_fail: false,
            }
        }
    }

    #[async_trait::async_trait]
    impl VmRuntime for CountingFake {
        async fn provision(&self, _m: &ProvisionManifest) -> Result<(), String> {
            Ok(())
        }
        async fn start(&self) -> Result<(), String> {
            self.started.store(true, Ordering::SeqCst);
            Ok(())
        }
        async fn stop(&self, _t: Duration) -> Result<(), String> {
            self.stopped.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
        async fn exec(&self, _argv: &[&str]) -> Result<ExitStatus, String> {
            Err("not used".into())
        }
        async fn wait_ready(&self, _t: Duration) -> Result<(), String> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn start_transitions_idle_to_ready() {
        let fake = Arc::new(CountingFake::new());
        let dir = tempfile::tempdir().unwrap();
        let transport = Transport::Unix(dir.path().join("nope.sock"));
        let mut lc = VmLifecycle::new(fake.clone(), transport);
        assert_eq!(lc.phase(), LifecyclePhase::Idle);
        lc.start().await.expect("start ok");
        assert_eq!(lc.phase(), LifecyclePhase::Ready);
        assert!(fake.started.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn stop_drains_then_calls_runtime_stop_even_when_wire_dead() {
        let fake = Arc::new(CountingFake::new());
        let dir = tempfile::tempdir().unwrap();
        let transport = Transport::Unix(dir.path().join("missing.sock"));
        let mut lc = VmLifecycle::new(fake.clone(), transport);
        // No server bound; drain is a no-op. stop() should still call
        // VmRuntime::stop and end in Idle.
        lc.stop().await.expect("stop ok");
        assert_eq!(lc.phase(), LifecyclePhase::Idle);
        assert!(fake.stopped.load(Ordering::SeqCst) >= 1);
    }
}
