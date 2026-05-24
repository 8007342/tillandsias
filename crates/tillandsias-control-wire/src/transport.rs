//! Transport descriptors for the control wire.
//!
//! The framing format (`4-byte BE length || postcard envelope`) is
//! identical across transports. This module names the two transports we
//! support: the legacy Unix socket (Linux tray ↔ Linux headless on the
//! same host) and vsock (host tray ↔ in-VM headless on Windows + macOS).
//!
//! The actual `connect` / `bind` helpers land with the implementation wave;
//! this design step only fixes the public descriptor enum.
//!
//! @trace spec:vsock-transport, spec:host-shell-architecture

#![allow(dead_code)]
#![allow(unused)]

use std::path::PathBuf;

/// Where to reach the control wire.
#[derive(Debug, Clone)]
pub enum Transport {
    /// Filesystem socket (Linux). Default
    /// `$XDG_RUNTIME_DIR/tillandsias/control.sock`.
    Unix(PathBuf),
    /// virtio-vsock (Windows + macOS host trays). `cid` identifies the
    /// guest VM; `port` is conventionally `42420`.
    Vsock { cid: u32, port: u32 },
}
