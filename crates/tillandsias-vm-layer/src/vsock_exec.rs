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
//! message): open a session running `argv`, optionally deliver a fixed `input`
//! to the child's PTY (stdin + `/dev/tty`) via `PtyData{ToGuest}`, drain
//! `PtyData{ToHost}` until the guest sends `PtyClose`, and return the exit
//! status plus the (PTY-multiplexed) output. This is one-shot
//! run-to-completion (with optional up-front input) — not a live bidirectional
//! interactive attach.
//!
//! @trace spec:vm-idiomatic-layer, spec:vsock-transport,
//!        openspec/changes/control-wire-pty-attach/proposal.md,
//!        plan/issues/optimization-macos-vz-idiomatic-exec-layer-2026-06-21.md

use tillandsias_control_wire::{
    ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, MAX_PTY_FRAME_BYTES, PtyDirection, PtyExit,
    WIRE_VERSION, decode, encode,
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
/// `stream`, collecting multiplexed output and the exit status. No stdin is
/// forwarded — see [`exec_over_stream_with_input`] for the variant that does.
pub async fn exec_over_stream<S>(stream: S, argv: &[&str]) -> Result<ExecOutput, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    exec_over_stream_with_input(stream, argv, &[]).await
}

/// Like [`exec_over_stream`] but first delivers `input` to the guest child's
/// PTY (its stdin **and** `/dev/tty`) before draining output.
///
/// This is the keystone for near-interactive flows that read a single value
/// from the controlling terminal — e.g. `tillandsias-headless --github-login`'s
/// `read -rs TOKEN < /dev/tty`: the host supplies the secret as `input` (with a
/// trailing newline) and it arrives on the guest `/dev/tty` exactly as if typed,
/// so the token never appears in `argv` / the process list. ssh-over-vsock is
/// not required.
///
/// Protocol: `Hello`/`HelloAck` (seq 1), `PtyOpen` (seq 2, session 1), then
/// `input` as one or more `PtyData{ToGuest}` frames (seq 3…, chunked at
/// `MAX_PTY_FRAME_BYTES`), then drain `PtyData{ToHost}` until `PtyClose`.
/// Generic over the stream so it is unit-testable with an in-memory
/// `tokio::io::duplex` peer (no real VM).
pub async fn exec_over_stream_with_input<S>(
    mut stream: S,
    argv: &[&str],
    input: &[u8],
) -> Result<ExecOutput, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    if argv.is_empty() {
        return Err("vsock_exec: empty argv".to_string());
    }
    let session_id: u32 = 1;
    let mut seq: u64 = 1;

    // 1) Hello / HelloAck (seq 1).
    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
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

    // 2) PtyOpen (seq 2). env REPLACES the guest environment; a login shell or
    // absolute argv[0] is the caller's responsibility (the guest pty handler
    // env_clears, then seeds a default PATH). TERM=dumb keeps output clean.
    seq += 1;
    let argv_owned: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
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

    // 3) Deliver stdin/PTY input (seq 3…), chunked. Sent as ToGuest so it lands
    // on the child's stdin and /dev/tty.
    for chunk in input.chunks(MAX_PTY_FRAME_BYTES) {
        seq += 1;
        write_envelope(
            &mut stream,
            &ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq,
                body: ControlMessage::PtyData {
                    session_id,
                    direction: PtyDirection::ToGuest,
                    bytes: chunk.to_vec(),
                },
            },
        )
        .await?;
    }

    // 4) Drain until PtyClose for our session. 5-minute idle timeout per frame.
    const IDLE_TIMEOUT_SECS: u64 = 300;
    let mut stdout = Vec::new();
    loop {
        let env = match tokio::time::timeout(
            std::time::Duration::from_secs(IDLE_TIMEOUT_SECS),
            read_envelope(&mut stream),
        )
        .await
        {
            Ok(Ok(e)) => e,
            Ok(Err(e)) => return Err(e),
            Err(_) => {
                return Err(format!(
                    "vsock_exec: no data from guest for {IDLE_TIMEOUT_SECS}s — connection stale"
                ));
            }
        };
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

/// Like [`exec_over_stream_with_input`] but emits each PTY output chunk to
/// `on_output` immediately rather than accumulating the full buffer. Use this
/// for long-running guest commands (e.g. `--opencode`) where real-time output
/// matters; the caller receives `ExecOutput { exit, stdout: vec![] }` on
/// success (`stdout` is always empty — the caller owns the output via callback).
pub async fn exec_over_stream_with_input_streaming<S, F>(
    mut stream: S,
    argv: &[&str],
    input: &[u8],
    on_output: F,
) -> Result<ExecOutput, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
    F: Fn(&[u8]),
{
    if argv.is_empty() {
        return Err("vsock_exec: empty argv".to_string());
    }
    let session_id: u32 = 1;
    let mut seq: u64 = 1;

    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: ControlMessage::Hello {
                from: "tillandsias-vm-layer::vsock_exec::streaming".to_string(),
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

    seq += 1;
    let argv_owned: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
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

    for chunk in input.chunks(MAX_PTY_FRAME_BYTES) {
        seq += 1;
        write_envelope(
            &mut stream,
            &ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq,
                body: ControlMessage::PtyData {
                    session_id,
                    direction: PtyDirection::ToGuest,
                    bytes: chunk.to_vec(),
                },
            },
        )
        .await?;
    }

    // 5-minute idle timeout per frame: if the guest sends nothing for this
    // long the vsock connection is considered stale (e.g. WiFi drop without
    // RST, or a hung guest process). Long-running commands like `--init` or
    // forge sessions regularly go quiet for minutes, so the window is generous.
    const IDLE_TIMEOUT_SECS: u64 = 300;

    loop {
        let env = match tokio::time::timeout(
            std::time::Duration::from_secs(IDLE_TIMEOUT_SECS),
            read_envelope(&mut stream),
        )
        .await
        {
            Ok(Ok(e)) => e,
            Ok(Err(e)) => return Err(e),
            Err(_) => {
                return Err(format!(
                    "vsock_exec: no data from guest for {IDLE_TIMEOUT_SECS}s — connection stale"
                ));
            }
        };
        match env.body {
            ControlMessage::PtyData {
                session_id: sid,
                direction: PtyDirection::ToHost,
                bytes,
            } if sid == session_id => on_output(&bytes),
            ControlMessage::PtyClose {
                session_id: sid,
                exit,
            } if sid == session_id => {
                return Ok(ExecOutput {
                    exit,
                    stdout: vec![],
                });
            }
            _ => {}
        }
    }
}

/// One scripted prompt→response step for [`exec_over_stream_expect`].
#[derive(Clone)]
pub struct Expect {
    /// Substring to wait for in the guest's output before responding.
    pub needle: Vec<u8>,
    /// Bytes to send to the guest (as `PtyData{ToGuest}`) once `needle` is seen.
    pub response: Vec<u8>,
    /// Human label for logs; `response` is never logged (may be secret).
    pub label: String,
}

/// One prompt step whose response is produced only after the guest emits the
/// matching prompt. This lets host wrappers defer credential prompts until the
/// guest has completed its own infrastructure preflight.
pub struct DynamicExpect {
    /// Substring to wait for in the guest's output before responding.
    pub needle: Vec<u8>,
    /// Produce bytes to send to the guest once `needle` is seen.
    pub response: Box<dyn FnMut() -> Result<Vec<u8>, String> + Send>,
    /// Human label for logs; `response` is never logged (may be secret).
    pub label: String,
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|p| p + needle.len())
}

