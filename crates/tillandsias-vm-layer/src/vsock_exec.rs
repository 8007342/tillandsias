//! Self-contained control-wire client for **non-interactive** guest command
//! execution — the wire half of `VmRuntime::exec` on macOS (and any future
//! vsock-backed backend).
//!
//! Why self-contained: the richer PTY session machinery (`PtyRouter`,
//! `connect_pty_bridge`, `pump_io`) lives in `tillandsias-host-shell`, which
//! **depends on** `tillandsias-vm-layer` — so this crate cannot use it without
//! a dependency cycle. Instead this module speaks the control wire directly
//! using only `tillandsias-control-wire` (envelope encode/decode + the 4-byte
//! length framing), mirroring the handshake `tillandsias-macos-tray`'s
//! `pty_vsock_bridge` performs, but for a one-shot run-to-completion command
//! rather than an interactive attach.
//!
//! Reuses the existing `PtyOpen` / `PtyData` / `PtyClose` protocol (no new wire
//! message): open a session running `argv`, drain `PtyData{ToHost}` until the
//! guest sends `PtyClose`, and return the exit status plus the (PTY-multiplexed)
//! output. Non-interactive: no stdin is forwarded.
//!
//! @trace spec:vm-idiomatic-layer, spec:vsock-transport,
//!        openspec/changes/control-wire-pty-attach/proposal.md,
//!        plan/issues/optimization-macos-vz-idiomatic-exec-layer-2026-06-21.md

use tillandsias_control_wire::{
    ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, PtyDirection, PtyExit, WIRE_VERSION,
    decode, encode,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Outcome of a non-interactive guest exec.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecOutput {
    /// Guest child exit (code, or signal if killed) — mirrors `waitpid`.
    pub exit: PtyExit,
    /// Multiplexed stdout+stderr bytes (a PTY merges the two streams).
    pub stdout: Vec<u8>,
}

/// Write one length-prefixed `ControlEnvelope` frame.
async fn write_envelope<W: AsyncWrite + Unpin>(
    w: &mut W,
    env: &ControlEnvelope,
) -> Result<(), String> {
    let bytes = encode(env).map_err(|e| format!("vsock_exec: encode: {e}"))?;
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(format!(
            "vsock_exec: frame too large ({} > {MAX_MESSAGE_BYTES})",
            bytes.len()
        ));
    }
    w.write_all(&(bytes.len() as u32).to_be_bytes())
        .await
        .map_err(|e| format!("vsock_exec: write len: {e}"))?;
    w.write_all(&bytes)
        .await
        .map_err(|e| format!("vsock_exec: write body: {e}"))?;
    w.flush()
        .await
        .map_err(|e| format!("vsock_exec: flush: {e}"))?;
    Ok(())
}

/// Read one length-prefixed `ControlEnvelope` frame.
async fn read_envelope<R: AsyncRead + Unpin>(r: &mut R) -> Result<ControlEnvelope, String> {
    let mut len_buf = [0u8; 4];
    r.read_exact(&mut len_buf)
        .await
        .map_err(|e| format!("vsock_exec: read len: {e}"))?;
    let n = u32::from_be_bytes(len_buf) as usize;
    if n > MAX_MESSAGE_BYTES {
        return Err(format!(
            "vsock_exec: inbound frame too large ({n} > {MAX_MESSAGE_BYTES})"
        ));
    }
    let mut buf = vec![0u8; n];
    r.read_exact(&mut buf)
        .await
        .map_err(|e| format!("vsock_exec: read body: {e}"))?;
    decode(&buf).map_err(|e| format!("vsock_exec: decode: {e}"))
}

