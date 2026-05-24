//! Vsock client for the host trays.
//!
//! Wraps `tillandsias-control-wire` with a vsock transport (Linux dev box,
//! Windows host via Hyper-V vsock, macOS host via Virtualization.framework).
//! Provides a typed RPC surface over the `ControlMessage` enum.
//!
//! @trace spec:host-shell-architecture, spec:vsock-transport

#![allow(dead_code)]
#![allow(unused)]

use tillandsias_control_wire::ControlEnvelope;

/// A connected client for the in-VM headless control wire.
pub struct Client {
    pub cid: u32,
    pub port: u32,
}

impl Client {
    /// Open a fresh connection to `cid:port`. Does not perform the
    /// `Hello`/`HelloAck` handshake — call `handshake()` next.
    pub async fn new(cid: u32, port: u32) -> Result<Self, String> {
        todo!("@spec vsock-transport: tokio-vsock connect with retry/backoff")
    }

    /// Send the `Hello` envelope and validate the `HelloAck` reply.
    pub async fn handshake(&mut self) -> Result<(), String> {
        todo!("@spec vsock-transport: postcard Hello/HelloAck exchange")
    }

    /// Send an envelope and wait for the next inbound envelope. The caller
    /// must correlate by `seq` if interleaved requests are expected.
    pub async fn request(&mut self, _envelope: &ControlEnvelope) -> Result<ControlEnvelope, String> {
        todo!("@spec vsock-transport: framed postcard read/write")
    }
}