/// Run `argv` and drive a sequential, expect-style conversation: wait for each
/// `expects[i].needle` to appear in the guest output, then send
/// `expects[i].response` (as PTY input). Steps are consumed in order. Used to
/// drive the released guest `tillandsias-headless --github-login` (which prompts
/// for git name, git email, then the token) without changing the guest binary.
///
/// The token is sent ONLY after its prompt, so the guest's earlier `read_line`s
/// don't buffer-steal it before the container's `read -rs TOKEN < /dev/tty`.
///
/// `on_event(&str)` receives non-secret progress labels (e.g. "matched: git
/// author name") so the caller can show progress without leaking responses.
pub async fn exec_over_stream_expect<S>(
    stream: S,
    argv: &[&str],
    expects: Vec<Expect>,
    on_event: impl FnMut(&str),
) -> Result<ExecOutput, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let expects = expects
        .into_iter()
        .map(|expect| {
            let mut response = Some(expect.response);
            DynamicExpect {
                needle: expect.needle,
                label: expect.label,
                response: Box::new(move || {
                    response
                        .take()
                        .ok_or_else(|| "static expect response consumed more than once".to_string())
                }),
            }
        })
        .collect();
    exec_over_stream_expect_dynamic(stream, argv, expects, on_event).await
}

/// Like [`exec_over_stream_expect`], but each response is produced lazily after
/// its prompt is observed.
pub async fn exec_over_stream_expect_dynamic<S>(
    mut stream: S,
    argv: &[&str],
    expects: Vec<DynamicExpect>,
    mut on_event: impl FnMut(&str),
) -> Result<ExecOutput, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    if argv.is_empty() {
        return Err("vsock_exec: empty argv".to_string());
    }
    let session_id: u32 = 1;
    let mut seq: u64 = 1;

    // Handshake (seq 1) + PtyOpen (seq 2) — same as exec_over_stream_with_input.
    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: ControlMessage::Hello {
                from: "tillandsias-vm-layer::vsock_exec".to_string(),
                capabilities: vec!["pty.attach@v1".to_string()],
            },
        },
    )
    .await?;
    match read_envelope(&mut stream).await?.body {
        ControlMessage::HelloAck { wire_version, .. } if wire_version == WIRE_VERSION => {}
        ControlMessage::HelloAck { wire_version, .. } => {
            return Err(format!(
                "vsock_exec: wire_version mismatch (peer {wire_version}, self {WIRE_VERSION})"
            ));
        }
        other => {
            return Err(format!(
                "vsock_exec: expected HelloAck, got {}",
                other.kind()
            ));
        }
    }
    seq += 1;
    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: ControlMessage::PtyOpen {
                session_id,
                rows: 24,
                cols: 80,
                argv: argv.iter().map(|s| s.to_string()).collect(),
                env: vec![("TERM".to_string(), "dumb".to_string())],
                cwd: None,
            },
        },
    )
    .await?;

    let mut stdout = Vec::new();
    let mut search_start = 0usize;
    let mut pending = expects.into_iter();
    let mut current = pending.next();
    const IDLE_TIMEOUT_SECS: u64 = 300;

    loop {
        let env = match tokio::time::timeout(
            std::time::Duration::from_secs(IDLE_TIMEOUT_SECS),
            read_envelope(&mut stream),
        )
        .await
        {
            Ok(Ok(e)) => e,
            Ok(Err(e)) => return Err(e),
            Err(_) => {
                return Err(format!(
                    "vsock_exec: no data from guest for {IDLE_TIMEOUT_SECS}s — connection stale"
                ));
            }
        };
        match env.body {
            ControlMessage::PtyData {
                session_id: sid,
                direction: PtyDirection::ToHost,
                bytes,
            } if sid == session_id => {
                stdout.extend_from_slice(&bytes);
                // Satisfy as many sequential expects as the new output allows.
                while current.is_some() {
                    let end = {
                        let exp = current.as_ref().expect("current expect exists");
                        find_subslice(&stdout[search_start..], &exp.needle)
                    };
                    if let Some(end) = end {
                        let exp = current.as_mut().expect("current expect exists");
                        on_event(&format!("matched: {}", exp.label));
                        search_start += end;
                        seq += 1;
                        let response = (exp.response)()?;
                        write_envelope(
                            &mut stream,
                            &ControlEnvelope {
                                wire_version: WIRE_VERSION,
                                seq,
                                body: ControlMessage::PtyData {
                                    session_id,
                                    direction: PtyDirection::ToGuest,
                                    bytes: response,
                                },
                            },
                        )
                        .await?;
                        current = pending.next();
                    } else {
                        break;
                    }
                }
            }
            ControlMessage::PtyClose {
                session_id: sid,
                exit,
            } if sid == session_id => return Ok(ExecOutput { exit, stdout }),
            _ => {}
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

    /// `exec_over_stream_with_input` delivers stdin/PTY input to the guest — the
    /// keystone for the github-login token paste (`read -rs TOKEN < /dev/tty`).
    /// The fake guest reads the ToGuest frame and echoes it back, mirroring a
    /// `read X; echo "GOT:$X"` round-trip.
    #[tokio::test]
    async fn exec_over_stream_with_input_delivers_stdin() {
        let (client, mut guest) = tokio::io::duplex(8192);
        let guest_task = tokio::spawn(async move {
            // Hello -> HelloAck.
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
            // PtyOpen.
            let _ = read_envelope(&mut guest).await.unwrap();
            // Expect the input delivered as a ToGuest PtyData frame.
            let input = read_envelope(&mut guest).await.unwrap();
            let got = match input.body {
                ControlMessage::PtyData {
                    direction: PtyDirection::ToGuest,
                    bytes,
                    session_id,
                } => {
                    assert_eq!(session_id, 1);
                    bytes
                }
                other => panic!("expected ToGuest PtyData, got {}", other.kind()),
            };
            assert_eq!(got, b"s3cr3t-token\n");
            // Echo it back (minus newline) as the "command output", then close.
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 3,
                    body: ControlMessage::PtyData {
                        session_id: 1,
                        direction: PtyDirection::ToHost,
                        bytes: b"GOT:s3cr3t-token".to_vec(),
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

        let out = exec_over_stream_with_input(
            client,
            &["/bin/bash", "-lc", "read -r X; echo GOT:$X"],
            b"s3cr3t-token\n",
        )
        .await
        .expect("exec_over_stream_with_input should succeed");
        assert_eq!(out.exit.code, 0);
        assert_eq!(out.stdout, b"GOT:s3cr3t-token");
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

    /// `exec_over_stream_expect` drives a sequential prompt→response script —
    /// the mechanism that drives the released guest `--github-login` (git name,
    /// git email, then token). The fake guest emits three prompts in order and
    /// must receive the three scripted responses, token last.
    #[tokio::test]
    async fn exec_over_stream_expect_drives_sequential_prompts() {
        let (client, mut guest) = tokio::io::duplex(8192);
        let guest_task = tokio::spawn(async move {
            let _ = read_envelope(&mut guest).await.unwrap(); // Hello
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
            let _ = read_envelope(&mut guest).await.unwrap(); // PtyOpen

            // Helper: emit a ToHost prompt, then expect the next ToGuest response.
            async fn step(
                guest: &mut tokio::io::DuplexStream,
                seq: u64,
                prompt: &[u8],
                expected_response: &[u8],
            ) {
                write_envelope(
                    guest,
                    &ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq,
                        body: ControlMessage::PtyData {
                            session_id: 1,
                            direction: PtyDirection::ToHost,
                            bytes: prompt.to_vec(),
                        },
                    },
                )
                .await
                .unwrap();
                let resp = read_envelope(guest).await.unwrap();
                match resp.body {
                    ControlMessage::PtyData {
                        direction: PtyDirection::ToGuest,
                        bytes,
                        ..
                    } => assert_eq!(bytes, expected_response),
                    other => panic!("expected ToGuest response, got {}", other.kind()),
                }
            }

            step(&mut guest, 3, b"Git author name [x]: ", b"Test User\n").await;
            step(&mut guest, 4, b"Git author email: ", b"t@example.com\n").await;
            step(
                &mut guest,
                5,
                b"Paste your GitHub authentication token (input hidden): ",
                b"ghp_FAKE\n",
            )
            .await;

            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 6,
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

        let expects = vec![
            Expect {
                needle: b"author name".to_vec(),
                response: b"Test User\n".to_vec(),
                label: "git author name".to_string(),
            },
            Expect {
                needle: b"author email".to_vec(),
                response: b"t@example.com\n".to_vec(),
                label: "git author email".to_string(),
            },
            Expect {
                needle: b"authentication token".to_vec(),
                response: b"ghp_FAKE\n".to_vec(),
                label: "github token".to_string(),
            },
        ];
        let out = exec_over_stream_expect(
            client,
            &["tillandsias-headless", "--github-login"],
            expects,
            |_| {},
        )
        .await
        .expect("expect-driven exec should succeed");
        assert_eq!(out.exit.code, 0);
        guest_task.await.unwrap();
    }

    /// Dynamic expects produce the response only after the matching guest
    /// prompt arrives. Host credential wrappers use this to avoid asking the
    /// operator for secrets while the guest is still doing infrastructure
    /// preflight.
    #[tokio::test]
    async fn exec_over_stream_expect_dynamic_defers_response_until_prompt() {
        let (client, mut guest) = tokio::io::duplex(8192);
        let callback_called = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let guest_observer = callback_called.clone();

        let guest_task = tokio::spawn(async move {
            let _ = read_envelope(&mut guest).await.unwrap(); // Hello
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
            let _ = read_envelope(&mut guest).await.unwrap(); // PtyOpen
            assert!(!guest_observer.load(std::sync::atomic::Ordering::SeqCst));

            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 3,
                    body: ControlMessage::PtyData {
                        session_id: 1,
                        direction: PtyDirection::ToHost,
                        bytes: b"preflight ok\n".to_vec(),
                    },
                },
            )
            .await
            .unwrap();
            tokio::task::yield_now().await;
            assert!(!guest_observer.load(std::sync::atomic::Ordering::SeqCst));

            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 4,
                    body: ControlMessage::PtyData {
                        session_id: 1,
                        direction: PtyDirection::ToHost,
                        bytes: b"Git author name: ".to_vec(),
                    },
                },
            )
            .await
            .unwrap();
            let resp = read_envelope(&mut guest).await.unwrap();
            match resp.body {
                ControlMessage::PtyData {
                    direction: PtyDirection::ToGuest,
                    bytes,
                    ..
                } => assert_eq!(bytes, b"Late User\n"),
                other => panic!("expected ToGuest response, got {}", other.kind()),
            }

            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 5,
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

        let callback_flag = callback_called.clone();
        let expects = vec![DynamicExpect {
            needle: b"author name".to_vec(),
            label: "git author name".to_string(),
            response: Box::new(move || {
                callback_flag.store(true, std::sync::atomic::Ordering::SeqCst);
                Ok(b"Late User\n".to_vec())
            }),
        }];
        let out = exec_over_stream_expect_dynamic(
            client,
            &["tillandsias-headless", "--github-login"],
            expects,
            |_| {},
        )
        .await
        .expect("dynamic expect-driven exec should succeed");
        assert_eq!(out.exit.code, 0);
        assert!(callback_called.load(std::sync::atomic::Ordering::SeqCst));
        guest_task.await.unwrap();
    }
}