/// Run `argv` to completion in the guest over an already-connected control-wire
/// `stream`, collecting multiplexed output and the exit status.
///
/// Protocol: `Hello`/`HelloAck` handshake (seq 1), then `PtyOpen` (seq 2,
/// session 1) with `argv`, then drain inbound frames — accumulating
/// `PtyData{ToHost}` for the session — until `PtyClose` for the session yields
/// the exit. Unrelated frames (other sessions, status replies, host-direction
/// echoes) are ignored. Generic over the stream so it is unit-testable with an
/// in-memory `tokio::io::duplex` peer (no real VM).
pub async fn exec_over_stream<S>(mut stream: S, argv: &[&str]) -> Result<ExecOutput, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    if argv.is_empty() {
        return Err("vsock_exec: empty argv".to_string());
    }

    // 1) Hello / HelloAck (seq 1).
    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::Hello {
                from: "tillandsias-vm-layer::vsock_exec".to_string(),
                capabilities: vec!["pty.attach@v1".to_string()],
            },
        },
    )
    .await?;
    let ack = read_envelope(&mut stream).await?;
    match ack.body {
        ControlMessage::HelloAck { wire_version, .. } => {
            if wire_version != WIRE_VERSION {
                return Err(format!(
                    "vsock_exec: wire_version mismatch (peer {wire_version}, self {WIRE_VERSION})"
                ));
            }
        }
        other => {
            return Err(format!(
                "vsock_exec: expected HelloAck, got {}",
                other.kind()
            ));
        }
    }

    // 2) PtyOpen (seq 2, session 1). env REPLACES the guest environment; a
    // login shell or absolute argv[0] is the caller's responsibility (the guest
    // pty handler env_clears). TERM=dumb keeps non-interactive output clean.
    let session_id: u32 = 1;
    let argv_owned: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 2,
            body: ControlMessage::PtyOpen {
                session_id,
                rows: 24,
                cols: 80,
                argv: argv_owned,
                env: vec![("TERM".to_string(), "dumb".to_string())],
                cwd: None,
            },
        },
    )
    .await?;

    // 3) Drain until PtyClose for our session.
    let mut stdout = Vec::new();
    loop {
        let env = read_envelope(&mut stream).await?;
        match env.body {
            ControlMessage::PtyData {
                session_id: sid,
                direction: PtyDirection::ToHost,
                bytes,
            } if sid == session_id => stdout.extend_from_slice(&bytes),
            ControlMessage::PtyClose {
                session_id: sid,
                exit,
            } if sid == session_id => return Ok(ExecOutput { exit, stdout }),
            _ => { /* unrelated frame — ignore */ }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Drive `exec_over_stream` against an in-memory fake guest that completes
    /// the handshake, streams output, and closes with exit code 0 — proving the
    /// non-interactive exec protocol end to end without a real VM.
    #[tokio::test]
    async fn exec_over_stream_collects_output_and_exit() {
        let (client, mut guest) = tokio::io::duplex(8192);

        let guest_task = tokio::spawn(async move {
            // Expect Hello, reply HelloAck.
            let hello = read_envelope(&mut guest).await.unwrap();
            assert!(matches!(hello.body, ControlMessage::Hello { .. }));
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 1,
                    body: ControlMessage::HelloAck {
                        wire_version: WIRE_VERSION,
                        server_caps: vec![],
                    },
                },
            )
            .await
            .unwrap();

            // Expect PtyOpen carrying our argv.
            let open = read_envelope(&mut guest).await.unwrap();
            match open.body {
                ControlMessage::PtyOpen {
                    argv, session_id, ..
                } => {
                    assert_eq!(argv, vec!["/bin/echo".to_string(), "HELLO".to_string()]);
                    assert_eq!(session_id, 1);
                }
                other => panic!("expected PtyOpen, got {}", other.kind()),
            }

            // Stream output, then close with exit 0.
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 3,
                    body: ControlMessage::PtyData {
                        session_id: 1,
                        direction: PtyDirection::ToHost,
                        bytes: b"HELLO\n".to_vec(),
                    },
                },
            )
            .await
            .unwrap();
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 4,
                    body: ControlMessage::PtyClose {
                        session_id: 1,
                        exit: PtyExit {
                            code: 0,
                            signal: None,
                        },
                    },
                },
            )
            .await
            .unwrap();
        });

        let out = exec_over_stream(client, &["/bin/echo", "HELLO"])
            .await
            .expect("exec_over_stream should succeed");
        assert_eq!(
            out.exit,
            PtyExit {
                code: 0,
                signal: None
            }
        );
        assert_eq!(out.stdout, b"HELLO\n");
        guest_task.await.unwrap();
    }

    /// A non-zero guest exit is propagated faithfully.
    #[tokio::test]
    async fn exec_over_stream_propagates_nonzero_exit() {
        let (client, mut guest) = tokio::io::duplex(8192);
        let guest_task = tokio::spawn(async move {
            let _ = read_envelope(&mut guest).await.unwrap();
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 1,
                    body: ControlMessage::HelloAck {
                        wire_version: WIRE_VERSION,
                        server_caps: vec![],
                    },
                },
            )
            .await
            .unwrap();
            let _ = read_envelope(&mut guest).await.unwrap();
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 3,
                    body: ControlMessage::PtyClose {
                        session_id: 1,
                        exit: PtyExit {
                            code: 17,
                            signal: None,
                        },
                    },
                },
            )
            .await
            .unwrap();
        });
        let out = exec_over_stream(client, &["/bin/false"]).await.unwrap();
        assert_eq!(out.exit.code, 17);
        assert!(out.stdout.is_empty());
        guest_task.await.unwrap();
    }

    /// An empty argv is rejected before any I/O.
    #[tokio::test]
    async fn exec_over_stream_rejects_empty_argv() {
        let (client, _guest) = tokio::io::duplex(64);
        let err = exec_over_stream(client, &[]).await.unwrap_err();
        assert!(err.contains("empty argv"), "got: {err}");
    }
}
