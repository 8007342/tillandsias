//! VM lifecycle orchestration for the host-side trays.
//!
//! Sits above `tillandsias-vm-layer` and adds the tray-facing policy:
//! start the VM on tray launch, stop it on tray exit, drain forges before
//! stopping the VM, surface a single condensed status line.
//!
//! @trace spec:host-shell-architecture, spec:vm-provisioning-lifecycle

#![allow(dead_code)]
#![allow(unused)]

use std::sync::Arc;
use std::time::Duration;

use tillandsias_vm_layer::VmRuntime;

/// Coarse-grained lifecycle phases the tray menu can render via a single
/// status line.
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

/// Wraps a `VmRuntime` and exposes start/stop/drain operations that the
/// native trays call from button handlers.
pub struct VmLifecycle {
    runtime: Arc<dyn VmRuntime>,
    phase: LifecyclePhase,
}

impl VmLifecycle {
    pub fn new(runtime: Arc<dyn VmRuntime>) -> Self {
        Self {
            runtime,
            phase: LifecyclePhase::Idle,
        }
    }

    pub fn phase(&self) -> LifecyclePhase {
        self.phase
    }

    pub async fn start(&mut self) -> Result<(), String> {
        todo!("@spec host-shell-architecture: VmRuntime.start + wait_ready + phase transitions")
    }

    pub async fn stop(&mut self) -> Result<(), String> {
        todo!("@spec host-shell-architecture: drain forges, VmRuntime.stop with 30s fallback")
    }

    /// Send `VmShutdownRequest` over the control wire so the in-VM headless
    /// stops every forge before the host shuts the VM down.
    pub async fn drain(&mut self, _drain_timeout: Duration) -> Result<(), String> {
        todo!("@spec host-shell-architecture: VmShutdownRequest then await reply")
    }
}
