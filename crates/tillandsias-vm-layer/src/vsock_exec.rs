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
    CAP_PTY_DATA_SESSION, CAP_PTY_HEARTBEAT_V1, CAP_PTY_HEARTBEAT_V2, CAP_PTY_STDIN_EOF,
    ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, MAX_PTY_FRAME_BYTES, PtyDirection, PtyExit,
    PtyInputState, VmPhase, WIRE_VERSION, decode, encode, transport::control_frame_codec,
};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

/// The control-wire session stream, framed once per session.
///
/// ORDER 795-5itp. One `LengthDelimitedCodec` — `control_frame_codec()`, which
/// pins `MAX_MESSAGE_BYTES` on both encode and decode — instead of this file's
/// own copy of the `u32-BE` prefix arithmetic.
type ExecFramed<S> = tokio_util::codec::Framed<S, tokio_util::codec::LengthDelimitedCodec>;

/// Wrap a connected control-wire stream in the shared codec. Call this ONCE
/// per session; see the note on [`read_envelope`] for why per-call framing
/// loses pipelined bytes.
fn frame_stream<S: AsyncRead + AsyncWrite + Unpin>(stream: S) -> ExecFramed<S> {
    tokio_util::codec::Framed::new(stream, control_frame_codec())
}

const IDLE_TIMEOUT_SECS: u64 = 300;
const MIN_EXEC_IDLE_TIMEOUT_SECS: u64 = 60;
const EXEC_IDLE_TIMEOUT_ENV: &str = "TILLANDSIAS_VSOCK_EXEC_IDLE_TIMEOUT_SECS";

fn exec_idle_timeout_from(value: Option<&str>) -> Result<std::time::Duration, String> {
    let Some(value) = value else {
        return Ok(std::time::Duration::from_secs(IDLE_TIMEOUT_SECS));
    };
    let seconds = value.parse::<u64>().map_err(|_| {
        format!("{EXEC_IDLE_TIMEOUT_ENV} must be an integer number of seconds, got {value:?}")
    })?;
    if seconds < MIN_EXEC_IDLE_TIMEOUT_SECS {
        return Err(format!(
            "{EXEC_IDLE_TIMEOUT_ENV} must be at least {MIN_EXEC_IDLE_TIMEOUT_SECS} seconds, got {seconds}"
        ));
    }
    Ok(std::time::Duration::from_secs(seconds))
}

fn exec_idle_timeout() -> Result<std::time::Duration, String> {
    exec_idle_timeout_from(std::env::var(EXEC_IDLE_TIMEOUT_ENV).ok().as_deref())
}

/// Wall-clock ceiling on one expect-driven exec (689-y2my, remaining item (a)).
///
/// This is NOT the progress deadline the packet originally asked for. That idea
/// was refuted on 2026-08-12: the heartbeat is load-bearing (order 332), a
/// legitimate first-run `--github-login` was measured at ~1290s of silence
/// before it prompted, and a deadlock is indistinguishable from a slow-but-
/// healthy command *by timing alone*. Any bound tight enough to catch a wedge
/// promptly is tight enough to kill working work.
///
/// So this ceiling is deliberately far above every legitimate duration anyone
/// has measured — four hours against a 21-minute worst case, a ~11x margin. It
/// exists for the one property a purely observational fix cannot provide:
/// **termination**. An unattended cycle that wedges at 02:00 currently holds
/// the session until a human notices. With the heartbeat reports shipped in the
/// safe half, that wedge is already legible within 30 seconds to anyone
/// watching; this is what happens when nobody is.
///
/// Justified against order 332 by the margin, not by an argument that no output
/// means no progress: a command that genuinely runs for four hours under an
/// exec expect is outside anything this transport has ever been used for, and
/// the ceiling is configurable for the host that finds one.
const EXEC_WALL_CLOCK_CEILING_SECS: u64 = 14_400;
const MIN_EXEC_WALL_CLOCK_CEILING_SECS: u64 = 300;
const EXEC_WALL_CLOCK_CEILING_ENV: &str = "TILLANDSIAS_VSOCK_EXEC_WALL_CLOCK_CEILING_SECS";

fn exec_wall_clock_ceiling_from(
    value: Option<&str>,
) -> Result<Option<std::time::Duration>, String> {
    let Some(value) = value else {
        return Ok(Some(std::time::Duration::from_secs(
            EXEC_WALL_CLOCK_CEILING_SECS,
        )));
    };
    // An explicit `0` disables the ceiling. A host with a genuinely unbounded
    // exec should be able to say so out loud rather than setting a number so
    // large it reads as a typo.
    if value == "0" {
        return Ok(None);
    }
    let seconds = value.parse::<u64>().map_err(|_| {
        format!("{EXEC_WALL_CLOCK_CEILING_ENV} must be an integer number of seconds, got {value:?}")
    })?;
    if seconds < MIN_EXEC_WALL_CLOCK_CEILING_SECS {
        return Err(format!(
            "{EXEC_WALL_CLOCK_CEILING_ENV} must be at least {MIN_EXEC_WALL_CLOCK_CEILING_SECS} seconds (or 0 to disable), got {seconds}"
        ));
    }
    Ok(Some(std::time::Duration::from_secs(seconds)))
}

fn exec_wall_clock_ceiling() -> Result<Option<std::time::Duration>, String> {
    exec_wall_clock_ceiling_from(std::env::var(EXEC_WALL_CLOCK_CEILING_ENV).ok().as_deref())
}

/// The message a ceiling breach produces. Separate from the send site so the
/// test asserts the operator-visible text, not a timing coincidence.
///
/// It names what the exec was waiting for and how much guest output arrived,
/// because "it timed out" without those two facts is what made the 70-minute
/// wedge unreadable in the first place.
fn wall_clock_ceiling_error(
    ceiling: std::time::Duration,
    pending_label: Option<&str>,
    bytes_seen: usize,
) -> String {
    let waiting_on = match pending_label {
        Some(label) => format!("still waiting for {label}"),
        None => "no expect pending".to_string(),
    };
    format!(
        "vsock_exec: exec exceeded the {}s wall-clock ceiling — {waiting_on}, {bytes_seen} bytes of guest output seen. \
         The wire was alive (the guest was heartbeating), so this is a wedged or blocked guest rather than a dead connection. \
         Raise or disable with {EXEC_WALL_CLOCK_CEILING_ENV} (0 disables).",
        ceiling.as_secs()
    )
}

/// How much of an arriving output frame is shown in a progress preview, and
/// how often previews may be emitted (order 690-eug2).
///
/// The packet's headline defect: the driver accumulated everything and emitted
/// it only at `PtyClose`, with `on_event` firing solely on a needle match, so
/// during a long or hung run the operator saw NOTHING. The heartbeat reports
/// and the deadlock detection added since tell you THAT the guest is quiet or
/// stuck; a preview tells you WHAT it is saying, which is the difference
/// between "still waiting" and "oh, it is asking for a passphrase".
const EXEC_PREVIEW_BYTES: usize = 200;
const EXEC_PREVIEW_MIN_GAP: std::time::Duration = std::time::Duration::from_secs(1);

/// Render an arriving frame as a single-line, bounded, escaped preview.
///
/// Escaping is not cosmetic. Guest output is raw PTY bytes: control sequences,
/// carriage returns, and cursor movement. Passing those through to a caller's
/// log would let a guest rewrite lines it does not own — the log is the
/// diagnostic surface for a wedged guest, so it must not be forgeable by the
/// thing being diagnosed.
fn preview_of(bytes: &[u8]) -> String {
    let shown = &bytes[..bytes.len().min(EXEC_PREVIEW_BYTES)];
    let mut out = String::with_capacity(shown.len() + 16);
    for &b in shown {
        match b {
            b'\n' => out.push_str("\\n"),
            b'\r' => out.push_str("\\r"),
            b'\t' => out.push_str("\\t"),
            0x20..=0x7e => out.push(b as char),
            _ => out.push_str(&format!("\\x{b:02x}")),
        }
    }
    if bytes.len() > shown.len() {
        out.push_str(&format!(" …(+{} bytes)", bytes.len() - shown.len()));
    }
    out
}

/// How many bytes of guest transcript the expect driver retains (order
/// 690-eug2). 8 MiB: far above any real prompt-driven exchange, low enough that
/// a runaway guest cannot exhaust host memory.
const EXEC_TRANSCRIPT_CAP_BYTES: usize = 8 * 1024 * 1024;
const EXEC_TRANSCRIPT_CAP_ENV: &str = "TILLANDSIAS_VSOCK_EXEC_TRANSCRIPT_CAP_BYTES";

/// The cap, overridable; `0` disables trimming entirely.
fn exec_transcript_cap() -> usize {
    std::env::var(EXEC_TRANSCRIPT_CAP_ENV)
        .ok()
        .and_then(|v| v.trim().parse::<usize>().ok())
        .unwrap_or(EXEC_TRANSCRIPT_CAP_BYTES)
}

/// Drop transcript bytes that can no longer participate in a match, returning
/// how many were dropped and adjusting the two cursors.
///
/// WHY THIS IS SAFE, and it rests on the cursor invariant the rescan fix
/// established: no match can START before `scan_from - (needle.len()-1)`,
/// because everything before that has already been examined for the CURRENT
/// needle. And `search_start` only ever moves forward, so nothing before it is
/// ever searched again. Bytes before the later of those two points are
/// therefore dead for matching, by construction rather than by estimate.
///
/// The dropped bytes are the OLDEST guest output, and the caller loses them
/// from `ExecOutput.stdout`. That is the honest trade for a bound, and it is
/// why the elision is REPORTED through on_event rather than papered over: a
/// silently short transcript would send someone hunting for output the guest
/// definitely produced. Nothing is injected into `stdout` itself — a marker in
/// the byte stream would corrupt exactly what callers parse.
fn trim_transcript(
    stdout: &mut Vec<u8>,
    search_start: &mut usize,
    scan_from: &mut usize,
    current_needle_len: Option<usize>,
    cap: usize,
) -> usize {
    if cap == 0 || stdout.len() <= cap {
        return 0;
    }
    let dead_for_current = match current_needle_len {
        // An expect is pending: keep the overlap window the scan needs.
        Some(len) => scan_from.saturating_sub(len.saturating_sub(1)),
        // No expect pending: matching is over, everything is dead.
        None => stdout.len(),
    };
    let drop_to = (*search_start).max(dead_for_current).min(stdout.len());
    if drop_to == 0 {
        // Cannot trim without losing match context — a guest that floods
        // before the first prompt. Reported by the caller rather than silently
        // exceeding the cap.
        return 0;
    }
    stdout.drain(..drop_to);
    // SATURATING, not `-=`. drop_to is the MAX of search_start and the dead
    // window, so it can exceed search_start whenever the cursor has moved past
    // it — and then the search origin is simply the new start of the buffer.
    // Writing `*search_start -= drop_to` underflowed on the first run.
    *search_start = search_start.saturating_sub(drop_to);
    *scan_from = scan_from.saturating_sub(drop_to);
    drop_to
}

/// Escape hatch for the deadlock report, mirroring the ceiling's own env.
///
/// Set to `0` to disable. Present because a new terminal condition on a path
/// this critical should be switchable off by an operator who hits a case
/// nobody anticipated, without editing code — the same reasoning that gave the
/// wall-clock ceiling one.
const EXEC_DEADLOCK_REPORT_ENV: &str = "TILLANDSIAS_VSOCK_EXEC_DEADLOCK_REPORT";

fn deadlock_report_enabled() -> bool {
    !matches!(
        std::env::var(EXEC_DEADLOCK_REPORT_ENV).ok().as_deref(),
        Some("0")
    )
}

/// The message a guest-reported deadlock produces (order 723-g4bk).
///
/// Deliberately distinguishable from BOTH of its neighbours, because the whole
/// point of the ladder is that these three are different failures and were
/// previously indistinguishable:
///
///   * the idle timeout says the wire went silent — a dead connection;
///   * the wall-clock ceiling says time ran out while the wire was alive — a
///     bound, not a diagnosis;
///   * this says the GUEST TOLD US it is waiting for input. Not an inference
///     from elapsed time, which is exactly what 689-y2my's refuted progress
///     deadline tried and could not do.
fn guest_deadlock_error(pending_label: &str, bytes_seen: usize, elapsed_secs: u64) -> String {
    format!(
        "vsock_exec: DEADLOCK — the guest reports it is blocked reading its terminal, \
         while this exec is still waiting for {pending_label} ({bytes_seen} bytes of guest output seen, \
         {elapsed_secs}s elapsed). The guest is waiting for input this exec is not going to send, \
         and this exec is waiting for a prompt the guest is not going to print. \
         The wire is alive and the guest is healthy — neither a stale connection nor a timeout. \
         Disable this report with {EXEC_DEADLOCK_REPORT_ENV}=0."
    )
}

/// Outcome of a non-interactive guest exec.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecOutput {
    /// Guest child exit (code, or signal if killed) — mirrors `waitpid`.
    pub exit: PtyExit,
    /// Multiplexed stdout+stderr bytes (a PTY merges the two streams).
    pub stdout: Vec<u8>,
}

/// Write one length-prefixed `ControlEnvelope` frame.
async fn write_envelope<S: AsyncRead + AsyncWrite + Unpin>(
    w: &mut ExecFramed<S>,
    env: &ControlEnvelope,
) -> Result<(), String> {
    let bytes = encode(env).map_err(|e| format!("vsock_exec: encode: {e}"))?;
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(format!(
            "vsock_exec: frame too large ({} > {MAX_MESSAGE_BYTES})",
            bytes.len()
        ));
    }
    // ORDER 690-eug2: bound the WRITE side too.
    //
    // Every bound this seam has grown was on reads — the idle deadline, the
    // wall-clock ceiling, the setup deadlines added last cycle. A peer that
    // accepts the connection and then stops DRAINING blocks the writer
    // indefinitely, and no read-side deadline can observe that: the host is not
    // waiting for data, it is waiting for buffer space. The symptom is a host
    // parked inside a send with nothing on any timer.
    //
    // Reuses the idle timeout rather than inventing a knob. A write that cannot
    // make progress for as long as a read may go silent is stuck by the same
    // standard, and one env var is easier to reason about than two.
    let deadline = exec_idle_timeout()?;
    // ORDER 795-5itp: write through the UNDERLYING stream, not the codec Sink.
    //
    // The staged bounds above are load-bearing (690-eug2): `SinkExt::send`
    // encodes and writes in one call, so a stall inside it can only be
    // reported as "the write blocked", losing the length-vs-body distinction
    // that `a_peer_that_stops_draining_does_not_park_the_writer` asserts.
    // Reaching past the codec is sound here precisely BECAUSE the Sink half
    // is never used: its write buffer is always empty, so nothing can
    // interleave with these bytes. The READ half still goes through the
    // codec, which is where the raw frame-length decode actually was.
    let raw = w.get_mut();
    write_all_bounded(
        raw,
        &(bytes.len() as u32).to_be_bytes(),
        deadline,
        "the frame length",
    )
    .await?;
    write_all_bounded(raw, &bytes, deadline, "the frame body").await?;
    match tokio::time::timeout(deadline, raw.flush()).await {
        Ok(r) => r.map_err(|e| format!("vsock_exec: flush: {e}"))?,
        Err(_) => {
            return Err(format!(
                "vsock_exec: the peer stopped draining — flush blocked for {}s. \
                 The connection is open and the peer is not reading; this is back-pressure, \
                 not a stale or refused connection (override with {EXEC_IDLE_TIMEOUT_ENV})",
                deadline.as_secs()
            ));
        }
    }
    Ok(())
}

/// `write_all` under a deadline, naming which part of the frame stalled.
///
/// Split out so the two writes share one message shape and the stage is not
/// guessed from a stack trace.
async fn write_all_bounded<W: AsyncWrite + Unpin>(
    w: &mut W,
    buf: &[u8],
    deadline: std::time::Duration,
    stage: &str,
) -> Result<(), String> {
    match tokio::time::timeout(deadline, w.write_all(buf)).await {
        Ok(r) => r.map_err(|e| format!("vsock_exec: write {stage}: {e}")),
        Err(_) => Err(format!(
            "vsock_exec: the peer stopped draining — writing {stage} blocked for {}s. \
             The connection is open and the peer is not reading; this is back-pressure, \
             not a stale or refused connection (override with {EXEC_IDLE_TIMEOUT_ENV})",
            deadline.as_secs()
        )),
    }
}

/// Read one length-prefixed `ControlEnvelope` frame off the session codec.
///
/// ORDER 795-5itp slice 6, the last Linux production raw frame-length decode.
/// The `u32::from_be_bytes` + bounds-check + `read_exact(body)` that used to
/// live here is now `control_frame_codec()`, so the maximum frame length is
/// the shared `MAX_MESSAGE_BYTES` by construction instead of by a copy of the
/// comparison.
///
/// WHY THE CODEC IS SESSION-SCOPED AND NOT PER CALL. A `Framed` reads into its
/// OWN buffer and routinely reads past the frame it returns. Constructing one
/// per call and dropping it would discard whatever of the next frame came in
/// the same TCP/vsock segment — on this seam that is a lost `PtyData` or a
/// lost `PtyClose`, i.e. a hang, not an error. So every entry point wraps its
/// stream ONCE (`frame_stream`) and threads `&mut ExecFramed` through the
/// whole session, which is why this takes the framed stream rather than a
/// reader.
async fn read_envelope<S: AsyncRead + AsyncWrite + Unpin>(
    r: &mut ExecFramed<S>,
) -> Result<ControlEnvelope, String> {
    let frame = match futures_util::StreamExt::next(r).await {
        Some(Ok(bytes)) => bytes,
        Some(Err(e)) if e.kind() == std::io::ErrorKind::InvalidData => {
            // The codec refuses an oversize length prefix before allocating.
            // Keep the wording the hand-rolled bound used: this is the same
            // refusal, and callers/logs should not have to learn a new one.
            return Err(format!(
                "vsock_exec: inbound frame too large (> {MAX_MESSAGE_BYTES}): {e}"
            ));
        }
        Some(Err(e)) => return Err(format!("vsock_exec: read frame: {e}")),
        None => {
            return Err("vsock_exec: read frame: peer closed the connection".to_string());
        }
    };
    decode(&frame).map_err(|e| format!("vsock_exec: decode: {e}"))
}

/// Read a SETUP-stage envelope under the same deadline the data path uses, and
/// name the stage on expiry (order 690-eug2).
///
/// The handshake reads were bare `read_envelope`, i.e. untimed. A guest that
/// ACCEPTS the vsock connection and then never answers `Hello` parked the host
/// forever — no idle deadline, no wall-clock ceiling, no heartbeat, because
/// none of those exist until the session is established. Every bound this seam
/// has grown was on the data path, and the connection could never reach it.
///
/// The stage is in the message because "no data from guest" is true of five
/// different moments here and useless in all of them; "guest never answered
/// Hello" and "guest never replied to PtyOpen" are different faults with
/// different causes.
async fn read_setup_envelope<S: AsyncRead + AsyncWrite + Unpin>(
    r: &mut ExecFramed<S>,
    timeout: std::time::Duration,
    stage: &str,
) -> Result<ControlEnvelope, String> {
    match tokio::time::timeout(timeout, read_envelope(r)).await {
        Ok(result) => result,
        Err(_) => Err(format!(
            "vsock_exec: guest accepted the connection but never completed {stage} within {}s — \
             the peer is reachable and silent, which is neither a refused connection nor a stale \
             session (override with {EXEC_IDLE_TIMEOUT_ENV})",
            timeout.as_secs()
        )),
    }
}

async fn read_exec_envelope<S: AsyncRead + AsyncWrite + Unpin>(
    r: &mut ExecFramed<S>,
    idle_timeout: std::time::Duration,
) -> Result<ControlEnvelope, String> {
    match tokio::time::timeout(idle_timeout, read_envelope(r)).await {
        Ok(result) => result,
        Err(_) => {
            let elapsed = if idle_timeout.as_secs() > 0 {
                format!("{}s", idle_timeout.as_secs())
            } else {
                format!("{}ms", idle_timeout.as_millis())
            };
            Err(format!(
                "vsock_exec: no data from guest for {elapsed} — connection stale (override with {EXEC_IDLE_TIMEOUT_ENV})"
            ))
        }
    }
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

/// Choose the open frame for an EXEC session (order 926-bin4).
///
/// A data session puts the child's fd 0 on a pipe, so binary stdin survives:
/// the line discipline never sees it. When the peer cannot do that we fall back
/// to `PtyOpen` and SAY SO if the payload is at risk, because the alternative is
/// the silent truncation this packet was filed for — measured as 0x15 discarding
/// everything buffered before it while the caller was told rc=0.
///
/// The warning is conditioned on the payload, not on the capability alone: a
/// text-only stdin is unaffected by the line discipline and warning about it
/// every time would train readers to ignore the message that matters.
fn exec_open_frame(
    peer_supports_data_session: bool,
    input: &[u8],
    session_id: u32,
    argv: Vec<String>,
    env: Vec<(String, String)>,
    cwd: Option<String>,
) -> ControlMessage {
    // Both exec entry points opened 24x80; it is a nominal size for a session
    // whose output is piped, not rendered, so it lives here rather than being
    // threaded through as two arguments that never vary.
    const EXEC_ROWS: u16 = 24;
    const EXEC_COLS: u16 = 80;
    let (rows, cols) = (EXEC_ROWS, EXEC_COLS);
    if peer_supports_data_session {
        return ControlMessage::PtyOpenData {
            session_id,
            rows,
            cols,
            argv,
            env,
            cwd,
        };
    }
    if input.iter().any(|b| LINE_DISCIPLINE_SPECIALS.contains(b)) {
        eprintln!(
            "[vsock_exec] WARNING: this guest does not advertise {CAP_PTY_DATA_SESSION}, so stdin \
             crosses a terminal line discipline that INTERPRETS control bytes. This payload \
             contains at least one of them, so it will be altered in transit: 0x04/0x11 lose a \
             byte, 0x15/0x1a discard everything buffered before them, 0x7f deletes the preceding \
             byte, 0x03 kills the child, and 0x13 wedges the session. Measured, order 926-bin4. \
             Update the staged guest binary."
        );
    }
    ControlMessage::PtyOpen {
        session_id,
        rows,
        cols,
        argv,
        env,
        cwd,
    }
}

/// The bytes a canonical-mode line discipline does NOT deliver verbatim, as
/// MEASURED on a live guest (926-bin4) rather than taken from a header. 0x08 is
/// deliberately absent: it arrived intact, because VERASE is DEL here, and
/// warning about bytes that are fine would dull the warning about bytes that
/// are not.
const LINE_DISCIPLINE_SPECIALS: &[u8] = &[0x03, 0x04, 0x11, 0x13, 0x15, 0x1a, 0x7f];

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
    stream: S,
    argv: &[&str],
    input: &[u8],
) -> Result<ExecOutput, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    if argv.is_empty() {
        return Err("vsock_exec: empty argv".to_string());
    }
    // ORDER 795-5itp: frame the session ONCE. See read_envelope for why a
    // per-call Framed would drop pipelined bytes on this control path.
    let mut stream = frame_stream(stream);
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
                capabilities: vec![
                    "pty.attach@v1".to_string(),
                    CAP_PTY_HEARTBEAT_V1.to_string(),
                    CAP_PTY_HEARTBEAT_V2.to_string(),
                ],
                build_version: None,
            },
        },
    )
    .await?;
    let ack = read_setup_envelope(&mut stream, exec_idle_timeout()?, "the Hello handshake").await?;
    // Order 925-eofi: read the EOF capability off the ack. Feature-detect on
    // the advertised token, NEVER on the wire version — a fleet routinely runs
    // a host newer than the guest staged beside it, and a version comparison
    // would send a frame an older guest cannot decode (which kills the session
    // rather than degrading).
    let (peer_supports_stdin_eof, peer_supports_data_session) = match ack.body {
        ControlMessage::HelloAck {
            wire_version,
            ref server_caps,
            ..
        } => {
            if wire_version != WIRE_VERSION {
                return Err(format!(
                    "vsock_exec: wire_version mismatch (peer {wire_version}, self {WIRE_VERSION})"
                ));
            }
            (
                server_caps.iter().any(|c| c == CAP_PTY_STDIN_EOF),
                server_caps.iter().any(|c| c == CAP_PTY_DATA_SESSION),
            )
        }
        other => {
            return Err(format!(
                "vsock_exec: expected HelloAck, got {}",
                other.kind()
            ));
        }
    };

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
            body: exec_open_frame(
                peer_supports_data_session,
                input,
                session_id,
                argv_owned,
                vec![("TERM".to_string(), "dumb".to_string())],
                None,
            ),
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

    // 3b) Tell the guest the input is finished — but ONLY if it said it can be
    // told (order 925-eofi). The guest turns this into whatever its terminal
    // state actually requires; the host deliberately does not send the byte
    // itself, for the reasons measured in 924-eof7.
    //
    // WHEN THE PEER CANNOT BE TOLD, SAY SO. Silence here is the whole defect:
    // a child that reads to EOF would block forever on a PTY whose master
    // never closes, and the caller would see a hang with no explanation. A
    // named warning is the minimum; callers whose command genuinely needs EOF
    // should treat this as a refusal rather than proceed hopefully.
    if !input.is_empty() {
        if peer_supports_stdin_eof {
            seq += 1;
            write_envelope(
                &mut stream,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq,
                    body: ControlMessage::PtyStdinEof { session_id },
                },
            )
            .await?;
        } else {
            eprintln!(
                "[vsock_exec] WARNING: this guest does not advertise {CAP_PTY_STDIN_EOF}, so it \
                 cannot be told that stdin is finished. Commands that read to EOF (a bare `cat`, \
                 `gh auth login --with-token`) will HANG here rather than return; byte-exact \
                 readers (`head -c N`) are unaffected. Update the staged guest binary to fix it."
            );
        }
    }

    // 4) Drain until PtyClose for our session. Empty ToHost frames are guest
    // liveness heartbeats and reset the per-frame idle deadline without
    // changing collected output.
    let idle_timeout = exec_idle_timeout()?;
    let mut stdout = Vec::new();
    loop {
        let env = read_exec_envelope(&mut stream, idle_timeout).await?;
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
            // A guest-reported error (e.g. PtyOpen rejected by the exec
            // allowlist) is terminal for the session. Without this arm the
            // drain loop ignored it and hung until the idle timeout —
            // caught live by the order-128 conformance harness 2026-07-14
            // (the streaming variant below always had the arm).
            ControlMessage::Error { message, .. } => {
                return Err(format!("vsock_exec: guest error: {message}"));
            }
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
    stream: S,
    argv: &[&str],
    input: &[u8],
    mut on_output: F,
) -> Result<ExecOutput, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
    F: FnMut(&[u8]),
{
    exec_over_stream_with_input_streaming_timeout(
        stream,
        argv,
        input,
        None,
        &mut on_output,
        exec_idle_timeout()?,
    )
    .await
}

/// Like [`exec_over_stream_with_input_streaming`], but REFUSES to send `argv`
/// unless the guest advertised `required_cap` in `HelloAck.server_caps`.
///
/// 795-zshi: `CAP_EXEC_ARGV_VECTOR`'s own doc says hosts MUST feature-detect on
/// the ack rather than compare wire versions, and every real exec handshake in
/// this module destructured `server_caps` away — so a host that adopted the
/// verbatim-argv arm would send it to an old guest and collect a bare
/// `exec allowlist violation` with nothing naming the cause.
///
/// The refusal is deliberately LOUD and names both the missing capability and
/// what the guest DID advertise. There is no silent fallback to the flattened
/// `/bin/bash -lc <string>` shape: re-flattening a request the caller expressed
/// as a vector is exactly the quoting rewrite this packet exists to delete, and
/// `openspec/specs/vsock-exec-authz` clause 5 records refusal as preferred
/// wherever no flattened form is already maintained for that request.
///
/// @trace spec:vsock-exec-authz, order:795-zshi
pub async fn exec_over_stream_with_input_streaming_requiring<S, F>(
    stream: S,
    argv: &[&str],
    input: &[u8],
    required_cap: &str,
    mut on_output: F,
) -> Result<ExecOutput, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
    F: FnMut(&[u8]),
{
    exec_over_stream_with_input_streaming_timeout(
        stream,
        argv,
        input,
        Some(required_cap),
        &mut on_output,
        exec_idle_timeout()?,
    )
    .await
}

/// The refusal text a capability-gated exec produces when the guest did not
/// advertise the capability the caller's argv shape depends on.
///
/// Pure string logic, unconditionally compiled so its pins run on every host:
/// the message is the whole value of the gate (a bare "allowlist violation"
/// from the guest is what this replaces), so it is asserted, not eyeballed.
///
/// @trace order:795-zshi
pub fn missing_cap_message(required_cap: &str, server_caps: &[String]) -> String {
    let advertised = if server_caps.is_empty() {
        "nothing".to_string()
    } else {
        server_caps.join(", ")
    };
    format!(
        "vsock_exec: the guest does not advertise `{required_cap}`, which this argv shape \
         requires; it advertised: {advertised}. Refusing rather than re-flattening the \
         request into `/bin/bash -lc <string>` — that rewrite loses the caller's word \
         boundaries, which is the defect class 795-zshi exists to delete. Update the guest \
         image (or express the command as a shell string if you meant one)."
    )
}

async fn exec_over_stream_with_input_streaming_timeout<S, F>(
    stream: S,
    argv: &[&str],
    input: &[u8],
    required_cap: Option<&str>,
    on_output: &mut F,
    idle_timeout: std::time::Duration,
) -> Result<ExecOutput, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
    F: FnMut(&[u8]),
{
    if argv.is_empty() {
        return Err("vsock_exec: empty argv".to_string());
    }
    // ORDER 795-5itp: frame the session ONCE. See read_envelope for why a
    // per-call Framed would drop pipelined bytes on this control path.
    let mut stream = frame_stream(stream);
    let session_id: u32 = 1;
    let mut seq: u64 = 1;

    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: ControlMessage::Hello {
                from: "tillandsias-vm-layer::vsock_exec::streaming".to_string(),
                capabilities: vec![
                    "pty.attach@v1".to_string(),
                    CAP_PTY_HEARTBEAT_V1.to_string(),
                    CAP_PTY_HEARTBEAT_V2.to_string(),
                ],
                build_version: None,
            },
        },
    )
    .await?;
    let ack = read_setup_envelope(&mut stream, exec_idle_timeout()?, "the Hello handshake").await?;
    // Order 925-eofi / 926-bin4: same feature-detect as the non-streaming entry
    // point. Both capabilities are read in the SAME window, because both must be
    // known before the open frame is chosen.
    let (peer_supports_stdin_eof, peer_supports_data_session) = match ack.body {
        // `server_caps` is READ here, not destructured away (795-zshi): the
        // capability check has to happen between the ack and the PtyOpen, which
        // is the only window in which the host still knows what the guest can do
        // and has not yet sent a shape the guest may refuse.
        ControlMessage::HelloAck {
            wire_version,
            server_caps,
            ..
        } => {
            if wire_version != WIRE_VERSION {
                return Err(format!(
                    "vsock_exec: wire_version mismatch (peer {wire_version}, self {WIRE_VERSION})"
                ));
            }
            if let Some(cap) = required_cap.filter(|c| !server_caps.iter().any(|s| s == c)) {
                return Err(missing_cap_message(cap, &server_caps));
            }
            (
                server_caps.iter().any(|c| c == CAP_PTY_STDIN_EOF),
                server_caps.iter().any(|c| c == CAP_PTY_DATA_SESSION),
            )
        }
        other => {
            return Err(format!(
                "vsock_exec: expected HelloAck, got {}",
                other.kind()
            ));
        }
    };

    seq += 1;
    let argv_owned: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: exec_open_frame(
                peer_supports_data_session,
                input,
                session_id,
                argv_owned,
                vec![("TERM".to_string(), "dumb".to_string())],
                None,
            ),
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

    // Order 925-eofi. THIS ENTRY POINT NEEDS IT TOO — and that is the whole
    // lesson of the first attempt: the EOF was added only to
    // `exec_over_stream_with_input`, its unit tests scanned that function and
    // passed the gate, and the live run STILL HUNG, because `--exec-guest`
    // comes through HERE. Two entry points, one of them fixed, green tests.
    // `every_input_entry_point_sends_stdin_eof` now enumerates them instead of
    // trusting anyone to remember, and fails on the day a third is added.
    if !input.is_empty() {
        if peer_supports_stdin_eof {
            seq += 1;
            write_envelope(
                &mut stream,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq,
                    body: ControlMessage::PtyStdinEof { session_id },
                },
            )
            .await?;
        } else {
            eprintln!(
                "[vsock_exec] WARNING: this guest does not advertise {CAP_PTY_STDIN_EOF}, so it \
                 cannot be told that stdin is finished. Commands that read to EOF (a bare `cat`, \
                 `gh auth login --with-token`) will HANG here rather than return; byte-exact \
                 readers (`head -c N`) are unaffected. Update the staged guest binary to fix it."
            );
        }
    }

    // 772-qn6j observability: TILLANDSIAS_VSOCK_EXEC_TRACE=1 prints one
    // stderr line per received envelope (kind + payload size). The 58-min
    // wedge survived a 300s PER-ENVELOPE deadline, which proves complete
    // envelopes kept arriving while zero data was delivered — this trace is
    // what distinguishes "heartbeats-only arriving" (guest data path silent)
    // from "data arriving but dropped here" without a guest rebuild.
    let trace = std::env::var("TILLANDSIAS_VSOCK_EXEC_TRACE").is_ok_and(|v| v == "1");
    loop {
        let env = read_exec_envelope(&mut stream, idle_timeout).await?;
        if trace {
            let (kind, size) = match &env.body {
                ControlMessage::PtyData { bytes, .. } => ("PtyData", bytes.len()),
                other => (other.kind(), 0),
            };
            eprintln!("[exec-trace] recv {kind} bytes={size}");
        }
        match env.body {
            ControlMessage::PtyData {
                session_id: sid,
                direction: PtyDirection::ToHost,
                bytes,
            } if sid == session_id && !bytes.is_empty() => on_output(&bytes),
            ControlMessage::PtyClose {
                session_id: sid,
                exit,
            } if sid == session_id => {
                return Ok(ExecOutput {
                    exit,
                    stdout: vec![],
                });
            }
            ControlMessage::Error { message, .. } => {
                return Err(format!("vsock_exec: guest error: {message}"));
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

/// Connect the Hello/HelloAck handshake then query `VmStatusRequest` and return
/// the in-VM `VmPhase`. Consumes the stream; caller opens a fresh connection
/// per probe. Used by `VzRuntime::wait_phase_ready` to poll until Ready.
///
/// @trace plan/issues/osx-next-work-queue-2026-05-25.md#macos-tray/wait-ready-phase-signal
pub async fn probe_vm_phase<S>(stream: S) -> Result<VmPhase, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    // ORDER 795-5itp: frame the session ONCE (see read_envelope).
    let mut stream = frame_stream(stream);
    // Hello / HelloAck (seq 1).
    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::Hello {
                from: "tillandsias-vm-layer::vsock_exec::probe_phase".to_string(),
                capabilities: vec![],
                build_version: None,
            },
        },
    )
    .await?;
    let ack = read_setup_envelope(&mut stream, exec_idle_timeout()?, "the Hello handshake").await?;
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
                "probe_vm_phase: expected HelloAck, got {}",
                other.kind()
            ));
        }
    }
    // VmStatusRequest (seq 2).
    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 2,
            body: ControlMessage::VmStatusRequest { seq: 2 },
        },
    )
    .await?;
    let reply = read_setup_envelope(&mut stream, exec_idle_timeout()?, "the PtyOpen reply").await?;
    match reply.body {
        ControlMessage::VmStatusReply { phase, .. } => Ok(phase),
        ControlMessage::Error { message, .. } => {
            Err(format!("probe_vm_phase: guest error: {message}"))
        }
        other => Err(format!(
            "probe_vm_phase: expected VmStatusReply, got {}",
            other.kind()
        )),
    }
}

/// Capability token a guest advertises when it can answer
/// [`ControlMessage::MetricsSnapshotRequest`] (order 333's handler).
pub const CAP_METRICS_SNAPSHOT: &str = "MetricsSnapshotRequest";

/// Handshake, then fetch the guest metrics snapshot — or report that the
/// guest cannot serve one (778-n9z2).
///
/// `Ok(None)` means the guest handshook fine and did NOT advertise
/// [`CAP_METRICS_SNAPSHOT`]: an older guest, not a failure. That distinction
/// is the whole point — feature detection is by CAPABILITY, never by
/// comparing wire versions, because a version says what a peer IS while a
/// capability says what it can DO, and this fleet routinely runs a host
/// newer than the guest binary staged beside it.
///
/// Additive on purpose: `Client::handshake` in `tillandsias-host-shell`
/// discards `server_caps`, and it is shared_logic with Linux and Windows
/// callers, so widening its return type to reach one macOS field would break
/// two other platforms for no reason. This helper reads the ack itself.
///
/// @trace spec:observability-metrics, spec:vsock-transport
pub async fn fetch_metrics_snapshot<S>(
    stream: S,
) -> Result<Option<tillandsias_control_wire::MetricsSnapshotWire>, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    // ORDER 795-5itp: frame the session ONCE (see read_envelope).
    let mut stream = frame_stream(stream);
    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::Hello {
                from: "tillandsias-vm-layer::vsock_exec::metrics_snapshot".to_string(),
                capabilities: vec![],
                build_version: None,
            },
        },
    )
    .await?;
    let ack = read_setup_envelope(&mut stream, exec_idle_timeout()?, "the Hello handshake").await?;
    let server_caps = match ack.body {
        ControlMessage::HelloAck {
            wire_version,
            server_caps,
            ..
        } => {
            if wire_version != WIRE_VERSION {
                return Err(format!(
                    "metrics_snapshot: wire_version mismatch (peer {wire_version}, self {WIRE_VERSION})"
                ));
            }
            server_caps
        }
        other => {
            return Err(format!(
                "metrics_snapshot: expected HelloAck, got {}",
                other.kind()
            ));
        }
    };
    if !server_caps.iter().any(|c| c == CAP_METRICS_SNAPSHOT) {
        return Ok(None);
    }

    write_envelope(
        &mut stream,
        &ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 2,
            body: ControlMessage::MetricsSnapshotRequest { seq: 2 },
        },
    )
    .await?;
    let reply = read_setup_envelope(
        &mut stream,
        exec_idle_timeout()?,
        "the MetricsSnapshot reply",
    )
    .await?;
    match reply.body {
        // The snapshot travels through untouched — no counter is defaulted,
        // no empty sample is dropped. A `None` counter means "could not be
        // collected" all the way to the JSON (spec:observability-metrics).
        ControlMessage::MetricsSnapshotReply { snapshot, .. } => Ok(Some(snapshot)),
        ControlMessage::Error { message, .. } => {
            Err(format!("metrics_snapshot: guest error: {message}"))
        }
        other => Err(format!(
            "metrics_snapshot: expected MetricsSnapshotReply, got {}",
            other.kind()
        )),
    }
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
    stream: S,
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
    // ORDER 795-5itp: frame the session ONCE. See read_envelope for why a
    // per-call Framed would drop pipelined bytes on this control path.
    let mut stream = frame_stream(stream);
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
                capabilities: vec![
                    "pty.attach@v1".to_string(),
                    CAP_PTY_HEARTBEAT_V1.to_string(),
                    CAP_PTY_HEARTBEAT_V2.to_string(),
                ],
                build_version: None,
            },
        },
    )
    .await?;
    match read_setup_envelope(&mut stream, exec_idle_timeout()?, "the Hello handshake")
        .await?
        .body
    {
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
    // Cursor for the incremental needle scan (order 690-eug2): everything
    // before it has already been examined for the CURRENT needle.
    let mut scan_from = 0usize;
    let mut pending = expects.into_iter();
    let mut current = pending.next();
    let transcript_cap = exec_transcript_cap();
    // Last time an output preview was emitted; None until the first frame.
    let mut last_preview: Option<std::time::Instant> = None;
    let mut elided_bytes = 0usize;
    let idle_timeout = exec_idle_timeout()?;
    // 689-y2my: make the WAIT observable. The deadline deliberately stays as it
    // is — heartbeats extending it is load-bearing (order 332, 4c9da7cc: a
    // silent long-running guest command must not be killed), and the legitimate
    // first-run `--github-login` spends minutes loading a ~580MB image before it
    // prompts at all. What was actually wrong on 2026-08-11 was not the bound
    // but the SILENCE: `on_event` fired only on a needle match, so a host
    // waiting for a prompt the guest would never print produced no output for 70
    // minutes and was indistinguishable from progress. Each heartbeat now says
    // what is being waited for, so the same wedge is legible within 30 seconds.
    let started = std::time::Instant::now();
    // 689-y2my item (a): a generous wall-clock ceiling, so an UNATTENDED wedge
    // terminates. The heartbeat reports above make a wedge legible to someone
    // watching within 30 seconds; this is what happens when nobody is.
    let wall_clock_ceiling = exec_wall_clock_ceiling()?;

    loop {
        // Checking at the top of the loop is sufficient precisely BECAUSE the
        // heartbeat exists: a live guest wakes this loop every 30s, so the
        // ceiling fires within one heartbeat of expiry. A guest that stops
        // heartbeating entirely is the other failure, and the idle deadline
        // below already owns it.
        if let Some(ceiling) = wall_clock_ceiling
            && started.elapsed() >= ceiling
        {
            return Err(wall_clock_ceiling_error(
                ceiling,
                current.as_ref().map(|e| e.label.as_str()),
                stdout.len(),
            ));
        }
        let env = read_exec_envelope(&mut stream, idle_timeout).await?;
        match env.body {
            ControlMessage::PtyData {
                session_id: sid,
                direction: PtyDirection::ToHost,
                bytes,
            } if sid == session_id => {
                if bytes.is_empty() {
                    // A liveness heartbeat, not output. Report the wait; do NOT
                    // treat it as progress and do NOT alter the deadline.
                    if let Some(exp) = current.as_ref() {
                        on_event(&format!(
                            "still waiting for {} — {}s elapsed, {} bytes of guest output so far",
                            exp.label,
                            started.elapsed().as_secs(),
                            stdout.len()
                        ));
                    }
                    continue;
                }
                // Surface output AS IT ARRIVES (order 690-eug2). Rate-limited
                // rather than per-frame: a chatty guest (`yes`, a build log)
                // would otherwise turn the caller's log into a firehose, and an
                // observability feature that has to be switched off to keep the
                // logs usable is not observability.
                //
                // The FIRST frame is always shown, because "the guest has begun
                // talking" is the single most useful early signal and waiting a
                // second to say it defeats the point.
                if !bytes.is_empty() {
                    let now = std::time::Instant::now();
                    let due = last_preview
                        .map(|t: std::time::Instant| now.duration_since(t) >= EXEC_PREVIEW_MIN_GAP)
                        .unwrap_or(true);
                    if due {
                        last_preview = Some(now);
                        on_event(&format!(
                            "guest output ({}s, {} bytes so far): {}",
                            started.elapsed().as_secs(),
                            stdout.len() + bytes.len(),
                            preview_of(&bytes)
                        ));
                    }
                }
                stdout.extend_from_slice(&bytes);
                // Bound the retained transcript (order 690-eug2). Runs BEFORE
                // matching so the cursors this adjusts are the ones the scan
                // below reads.
                if stdout.len() > transcript_cap {
                    let dropped = trim_transcript(
                        &mut stdout,
                        &mut search_start,
                        &mut scan_from,
                        current.as_ref().map(|e| e.needle.len()),
                        transcript_cap,
                    );
                    if dropped > 0 {
                        elided_bytes += dropped;
                        on_event(&format!(
                            "transcript cap reached: elided {dropped} bytes of earlier guest output \
                             ({elided_bytes} total). The retained transcript is the most recent \
                             {} bytes; override with {EXEC_TRANSCRIPT_CAP_ENV} (0 disables).",
                            stdout.len()
                        ));
                    }
                }
                // Satisfy as many sequential expects as the new output allows.
                while current.is_some() {
                    let end = {
                        let exp = current.as_ref().expect("current expect exists");
                        // ORDER 690-eug2: scan from a CURSOR, not from
                        // search_start, so each byte is examined a bounded
                        // number of times instead of once per subsequent frame.
                        // The old form re-searched the entire unmatched
                        // transcript on every inbound frame — O(bytes x frames)
                        // — which is worst exactly when the transcript is
                        // longest and the exchange is already in trouble.
                        //
                        // Backing up by needle.len()-1 is the whole correctness
                        // argument: a needle can straddle the boundary between
                        // the previous frame and this one, so the last
                        // needle_len-1 bytes of what we already scanned must be
                        // re-examined. Off-by-one here silently loses matches
                        // that arrive split across frames, which is a normal
                        // occurrence on a PTY, not an edge case.
                        let overlap = exp.needle.len().saturating_sub(1);
                        let from = scan_from.saturating_sub(overlap).max(search_start);
                        find_subslice(&stdout[from..], &exp.needle)
                            .map(|end| end + from - search_start)
                    };
                    if let Some(end) = end {
                        let exp = current.as_mut().expect("current expect exists");
                        on_event(&format!("matched: {}", exp.label));
                        search_start += end;
                        // A new needle searches the whole remaining transcript,
                        // so the cursor resets with it.
                        scan_from = search_start;
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
                        // No match in the transcript as it stands: everything
                        // up to here has been examined for THIS needle, so the
                        // next frame starts from the end (minus the overlap
                        // computed above).
                        scan_from = stdout.len();
                        break;
                    }
                }
            }
            ControlMessage::PtyClose {
                session_id: sid,
                exit,
            } if sid == session_id => return Ok(ExecOutput { exit, stdout }),
            // Order 689-xpq7. The two sibling drivers in this file have had this
            // arm since 2026-07-14, when the order-128 conformance harness
            // caught the guest's only diagnostic being dropped. The fix landed
            // on two drivers of three and the regression pin covered one, so
            // this one regressed the same way and nothing noticed.
            //
            // What the swallow costs is diagnosability, not liveness: the idle
            // timeout still fires, so the operator waits ~300s and is then told
            // "connection stale" — which is a lie about the failure. The guest
            // said why. This arm is what lets it be heard.
            //
            // The pending expect is named because a rejected exec fails while
            // waiting for a prompt that will never come, and "waiting for X"
            // plus the guest's own words is the difference between a report and
            // a riddle.
            ControlMessage::Error { message, .. } => {
                return Err(match current.as_ref() {
                    Some(expect) => format!(
                        "vsock_exec: guest error while waiting for {}: {message}",
                        expect.label
                    ),
                    None => format!("vsock_exec: guest error: {message}"),
                });
            }
            // Order 723-2yb3: the v2 heartbeat. Same liveness role as the v1
            // empty PtyData above — it is NOT output, it does NOT satisfy an
            // expect, and it does not alter the deadline — but it carries the
            // guest's answer to the question elapsed time cannot answer.
            //
            // REPORTING ONLY, deliberately. Acting on BlockedOnInput (failing
            // the exec fast instead of waiting out the ceiling) is rung 3
            // (723-g4bk). Shipping the observation first means the wedge
            // becomes legible on this cycle without changing any control flow,
            // and rung 3 can be judged on its own.
            ControlMessage::PtyHeartbeat {
                session_id: sid,
                input_state,
            } if sid == session_id => {
                if let Some(exp) = current.as_ref() {
                    let posture = match input_state {
                        PtyInputState::BlockedOnInput => {
                            "guest is BLOCKED READING ITS TERMINAL — it is waiting for input \
                             this exec is not sending"
                        }
                        PtyInputState::NotBlocked => "guest is working",
                        PtyInputState::Unknown => {
                            "guest could not determine its input state on this kernel"
                        }
                    };
                    on_event(&format!(
                        "still waiting for {} — {}s elapsed, {} bytes of guest output so far; {posture}",
                        exp.label,
                        started.elapsed().as_secs(),
                        stdout.len()
                    ));

                    // ORDER 723-g4bk — the rung the other two were built for.
                    //
                    // Both sides are waiting for each other, and both said so:
                    // the guest is blocked reading its terminal, and this exec
                    // is still waiting for a prompt. That is a deadlock the
                    // moment it is observed, not after a bound expires.
                    //
                    // WHY ONE HEARTBEAT IS ENOUGH, and this is the load-bearing
                    // argument: frames are ORDERED on the stream. If the guest
                    // had printed the prompt before blocking, that PtyData
                    // arrived before this heartbeat and the arm above would
                    // already have matched the needle and sent the response, so
                    // `current` would not still be pending. A pending expect
                    // co-occurring with a blocked guest therefore means the
                    // needle genuinely has not been printed — established by
                    // ordering, not by waiting long enough to be confident.
                    //
                    // This is NOT the refuted progress deadline. It never asks
                    // whether quiet means stuck; a slow guest loading a 580MB
                    // image reports NotBlocked and is untouched.
                    if input_state == PtyInputState::BlockedOnInput && deadlock_report_enabled() {
                        return Err(guest_deadlock_error(
                            &exp.label,
                            stdout.len(),
                            started.elapsed().as_secs(),
                        ));
                    }
                }
                continue;
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {

    /// ORDER 926-bin4 — the same ENUMERATION discipline 925-eofi's failure
    /// taught, applied to the open frame. Every exec entry point must choose
    /// its open frame through `exec_open_frame`, never construct `PtyOpen`
    /// inline: an entry point that hardcodes the terminal frame silently keeps
    /// the line-discipline corruption while its neighbours are fixed, and a
    /// per-function assertion would not see it.
    #[test]
    fn every_exec_entry_point_chooses_its_open_frame() {
        let source = include_str!("vsock_exec.rs");
        let code = source.split("#[cfg(test)]").next().expect("code region");
        let mut checked = 0;
        for chunk in code.split("async fn ").skip(1) {
            let name = chunk
                .split('<')
                .next()
                .unwrap_or("")
                .split('(')
                .next()
                .unwrap_or("")
                .trim()
                .to_string();
            // Only the entry points that deliver an `input` payload.
            if !chunk.contains("for chunk in input.chunks(") {
                continue;
            }
            checked += 1;
            assert!(
                chunk.contains("exec_open_frame("),
                "{name} opens its session without exec_open_frame, so it cannot \
                 use a data session and its stdin still crosses the line \
                 discipline (order 926-bin4)"
            );
        }
        assert!(
            checked >= 2,
            "expected at least two input-delivering entry points, found {checked}"
        );
    }

    /// The warning must fire on a payload that WILL be altered and stay quiet on
    /// one that will not — a warning that cries wolf on every text payload
    /// trains readers to ignore the case that matters.
    #[test]
    fn the_specials_list_is_what_was_measured_not_the_whole_control_range() {
        // Measured corrupting/killing/wedging on a live guest.
        for b in [0x03u8, 0x04, 0x11, 0x13, 0x15, 0x1a, 0x7f] {
            assert!(
                LINE_DISCIPLINE_SPECIALS.contains(&b),
                "0x{b:02x} was measured as altered and must be listed"
            );
        }
        // Measured arriving INTACT: VERASE is DEL here, so 0x08 is ordinary
        // data. Listing it would warn about a payload that is actually fine.
        assert!(
            !LINE_DISCIPLINE_SPECIALS.contains(&0x08),
            "0x08 arrived intact in the 926-bin4 sweep; listing it would warn \
             about bytes that are not broken"
        );
        assert!(
            !LINE_DISCIPLINE_SPECIALS.contains(&0x41),
            "0x41 is the sweep's negative control"
        );
    }

    /// ORDER 925-eofi — THE TEST THAT WOULD HAVE CAUGHT THE FIRST ATTEMPT.
    ///
    /// The EOF was originally added to `exec_over_stream_with_input` only. Its
    /// tests scanned that function, passed, and the live run still hung —
    /// because `--exec-guest` goes through the STREAMING entry point, which is
    /// a separate function with its own handshake and its own input loop. A
    /// per-function assertion cannot see a sibling that forgot.
    ///
    /// So this enumerates every function that writes `PtyData{ToGuest}` from
    /// an `input` argument and requires each to also send `PtyStdinEof`. A
    /// third input-sending path will fail here on the day it is written.
    #[test]
    fn every_input_entry_point_sends_stdin_eof() {
        let source = include_str!("vsock_exec.rs");
        // Function bodies, split on the `async fn` boundary; the test module is
        // excluded so its own quoted needles do not count as senders.
        let code = source.split("#[cfg(test)]").next().expect("code region");
        let mut checked = 0;
        for chunk in code.split("async fn ").skip(1) {
            let name = chunk.split('<').next().unwrap_or("");
            let name = name.split('(').next().unwrap_or("").trim();
            // Only functions that actually chunk an `input` onto the wire.
            if !chunk.contains("for chunk in input.chunks(") {
                continue;
            }
            checked += 1;
            assert!(
                chunk.contains("ControlMessage::PtyStdinEof"),
                "{name} sends stdin but never tells the guest it ended — a child \
                 reading to EOF will hang here. Every input-sending entry point \
                 must send PtyStdinEof (order 925-eofi)."
            );
            assert!(
                chunk.contains("peer_supports_stdin_eof"),
                "{name} must gate the EOF on the advertised capability"
            );
        }
        assert!(
            checked >= 2,
            "expected at least two input-sending entry points; found {checked} — \
             if the shape changed, repoint this scan rather than deleting it"
        );
    }

    /// ORDER 925-eofi — the refusal must be reachable and NAMED. A peer that
    /// cannot be told stdin is finished must not be sent the frame (it would
    /// fail the decode and kill the session), and the caller must not be left
    /// to infer a hang from silence.
    #[test]
    fn stdin_eof_is_gated_on_the_advertised_capability_not_the_wire_version() {
        let source = include_str!("vsock_exec.rs");
        let window = source
            .split("pub async fn exec_over_stream_with_input<S>")
            .nth(1)
            .and_then(|t| t.split("pub async fn ").next())
            .expect("the with_input entry point moved — repoint this scan");
        assert!(
            window.contains("server_caps.iter().any(|c| c == CAP_PTY_STDIN_EOF)"),
            "the EOF frame must be gated on the advertised capability"
        );
        assert!(
            !window.contains("wire_version >= ") && !window.contains("wire_version > "),
            "feature detection must never be a wire-version comparison: a fleet \
             runs hosts newer than the guest staged beside them"
        );
        assert!(
            window.contains("if peer_supports_stdin_eof"),
            "the send must be conditional"
        );
        let else_arm = window
            .split("if peer_supports_stdin_eof")
            .nth(1)
            .expect("gated send");
        assert!(
            else_arm.contains("WARNING") && else_arm.contains("HANG"),
            "an un-negotiated peer must produce a NAMED warning naming the \
             consequence — silence here is the defect this packet exists to remove"
        );
    }

    /// The EOF must only be sent when there was input to terminate; an empty
    /// stdin needs no end marker and sending one would be a frame for nothing.
    #[test]
    fn stdin_eof_is_only_sent_when_input_was_actually_delivered() {
        let source = include_str!("vsock_exec.rs");
        let window = source
            .split("3b) Tell the guest the input is finished")
            .nth(1)
            .expect("the 3b block moved — repoint this scan");
        let guard = window.split("if peer_supports_stdin_eof").next().unwrap();
        assert!(
            guard.contains("if !input.is_empty()"),
            "the EOF path must be inside an input-non-empty guard"
        );
    }

    use super::*;

    #[test]
    fn exec_idle_timeout_is_single_env_overridable_policy() {
        assert_eq!(
            exec_idle_timeout_from(None).unwrap(),
            std::time::Duration::from_secs(IDLE_TIMEOUT_SECS)
        );
        assert_eq!(
            exec_idle_timeout_from(Some("60")).unwrap(),
            std::time::Duration::from_secs(60)
        );
        assert!(
            exec_idle_timeout_from(Some("0"))
                .unwrap_err()
                .contains("at least 60")
        );
        assert!(
            exec_idle_timeout_from(Some("invalid"))
                .unwrap_err()
                .contains("must be an integer")
        );
    }

    /// 689-y2my. A host waiting on a prompt the guest never sends must SAY SO.
    ///
    /// On 2026-08-11 two `--github-login` runs parked for 70 and 6 minutes
    /// emitting nothing at all: `on_event` fired only on a needle match, so a
    /// deadlocked wait and a working-but-slow one looked identical from outside.
    /// The fix is observability, NOT a tighter deadline — heartbeats extending
    /// the deadline is load-bearing (order 332 / 4c9da7cc keeps silent
    /// long-running commands alive, and a real first-run login spends minutes
    /// loading an image before it prompts). So this asserts the WAIT is
    /// reported; it deliberately asserts nothing about timing.
    #[tokio::test]
    async fn heartbeats_report_what_the_host_is_waiting_for() {
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);

        tokio::spawn(async move {
            let _ = read_envelope(&mut guest).await.unwrap();
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 1,
                    body: ControlMessage::HelloAck {
                        wire_version: WIRE_VERSION,
                        server_caps: vec![CAP_PTY_HEARTBEAT_V1.to_string()],
                        build_version: None,
                    },
                },
            )
            .await
            .unwrap();
            let _ = read_envelope(&mut guest).await.unwrap(); // PtyOpen

            // Three heartbeats while the child is busy and silent...
            for _ in 0..3 {
                write_envelope(
                    &mut guest,
                    &ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: 2,
                        body: ControlMessage::PtyData {
                            session_id: 1,
                            direction: PtyDirection::ToHost,
                            bytes: Vec::new(),
                        },
                    },
                )
                .await
                .unwrap();
            }
            // ...then it finally prompts, and the exchange completes.
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 3,
                    body: ControlMessage::PtyData {
                        session_id: 1,
                        direction: PtyDirection::ToHost,
                        bytes: b"authentication token: ".to_vec(),
                    },
                },
            )
            .await
            .unwrap();
            let _ = read_envelope(&mut guest).await.unwrap(); // our response
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

        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let sink = events.clone();
        let out = exec_over_stream_expect_dynamic(
            client,
            &["/bin/login"],
            vec![DynamicExpect {
                needle: b"authentication token".to_vec(),
                label: "github token".to_string(),
                response: Box::new(|| Ok(b"tok\n".to_vec())),
            }],
            move |ev| sink.lock().unwrap().push(ev.to_string()),
        )
        .await
        .expect("exchange completes");

        assert_eq!(out.exit.code, 0);
        let seen = events.lock().unwrap().clone();
        let waiting: Vec<&String> = seen
            .iter()
            .filter(|e| e.contains("still waiting"))
            .collect();
        assert_eq!(
            waiting.len(),
            3,
            "every heartbeat must report the wait, so silence is never mistaken for progress. got: {seen:?}"
        );
        assert!(
            waiting[0].contains("github token"),
            "the report must NAME the pending prompt — that is the whole diagnostic. got: {}",
            waiting[0]
        );
        assert!(
            seen.iter().any(|e| e.contains("matched: github token")),
            "the match event must still fire. got: {seen:?}"
        );
    }

    /// Order 723-2yb3. Drive the expect loop against a fake guest that sends
    /// `heartbeats` frames of the given shape before prompting, and return
    /// every reported event.
    ///
    /// One helper for all four version combinations, because the point of the
    /// matrix is that the SAME exchange succeeds regardless of which heartbeat
    /// shape the guest emits — writing four bespoke fakes would let them drift
    /// apart and stop being a comparison.
    async fn run_with_heartbeats(frames: Vec<ControlMessage>) -> (ExecOutput, Vec<String>) {
        let (out, seen) = try_run_with_heartbeats(frames).await;
        (out.expect("exchange completes"), seen)
    }

    /// Same fake guest, but surfacing the Result so a test can assert the
    /// deadlock error (order 723-g4bk) rather than only successes.
    async fn try_run_with_heartbeats(
        frames: Vec<ControlMessage>,
    ) -> (Result<ExecOutput, String>, Vec<String>) {
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
        tokio::spawn(async move {
            let _ = read_envelope(&mut guest).await.unwrap();
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 1,
                    body: ControlMessage::HelloAck {
                        wire_version: WIRE_VERSION,
                        server_caps: vec![
                            CAP_PTY_HEARTBEAT_V1.to_string(),
                            CAP_PTY_HEARTBEAT_V2.to_string(),
                        ],
                        build_version: None,
                    },
                },
            )
            .await
            .unwrap();
            let _ = read_envelope(&mut guest).await.unwrap(); // PtyOpen
            for body in frames {
                write_envelope(
                    &mut guest,
                    &ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: 2,
                        body,
                    },
                )
                .await
                .unwrap();
            }
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 3,
                    body: ControlMessage::PtyData {
                        session_id: 1,
                        direction: PtyDirection::ToHost,
                        bytes: b"authentication token: ".to_vec(),
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

        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let sink = events.clone();
        let out = exec_over_stream_expect_dynamic(
            client,
            &["/bin/login"],
            vec![DynamicExpect {
                needle: b"authentication token".to_vec(),
                label: "github token".to_string(),
                response: Box::new(|| Ok(b"tok\n".to_vec())),
            }],
            move |ev| sink.lock().unwrap().push(ev.to_string()),
        )
        .await;
        let seen = events.lock().unwrap().clone();
        (out, seen)
    }

    fn v1_heartbeat() -> ControlMessage {
        ControlMessage::PtyData {
            session_id: 1,
            direction: PtyDirection::ToHost,
            bytes: Vec::new(),
        }
    }

    fn v2_heartbeat(input_state: PtyInputState) -> ControlMessage {
        ControlMessage::PtyHeartbeat {
            session_id: 1,
            input_state,
        }
    }

    /// Order 723-2yb3, THE COMPATIBILITY MATRIX. All four combinations must
    /// complete the same exchange; the two MIXED ones are the reason this is
    /// its own rung, because a version-skewed pair must degrade, never wedge.
    #[tokio::test]
    async fn every_heartbeat_version_combination_completes_the_exchange() {
        // v1 guest → v2-capable host. The host advertises v2 but the guest
        // keeps sending empty PtyData; nothing may change for it.
        let (out, seen) = run_with_heartbeats(vec![v1_heartbeat(), v1_heartbeat()]).await;
        assert_eq!(out.exit.code, 0, "v1 guest + v2 host must complete");
        assert_eq!(
            seen.iter().filter(|e| e.contains("still waiting")).count(),
            2,
            "v1 heartbeats must still report the wait: {seen:?}"
        );

        // v2 guest → v2 host, the new path. BlockedOnInput is deliberately
        // absent here: since order 723-g4bk it TERMINATES the exec, which is
        // the point of the ladder, and it has its own tests below.
        for state in [PtyInputState::NotBlocked, PtyInputState::Unknown] {
            let (out, seen) = run_with_heartbeats(vec![v2_heartbeat(state)]).await;
            assert_eq!(out.exit.code, 0, "v2/{state:?} must complete");
            assert_eq!(
                seen.iter().filter(|e| e.contains("still waiting")).count(),
                1,
                "a v2 heartbeat must report the wait exactly like v1: {seen:?}"
            );
        }

        // A guest that MIXES shapes mid-session — the shape a rolling upgrade
        // produces — must also be fine.
        let (out, _) = run_with_heartbeats(vec![
            v1_heartbeat(),
            v2_heartbeat(PtyInputState::NotBlocked),
            v1_heartbeat(),
        ])
        .await;
        assert_eq!(out.exit.code, 0, "mixed-shape heartbeats must complete");
    }

    /// The v2 heartbeat must SAY something the v1 one could not. Without this
    /// the whole rung reduces to a renamed frame.
    #[tokio::test]
    async fn a_v2_heartbeat_reports_the_guests_input_state() {
        let (_, blocked) =
            try_run_with_heartbeats(vec![v2_heartbeat(PtyInputState::BlockedOnInput)]).await;
        assert!(
            blocked
                .iter()
                .any(|e| e.contains("BLOCKED READING ITS TERMINAL")),
            "a blocked guest must be reported as blocked — this is the fact elapsed time cannot supply: {blocked:?}"
        );

        // NEGATIVE CONTROL: the other two states must NOT claim blockage. A
        // report that said "blocked" for every heartbeat would satisfy the
        // assertion above while resurrecting the ambiguity this rung removes.
        let (_, working) = run_with_heartbeats(vec![v2_heartbeat(PtyInputState::NotBlocked)]).await;
        assert!(
            !working.iter().any(|e| e.contains("BLOCKED")),
            "a working guest must never be reported as blocked: {working:?}"
        );
        let (_, unknown) = run_with_heartbeats(vec![v2_heartbeat(PtyInputState::Unknown)]).await;
        assert!(
            !unknown.iter().any(|e| e.contains("BLOCKED")),
            "an undeterminable state must never be reported as blocked: {unknown:?}"
        );
        assert!(
            unknown.iter().any(|e| e.contains("could not determine")),
            "…but it must be distinguishable from 'working': {unknown:?}"
        );
    }

    /// ORDER 690-eug2, criterion 1: guest output must be surfaced AS IT
    /// ARRIVES, not only at PtyClose.
    ///
    /// The packet's headline defect. `on_event` fired solely on a needle match,
    /// so during a long or hung run the operator saw nothing at all — which is
    /// what made every wedge of that week undiagnosable from outside.
    #[tokio::test]
    async fn guest_output_is_surfaced_before_the_session_closes() {
        let (_, seen) = run_with_heartbeats(vec![ControlMessage::PtyData {
            session_id: 1,
            direction: PtyDirection::ToHost,
            bytes: b"Loading image layer 1 of 7\n".to_vec(),
        }])
        .await;

        let previews: Vec<&String> = seen
            .iter()
            .filter(|e| e.starts_with("guest output"))
            .collect();
        assert!(
            !previews.is_empty(),
            "output must be reported while the exchange runs: {seen:?}"
        );
        assert!(
            previews[0].contains("Loading image layer 1 of 7"),
            "the preview must show WHAT the guest said — that is the difference \
             between 'still waiting' and 'oh, it is asking for something': {previews:?}"
        );
        assert!(
            previews[0].contains("bytes so far"),
            "and how much has arrived: {previews:?}"
        );
    }

    /// The preview must not be forgeable by the thing being diagnosed.
    ///
    /// Guest output is raw PTY bytes. Passing control sequences through to a
    /// caller's log would let a wedged guest rewrite lines it does not own —
    /// and that log is the diagnostic surface for exactly that guest.
    #[test]
    fn previews_escape_control_bytes_and_are_bounded() {
        let p = preview_of(b"ok\r\n\x1b[2K\x1b[1Gforged: everything is fine");
        assert!(
            !p.contains('\r') && !p.contains('\n'),
            "no raw newlines: {p}"
        );
        assert!(!p.contains('\x1b'), "no raw escape sequences: {p}");
        assert!(p.contains("\\r\\n"), "they are shown, not dropped: {p}");
        assert!(p.contains("\\x1b"), "escape bytes are visible as hex: {p}");
        assert!(
            p.contains("forged: everything is fine"),
            "text survives: {p}"
        );

        // Bounded, and it SAYS it truncated rather than silently cutting off.
        let long = preview_of(&vec![b'a'; EXEC_PREVIEW_BYTES * 3]);
        assert!(
            long.contains(&format!("+{} bytes", EXEC_PREVIEW_BYTES * 2)),
            "truncation must be stated: {long}"
        );
        assert!(long.len() < EXEC_PREVIEW_BYTES * 2, "and actually bounded");

        // NEGATIVE CONTROL: ordinary output passes through unmangled, or the
        // preview would be useless for reading a prompt.
        assert_eq!(
            preview_of(b"authentication token: "),
            "authentication token: "
        );
    }

    /// Rate-limited, or a chatty guest turns the caller's log into a firehose.
    /// An observability feature that has to be switched off to keep the logs
    /// usable is not observability.
    #[tokio::test]
    async fn a_chatty_guest_does_not_flood_the_event_sink() {
        let burst: Vec<ControlMessage> = (0..200)
            .map(|i| ControlMessage::PtyData {
                session_id: 1,
                direction: PtyDirection::ToHost,
                bytes: format!("line {i}\n").into_bytes(),
            })
            .collect();
        let (_, seen) = run_with_heartbeats(burst).await;

        let previews = seen
            .iter()
            .filter(|e| e.starts_with("guest output"))
            .count();
        assert!(
            previews <= 3,
            "200 frames inside one second must not produce 200 events; got {previews}: {seen:?}"
        );
        assert!(
            previews >= 1,
            "…but the first frame is always shown, because 'the guest has begun \
             talking' is the most useful early signal: {seen:?}"
        );
    }

    /// ORDER 690-eug2, the transcript cap. Pure unit tests over the trim, so
    /// the invariant is checked directly rather than inferred from an exchange.
    #[test]
    fn trimming_keeps_exactly_what_matching_still_needs() {
        // A pending needle: the overlap window must survive, because a match
        // can straddle the trim point exactly as it can straddle a frame.
        let mut buf: Vec<u8> = (0..100u8).collect();
        let mut search_start = 10usize;
        let mut scan_from = 90usize;
        let dropped = trim_transcript(&mut buf, &mut search_start, &mut scan_from, Some(5), 10);
        // dead_for_current = 90 - 4 = 86; max(search_start=10, 86) = 86.
        assert_eq!(dropped, 86);
        assert_eq!(buf.len(), 14, "the overlap window and the tail survive");
        assert_eq!(buf[0], 86, "the retained bytes are the most recent ones");
        assert_eq!(scan_from, 4, "the cursor follows the bytes it points at");
        assert_eq!(search_start, 0);

        // search_start WINS when it is later than the scan window: nothing
        // before it is ever searched again, but the scan window must not be
        // trimmed past it either.
        let mut buf: Vec<u8> = (0..100u8).collect();
        let mut search_start = 95usize;
        let mut scan_from = 96usize;
        let dropped = trim_transcript(&mut buf, &mut search_start, &mut scan_from, Some(50), 10);
        assert_eq!(dropped, 95, "trim to search_start, not past it");
        assert_eq!(search_start, 0);

        // No expect pending: matching is over, so everything is dead.
        let mut buf: Vec<u8> = (0..100u8).collect();
        let mut search_start = 0usize;
        let mut scan_from = 0usize;
        assert_eq!(
            trim_transcript(&mut buf, &mut search_start, &mut scan_from, None, 10),
            100
        );

        // NEGATIVE CONTROLS. Under the cap: never trim — the common case must
        // be untouched, and a trim that fired early would silently shorten
        // every transcript.
        let mut buf: Vec<u8> = (0..100u8).collect();
        let mut search_start = 50usize;
        let mut scan_from = 50usize;
        assert_eq!(
            trim_transcript(&mut buf, &mut search_start, &mut scan_from, Some(3), 1000),
            0
        );
        assert_eq!(buf.len(), 100);

        // Cap 0 disables trimming entirely, even over the limit.
        let mut buf: Vec<u8> = (0..100u8).collect();
        let mut search_start = 50usize;
        let mut scan_from = 50usize;
        assert_eq!(
            trim_transcript(&mut buf, &mut search_start, &mut scan_from, Some(3), 0),
            0
        );

        // Nothing droppable yet (a guest flooding before the first prompt):
        // refuse rather than lose match context. The cap is exceeded and said
        // so, which is better than a match silently lost.
        let mut buf: Vec<u8> = (0..100u8).collect();
        let mut search_start = 0usize;
        let mut scan_from = 0usize;
        assert_eq!(
            trim_transcript(&mut buf, &mut search_start, &mut scan_from, Some(3), 10),
            0
        );
        assert_eq!(
            buf.len(),
            100,
            "match context is never sacrificed to the cap"
        );
    }

    /// NO END-TO-END TRIM TEST, deliberately, and this is the second time the
    /// same trap has been recorded in this file.
    ///
    /// An end-to-end version needs a low cap, and the cap is read from an env
    /// var. The first attempt set `TILLANDSIAS_VSOCK_EXEC_TRANSCRIPT_CAP_BYTES`
    /// inside a `#[tokio::test]` with the comment "safe to set here: no other
    /// test reads this variable" — which was simply false, since every
    /// expect-driver test reads it through `exec_transcript_cap()`. Cargo runs
    /// tests in threads of ONE process, so four unrelated tests failed. Exactly
    /// the mistake `a_peer_that_goes_silent_during_setup_fails_bounded_and_named`
    /// already documents, made again one cycle later.
    ///
    /// The arithmetic — including the case where a match straddles the trim
    /// point — is covered by the unit test above, and the whole existing suite
    /// exercises the driver with trimming compiled in at the real cap. Buying
    /// one more assertion at the cost of a test that only passes when it runs
    /// alone is a bad trade.
    /// ORDER 795-5itp, NEGATIVE CONTROL for exit criterion 3: an over-long
    /// inbound frame is still refused, and the refusal still SAYS so.
    ///
    /// The hand-rolled reader compared the decoded `u32` against
    /// `MAX_MESSAGE_BYTES` itself. That comparison is gone; the bound now comes
    /// from `control_frame_codec()`. Without this test the migration could have
    /// silently widened the ceiling to `u32::MAX` — the codec's default is
    /// 8 MiB, not "whatever the old constant was", so an unbuilt or
    /// default-built codec would accept frames the old reader rejected and this
    /// file's other tests, which only ever send legal frames, would not notice.
    #[tokio::test]
    async fn an_oversize_inbound_frame_is_refused_by_the_codec_bound() {
        let (client, mut guest) = tokio::io::duplex(8192);
        let mut client = frame_stream(client);

        // A length prefix one byte past the shared ceiling. The body is never
        // sent: the codec must refuse on the PREFIX, before allocating for it.
        tokio::spawn(async move {
            let too_big = (MAX_MESSAGE_BYTES + 1) as u32;
            let _ = guest.write_all(&too_big.to_be_bytes()).await;
            let _ = guest.flush().await;
            // Hold the connection open so this cannot pass as an EOF test.
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        });

        let err = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            read_envelope(&mut client),
        )
        .await
        .expect("the bound must fire without waiting for a body that never comes")
        .expect_err("a frame longer than MAX_MESSAGE_BYTES must be refused");

        assert!(
            err.contains("too large"),
            "the refusal must name the size bound, not surface as a generic \
             decode or IO failure: {err}"
        );
        assert!(
            err.contains(&MAX_MESSAGE_BYTES.to_string()),
            "it must name the ceiling that was exceeded, so an operator can tell \
             a policy refusal from a corrupt stream: {err}"
        );
    }

    /// ORDER 795-5itp, THE HAZARD THE SESSION-SCOPED CODEC EXISTS TO AVOID.
    ///
    /// A `Framed` reads into its own buffer and routinely reads PAST the frame
    /// it returns. The obvious migration — construct a `Framed` inside
    /// `read_envelope`, use it, drop it — passes every test in this file,
    /// because they all write one frame and wait. It then loses data in
    /// production the first time a guest emits two frames into one segment:
    /// the second is sitting in the dropped codec's buffer, not on the socket.
    ///
    /// So this test writes two envelopes in a SINGLE `write_all` and requires
    /// both back. It fails loudly if anyone re-scopes the codec per call.
    #[tokio::test]
    async fn two_frames_in_one_write_are_both_read_back() {
        let (client, mut guest) = tokio::io::duplex(8192);
        let mut client = frame_stream(client);

        let env = |seq: u64| ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: ControlMessage::PtyData {
                session_id: 1,
                direction: PtyDirection::ToHost,
                bytes: vec![b'a' + seq as u8; 16],
            },
        };

        // One syscall, two frames — exactly what a chatty guest produces.
        let mut wire = Vec::new();
        for seq in [1u64, 2] {
            let body = encode(&env(seq)).unwrap();
            wire.extend_from_slice(&(body.len() as u32).to_be_bytes());
            wire.extend_from_slice(&body);
        }
        tokio::spawn(async move {
            let _ = guest.write_all(&wire).await;
            let _ = guest.flush().await;
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        });

        let first = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            read_envelope(&mut client),
        )
        .await
        .expect("first frame")
        .expect("first frame decodes");
        assert_eq!(first.seq, 1);

        let second = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            read_envelope(&mut client),
        )
        .await
        .expect(
            "the SECOND frame must still be reachable — if this times out the codec is \
             being constructed per call and the pipelined bytes were dropped with it",
        )
        .expect("second frame decodes");
        assert_eq!(
            second.seq, 2,
            "both frames of a single write must survive the framing layer"
        );
    }

    /// ORDER 690-eug2. A peer that stops DRAINING must not park the writer.
    ///
    /// This is the failure no read-side deadline can observe: the host is not
    /// waiting for data, it is waiting for buffer space. The idle deadline, the
    /// wall-clock ceiling and the setup deadlines are all reads, so a peer that
    /// accepts the connection and then simply stops reading left the host
    /// parked inside a send with nothing on any timer.
    #[tokio::test]
    async fn a_peer_that_stops_draining_does_not_park_the_writer() {
        // A tiny duplex buffer that nobody reads: the second frame cannot fit,
        // so write_all blocks exactly as a real stalled peer would.
        let (mut client, guest) = tokio::io::duplex(64);

        let big = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::PtyData {
                session_id: 1,
                direction: PtyDirection::ToGuest,
                bytes: vec![b'x'; 8192],
            },
        };

        let err = tokio::time::timeout(
            std::time::Duration::from_secs(20),
            write_all_bounded(
                &mut client,
                &encode(&big).unwrap(),
                std::time::Duration::from_millis(50),
                "the frame body",
            ),
        )
        .await
        .expect("the bound must fire well inside the test's own timeout")
        .expect_err("a peer that stops draining must not block forever");

        assert!(
            err.contains("stopped draining"),
            "the failure must name back-pressure, not read as a stale connection: {err}"
        );
        assert!(
            err.contains("the frame body"),
            "it must name WHICH part of the frame stalled: {err}"
        );
        assert!(
            !err.contains("connection stale"),
            "back-pressure is not a stale connection — they have different causes \
             and different fixes: {err}"
        );
        drop(guest);
    }

    /// NEGATIVE CONTROL: a peer that IS draining must not be killed by the
    /// write bound. Every other test in this file writes frames through
    /// write_envelope, so they collectively assert this too — but stating it
    /// once makes the intent explicit rather than incidental.
    #[tokio::test]
    async fn a_draining_peer_is_not_killed_by_the_write_bound() {
        let (out, _) = run_with_heartbeats(vec![]).await;
        assert_eq!(
            out.exit.code, 0,
            "a normal exchange must complete under the write bound"
        );
    }

    /// ORDER 690-eug2, the correctness case for the incremental needle scan.
    ///
    /// A PTY delivers output in whatever chunks the kernel feels like, so a
    /// prompt routinely arrives SPLIT across frames. The old scan re-searched
    /// the whole transcript every time and could not care; the cursor version
    /// can, and an off-by-one in its overlap would silently lose exactly these
    /// matches — silently, because the exec would then wait for a prompt that
    /// had already arrived and fail much later as a timeout.
    ///
    /// Every existing test in this file feeds each needle in ONE frame, so
    /// none of them would have caught it.
    #[tokio::test]
    async fn a_needle_split_across_frames_is_still_matched() {
        // One byte per frame: the most adversarial split available, and it
        // exercises the overlap on every single frame.
        let per_byte: Vec<ControlMessage> = b"authentication token: "
            .iter()
            .map(|b| ControlMessage::PtyData {
                session_id: 1,
                direction: PtyDirection::ToHost,
                bytes: vec![*b],
            })
            .collect();

        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
        tokio::spawn(async move {
            let _ = read_envelope(&mut guest).await.unwrap();
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 1,
                    body: ControlMessage::HelloAck {
                        wire_version: WIRE_VERSION,
                        server_caps: vec![],
                        build_version: None,
                    },
                },
            )
            .await
            .unwrap();
            let _ = read_envelope(&mut guest).await.unwrap(); // PtyOpen
            for body in per_byte {
                write_envelope(
                    &mut guest,
                    &ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: 2,
                        body,
                    },
                )
                .await
                .unwrap();
            }
            let _ = read_envelope(&mut guest).await.unwrap(); // our response
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 3,
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

        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let sink = events.clone();
        let out = exec_over_stream_expect_dynamic(
            client,
            &["/bin/login"],
            vec![DynamicExpect {
                needle: b"authentication token".to_vec(),
                label: "github token".to_string(),
                response: Box::new(|| Ok(b"tok\n".to_vec())),
            }],
            move |ev| sink.lock().unwrap().push(ev.to_string()),
        )
        .await
        .expect("a byte-at-a-time prompt must still match");

        assert_eq!(out.exit.code, 0);
        let seen = events.lock().unwrap().clone();
        assert!(
            seen.iter().any(|e| e.contains("matched: github token")),
            "a needle delivered one byte per frame must still be found: {seen:?}"
        );
    }

    /// ORDER 690-eug2. A peer that ACCEPTS the connection and then goes silent
    /// must fail, bounded and stage-named, at every setup stage.
    ///
    /// This is the gap every other bound on this seam left open: the idle
    /// deadline, the wall-clock ceiling and the heartbeat all live on the DATA
    /// path, and a connection that never establishes never reaches any of them.
    /// The handshake reads were bare `read_envelope` — untimed — so a guest
    /// that accepted the vsock connection and never answered `Hello` parked the
    /// host forever.
    #[tokio::test]
    async fn a_peer_that_goes_silent_during_setup_fails_bounded_and_named() {
        // Drive the helper DIRECTLY with an explicit deadline rather than
        // setting EXEC_IDLE_TIMEOUT_ENV. The first version of this test set
        // that variable and broke 18 unrelated tests: cargo runs them in
        // threads of ONE process, so a global env mutation is visible to every
        // other test that reads it. A test that can only pass when it runs
        // alone is not a test of this code.
        let (client, guest) = tokio::io::duplex(8192);
        let mut client = frame_stream(client);
        // Hold the guest end open and never write. Dropping it would make this
        // an EOF test — a DIFFERENT failure that already worked. The wedge
        // being pinned is a peer that stays CONNECTED and silent.
        let err = read_setup_envelope(
            &mut client,
            std::time::Duration::from_millis(50),
            "the Hello handshake",
        )
        .await
        .expect_err("a silent peer must not park the host forever");
        assert!(
            err.contains("never completed the Hello handshake"),
            "the failure must name the STAGE — 'no data from guest' is true of five \
             different moments here and useless in all of them: {err}"
        );
        assert!(
            err.contains("reachable and silent"),
            "it must distinguish a silent peer from a refused connection: {err}"
        );
        drop(guest);

        // The other setup stage produces its own name, so the two faults are
        // distinguishable in an operator's log.
        let (client, guest) = tokio::io::duplex(8192);
        let mut client = frame_stream(client);
        let err = read_setup_envelope(
            &mut client,
            std::time::Duration::from_millis(50),
            "the PtyOpen reply",
        )
        .await
        .expect_err("bounded at every setup stage");
        assert!(
            err.contains("never completed the PtyOpen reply"),
            "the two setup stages must be distinguishable: {err}"
        );
        drop(guest);
    }

    /// The bound is wired into EVERY setup read, not just the one a behavioural
    /// test happened to exercise.
    ///
    /// Structural because the behavioural version would need the production
    /// 300s deadline or a global env mutation, and the latter is what broke 18
    /// tests when this was first written. A bare `read_envelope(&mut stream)`
    /// on the setup path is exactly the defect 690-eug2 names, so its absence
    /// is the thing to assert.
    #[test]
    fn no_setup_read_is_left_unbounded() {
        let src = include_str!("vsock_exec.rs");
        // Scan the PRODUCTION half only. The first version scanned the whole
        // file and flagged its own filter expression — a check that reads its
        // own source as evidence, which is the antipattern 601-462g's problem
        // statement names ("a freshness gate that greps its own comment").
        let production = src
            .split_once("#[cfg(test)]")
            .map(|(before, _)| before)
            .unwrap_or(src);
        let offenders: Vec<&str> = production
            .lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .filter(|l| l.contains("read_envelope(&mut stream).await"))
            .collect();
        assert!(
            offenders.is_empty(),
            "every setup read must go through read_setup_envelope (order 690-eug2); \
             found bare reads: {offenders:?}"
        );
    }

    /// NEGATIVE CONTROL for the bound above: a peer that answers NORMALLY must
    /// not be killed by it. A setup deadline that fired on healthy handshakes
    /// would break every exec while satisfying the test above.
    #[tokio::test]
    async fn a_responsive_peer_is_not_killed_by_the_setup_deadline() {
        let (out, _) = run_with_heartbeats(vec![]).await;
        assert_eq!(
            out.exit.code, 0,
            "a normal handshake must complete under the setup deadline"
        );
    }

    /// ORDER 723-g4bk, THE REGRESSION TEST FOR THE WEDGE THAT STARTED ALL OF
    /// THIS. A guest that heartbeats forever while blocked on a prompt this
    /// exec will never answer must be REPORTED, not waited out.
    ///
    /// The original incident ran 70 minutes and was only stopped by an
    /// operator. After item (a) it would have been stopped by the 4h ceiling.
    /// Now it is stopped on the first heartbeat that says so — and the test
    /// asserts that by feeding a hundred heartbeats: if the exec were still
    /// waiting for a bound rather than acting on the report, it would consume
    /// all of them and then hang waiting for a prompt that never comes.
    #[tokio::test]
    async fn a_blocked_guest_is_reported_immediately_not_waited_out() {
        let (out, seen) = try_run_with_heartbeats(
            std::iter::repeat_with(|| v2_heartbeat(PtyInputState::BlockedOnInput))
                .take(100)
                .collect(),
        )
        .await;

        let err = out.expect_err("a guest-reported deadlock must fail the exec");
        assert!(
            err.contains("DEADLOCK"),
            "the failure must name the condition, not read as a timeout: {err}"
        );
        assert!(
            err.contains("github token"),
            "it must name the pending expect — that is the diagnostic: {err}"
        );
        assert!(
            err.contains("blocked reading its terminal"),
            "it must say what the GUEST reported: {err}"
        );
        // Distinguishable from BOTH neighbours. These three failures were
        // previously indistinguishable, which is the whole reason for the
        // ladder.
        assert!(
            !err.contains("wall-clock ceiling"),
            "a deadlock is not a ceiling breach: {err}"
        );
        assert!(
            !err.contains("connection stale"),
            "a deadlock is not a dead wire: {err}"
        );
        assert_eq!(
            seen.iter().filter(|e| e.contains("still waiting")).count(),
            1,
            "it must act on the FIRST blocked heartbeat, not accumulate reports: {seen:?}"
        );
    }

    /// NEGATIVE CONTROL for the rung: the states that are NOT a deadlock must
    /// behave exactly as before. Without this, "fail when blocked" could
    /// degrade into "fail when heartbeating", which would kill the legitimate
    /// 1290s first-run login that refuted the original progress deadline.
    #[tokio::test]
    async fn a_working_or_undeterminable_guest_is_never_reported_as_deadlocked() {
        for state in [PtyInputState::NotBlocked, PtyInputState::Unknown] {
            let (out, _) = try_run_with_heartbeats(
                std::iter::repeat_with(|| v2_heartbeat(state))
                    .take(50)
                    .collect(),
            )
            .await;
            let out = out.unwrap_or_else(|e| panic!("{state:?} must not fail the exec: {e}"));
            assert_eq!(out.exit.code, 0, "{state:?} must complete normally");
        }

        // And a v1 guest — which cannot report anything — is likewise untouched.
        let (out, _) =
            try_run_with_heartbeats(std::iter::repeat_with(v1_heartbeat).take(50).collect()).await;
        assert_eq!(
            out.expect("a v1 guest must be unaffected by rung 3")
                .exit
                .code,
            0
        );
    }

    /// The escape hatch works, mirroring the ceiling's own env. An operator who
    /// hits a case nobody anticipated must be able to switch a new terminal
    /// condition off without editing code.
    #[test]
    fn the_deadlock_report_can_be_disabled() {
        // Read through the same helper the loop uses, rather than asserting on
        // env plumbing that the loop might not share.
        assert!(deadlock_report_enabled() || std::env::var(EXEC_DEADLOCK_REPORT_ENV).is_ok());
        unsafe { std::env::set_var(EXEC_DEADLOCK_REPORT_ENV, "0") };
        assert!(!deadlock_report_enabled(), "0 must disable the report");
        unsafe { std::env::remove_var(EXEC_DEADLOCK_REPORT_ENV) };
        assert!(
            deadlock_report_enabled(),
            "absent env must leave it enabled"
        );
    }

    /// NEGATIVE CONTROL (bar-raise 634-39ik) for the test above. A build that
    /// emitted "still waiting" unconditionally would satisfy it. When the guest
    /// is actually producing output there is nothing to wait on, so no such
    /// event may appear — otherwise the signal becomes noise and stops meaning
    /// "this exchange is stuck".
    #[tokio::test]
    async fn a_talking_guest_produces_no_waiting_reports() {
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);

        tokio::spawn(async move {
            let _ = read_envelope(&mut guest).await.unwrap();
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 1,
                    body: ControlMessage::HelloAck {
                        wire_version: WIRE_VERSION,
                        server_caps: vec![],
                        build_version: None,
                    },
                },
            )
            .await
            .unwrap();
            let _ = read_envelope(&mut guest).await.unwrap();
            // Real output only — no heartbeats at all.
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 2,
                    body: ControlMessage::PtyData {
                        session_id: 1,
                        direction: PtyDirection::ToHost,
                        bytes: b"working...\nauthentication token: ".to_vec(),
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
                            code: 0,
                            signal: None,
                        },
                    },
                },
            )
            .await
            .unwrap();
        });

        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let sink = events.clone();
        exec_over_stream_expect_dynamic(
            client,
            &["/bin/login"],
            vec![DynamicExpect {
                needle: b"authentication token".to_vec(),
                label: "github token".to_string(),
                response: Box::new(|| Ok(b"tok\n".to_vec())),
            }],
            move |ev| sink.lock().unwrap().push(ev.to_string()),
        )
        .await
        .expect("exchange completes");

        let seen = events.lock().unwrap().clone();
        assert!(
            !seen.iter().any(|e| e.contains("still waiting")),
            "a guest that is talking is not stuck; reporting a wait here would make the \
             signal meaningless. got: {seen:?}"
        );
    }

    /// Regression pin (order 128 conformance harness, 2026-07-14): when the
    /// guest answers PtyOpen with a terminal `Error` envelope (e.g. exec
    /// allowlist rejection), `exec_over_stream_with_input` MUST return that
    /// error immediately instead of ignoring the frame and idling until the
    /// 300s timeout — the hang that made every trait-level `exec` against a
    /// rejected argv look like a dead wire.
    /// Order 689-xpq7. The shared half of the regression pin.
    ///
    /// The single-driver pin below (2026-07-14) is why this defect was found at
    /// all — and why it survived: the fix landed on two drivers of three, and a
    /// pin covering one driver cannot notice the third regressing. So the guest
    /// half is lifted out here and every driver runs against it. Adding a fourth
    /// driver without the Error arm now fails this suite instead of being
    /// discovered by an operator waiting 300 seconds for the wrong message.
    ///
    /// `reject_after_open` answers PtyOpen with a terminal Error, which is the
    /// live shape: every Error emission site in the guest today fires BEFORE a
    /// PTY session exists, i.e. on early rejection such as an exec-allowlist
    /// refusal.
    async fn reject_after_open<S>(guest: &mut ExecFramed<S>)
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let hello = read_envelope(guest).await.unwrap();
        assert!(matches!(hello.body, ControlMessage::Hello { .. }));
        write_envelope(
            guest,
            &ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 1,
                body: ControlMessage::HelloAck {
                    wire_version: WIRE_VERSION,
                    server_caps: vec![],
                    build_version: None,
                },
            },
        )
        .await
        .unwrap();

        let open = read_envelope(guest).await.unwrap();
        assert!(matches!(open.body, ControlMessage::PtyOpen { .. }));
        write_envelope(
            guest,
            &ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 2,
                body: ControlMessage::Error {
                    seq_in_reply_to: Some(open.seq),
                    code: tillandsias_control_wire::ErrorCode::Internal,
                    message: "PtyOpen rejected: exec allowlist violation".to_string(),
                },
            },
        )
        .await
        .unwrap();
    }

    fn assert_surfaced_guest_error(err: &str) {
        assert!(
            err.contains("guest error") && err.contains("allowlist"),
            "the guest's own message must reach the operator, got: {err}"
        );
        assert!(
            !err.contains("connection stale"),
            "a swallowed Error is reported as a stale wire — the misdiagnosis this fixes: {err}"
        );
    }

    #[tokio::test]
    async fn every_driver_surfaces_a_guest_error_envelope() {
        // Driver 1: the buffered one, which has had the arm since 2026-07-14.
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
        let guest_task = tokio::spawn(async move { reject_after_open(&mut guest).await });
        let err = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            exec_over_stream_with_input(client, &["/bin/false"], b""),
        )
        .await
        .expect("buffered driver must resolve well before the idle timeout")
        .expect_err("buffered driver must surface the guest Error");
        assert_surfaced_guest_error(&err);
        guest_task.await.unwrap();

        // Driver 2: the streaming one, which always had the arm.
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
        let guest_task = tokio::spawn(async move { reject_after_open(&mut guest).await });
        let err = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            exec_over_stream_with_input_streaming_timeout(
                client,
                &["/bin/false"],
                b"",
                None,
                &mut |_: &[u8]| {},
                std::time::Duration::from_secs(30),
            ),
        )
        .await
        .expect("streaming driver must resolve well before the idle timeout")
        .expect_err("streaming driver must surface the guest Error");
        assert_surfaced_guest_error(&err);
        guest_task.await.unwrap();

        // Driver 3: the expect driver — the one that was silently dropping it.
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
        let guest_task = tokio::spawn(async move { reject_after_open(&mut guest).await });
        let err = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            exec_over_stream_expect_dynamic(
                client,
                &["/bin/false"],
                vec![DynamicExpect {
                    needle: b"password:".to_vec(),
                    response: Box::new(|| Ok(b"secret\n".to_vec())),
                    label: "password prompt".to_string(),
                }],
                |_| {},
            ),
        )
        .await
        .expect("expect driver must resolve well before the idle timeout")
        .expect_err("expect driver must surface the guest Error");
        assert_surfaced_guest_error(&err);
        // A rejected exec dies waiting for a prompt that will never come, so the
        // report names what it was waiting for. Without this the operator learns
        // that something failed but not where in the exchange.
        assert!(
            err.contains("password prompt"),
            "the pending expect must be named: {err}"
        );
        guest_task.await.unwrap();
    }

    /// NEGATIVE CONTROL for the new arm: a normal PtyClose still returns Ok with
    /// the guest's output and exit. Without this, the Error arm could be made to
    /// pass by failing every exec.
    #[tokio::test]
    async fn expect_driver_normal_close_is_unaffected_by_the_error_arm() {
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
        let guest_task = tokio::spawn(async move {
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
                        build_version: None,
                    },
                },
            )
            .await
            .unwrap();
            let open = read_envelope(&mut guest).await.unwrap();
            let session_id = match open.body {
                ControlMessage::PtyOpen { session_id, .. } => session_id,
                other => panic!("expected PtyOpen, got {}", other.kind()),
            };
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 2,
                    body: ControlMessage::PtyData {
                        session_id,
                        direction: PtyDirection::ToHost,
                        bytes: b"all good\n".to_vec(),
                    },
                },
            )
            .await
            .unwrap();
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 3,
                    body: ControlMessage::PtyClose {
                        session_id,
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

        let out = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            exec_over_stream_expect_dynamic(client, &["/bin/true"], vec![], |_| {}),
        )
        .await
        .expect("normal close must resolve promptly")
        .expect("a normal PtyClose must still succeed");
        assert_eq!(
            out.exit,
            PtyExit {
                code: 0,
                signal: None
            }
        );
        assert_eq!(String::from_utf8_lossy(&out.stdout), "all good\n");
        guest_task.await.unwrap();
    }

    #[tokio::test]
    async fn exec_with_input_surfaces_guest_error_instead_of_hanging() {
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);

        let guest_task = tokio::spawn(async move {
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
                        build_version: None,
                    },
                },
            )
            .await
            .unwrap();

            let open = read_envelope(&mut guest).await.unwrap();
            assert!(matches!(open.body, ControlMessage::PtyOpen { .. }));
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 2,
                    body: ControlMessage::Error {
                        seq_in_reply_to: Some(open.seq),
                        code: tillandsias_control_wire::ErrorCode::Internal,
                        message: "PtyOpen rejected: exec allowlist violation".to_string(),
                    },
                },
            )
            .await
            .unwrap();
        });

        let err = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            exec_over_stream_with_input(client, &["/bin/false"], b""),
        )
        .await
        .expect("must resolve well before the idle timeout — not hang")
        .expect_err("guest Error envelope must surface as Err");
        assert!(
            err.contains("guest error") && err.contains("allowlist"),
            "wrong diagnosis: {err}"
        );
        guest_task.await.unwrap();
    }

    /// Drive `exec_over_stream` against an in-memory fake guest that completes
    /// the handshake, streams output, and closes with exit code 0 — proving the
    /// non-interactive exec protocol end to end without a real VM.
    #[tokio::test]
    async fn exec_over_stream_collects_output_and_exit() {
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);

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
                        build_version: None,
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

    /// 689-y2my item (a). The ceiling parser's contract, including the two
    /// ways a host can opt out of the default and the one way it cannot.
    #[test]
    fn wall_clock_ceiling_parses_default_disable_and_floor() {
        assert_eq!(
            exec_wall_clock_ceiling_from(None).unwrap(),
            Some(std::time::Duration::from_secs(EXEC_WALL_CLOCK_CEILING_SECS)),
            "unset means the default ceiling, not unbounded"
        );
        assert_eq!(
            exec_wall_clock_ceiling_from(Some("0")).unwrap(),
            None,
            "an explicit 0 disables the ceiling — a host with a genuinely \
             unbounded exec should say so out loud"
        );
        assert_eq!(
            exec_wall_clock_ceiling_from(Some("7200")).unwrap(),
            Some(std::time::Duration::from_secs(7200))
        );
        // Floor: a ceiling short enough to kill legitimate work is the exact
        // mistake criterion 1 was refuted for. Refuse it rather than honour it.
        assert!(
            exec_wall_clock_ceiling_from(Some("30")).is_err(),
            "a sub-floor ceiling must be refused, not silently accepted"
        );
        assert!(exec_wall_clock_ceiling_from(Some("banana")).is_err());
    }

    /// The breach message must carry the two facts whose absence made the
    /// 2026-08-11 wedge unreadable: what it was waiting for, and how much the
    /// guest had said.
    #[test]
    fn wall_clock_ceiling_error_names_the_pending_expect_and_bytes() {
        let msg = wall_clock_ceiling_error(
            std::time::Duration::from_secs(14_400),
            Some("github device prompt"),
            42,
        );
        assert!(msg.contains("14400s"), "{msg}");
        assert!(msg.contains("github device prompt"), "{msg}");
        assert!(msg.contains("42 bytes"), "{msg}");
        // It must not read as a dead wire — that misdirection is the defect.
        assert!(
            msg.contains("wire was alive"),
            "a ceiling breach is a wedged guest, not a stale connection: {msg}"
        );

        // Negative control: with nothing pending the message must NOT invent a
        // label. A formatter that always printed one would pass the assertion
        // above while lying whenever the exec was between expects.
        let none_pending = wall_clock_ceiling_error(std::time::Duration::from_secs(300), None, 0);
        assert!(none_pending.contains("no expect pending"), "{none_pending}");
        assert!(
            !none_pending.contains("still waiting for"),
            "{none_pending}"
        );
    }

    /// The ORDER-332 GUARD, restated as a negative control for this cycle's
    /// change: a guest that heartbeats through silence longer than the idle
    /// deadline must still not be killed. The ceiling added here is four hours;
    /// nothing in this suite may come near it. If a future edit tightens the
    /// ceiling toward the idle deadline, this is the test that should fail.
    #[test]
    fn wall_clock_ceiling_leaves_enormous_headroom_over_measured_first_run() {
        // Measured on macOS 2026-08-12: ~1290s of legitimate silence during a
        // first-run --github-login that then SUCCEEDED.
        let measured_worst_case_secs = 1290u64;
        let ceiling = exec_wall_clock_ceiling_from(None)
            .expect("default ceiling parses")
            .expect("the default is a ceiling, not unbounded")
            .as_secs();
        assert!(
            ceiling >= measured_worst_case_secs * 10,
            "the ceiling ({ceiling}s) must stay far above every legitimate duration \
             anyone has measured ({measured_worst_case_secs}s); a bound tight enough to \
             catch a wedge promptly is tight enough to kill working work (order 332, \
             689-y2my criterion-1 refutation)"
        );

        // The configurable FLOOR must not sit below the idle deadline either,
        // or a host could set a ceiling that preempts the liveness bound it is
        // layered above. Read both through the parsers so this compares the
        // values callers actually get.
        let floor = exec_wall_clock_ceiling_from(Some("300"))
            .expect("floor value parses")
            .expect("a floor value is a ceiling")
            .as_secs();
        let idle = exec_idle_timeout_from(None)
            .expect("default idle timeout parses")
            .as_secs();
        assert!(
            floor >= idle,
            "the ceiling floor ({floor}s) must not sit below the idle deadline ({idle}s)"
        );
    }

    #[tokio::test]
    async fn streaming_exec_heartbeats_survive_total_silence_beyond_idle_deadline() {
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
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
                        build_version: None,
                    },
                },
            )
            .await
            .unwrap();
            let _ = read_envelope(&mut guest).await.unwrap();

            for seq in 3..=7 {
                tokio::time::sleep(std::time::Duration::from_millis(15)).await;
                write_envelope(
                    &mut guest,
                    &ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq,
                        body: ControlMessage::PtyData {
                            session_id: 1,
                            direction: PtyDirection::ToHost,
                            bytes: Vec::new(),
                        },
                    },
                )
                .await
                .unwrap();
            }
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 8,
                    body: ControlMessage::PtyData {
                        session_id: 1,
                        direction: PtyDirection::ToHost,
                        bytes: b"build complete\n".to_vec(),
                    },
                },
            )
            .await
            .unwrap();
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 9,
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

        let started = std::time::Instant::now();
        let mut output = Vec::new();
        let out = exec_over_stream_with_input_streaming_timeout(
            client,
            &["/bin/sh", "-c", "slow build"],
            &[],
            None,
            &mut |bytes: &[u8]| output.extend_from_slice(bytes),
            std::time::Duration::from_millis(35),
        )
        .await
        .expect("heartbeat frames must keep a silent build alive");

        assert!(started.elapsed() > std::time::Duration::from_millis(70));
        assert_eq!(out.exit.code, 0);
        assert_eq!(output, b"build complete\n");
        guest_task.await.unwrap();
    }

    #[tokio::test]
    async fn streaming_exec_times_out_when_slow_guest_sends_no_frames() {
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
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
                        build_version: None,
                    },
                },
            )
            .await
            .unwrap();
            let _ = read_envelope(&mut guest).await.unwrap();
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        });

        let err = exec_over_stream_with_input_streaming_timeout(
            client,
            &["/bin/sh", "-c", "silent build"],
            &[],
            None,
            &mut |_| {},
            std::time::Duration::from_millis(25),
        )
        .await
        .expect_err("a silent peer without heartbeats must still time out");
        assert!(err.contains("no data from guest for 25ms"), "got: {err}");
        guest_task.abort();
    }

    /// `exec_over_stream_with_input` delivers stdin/PTY input to the guest — the
    /// keystone for the github-login token paste (`read -rs TOKEN < /dev/tty`).
    /// The fake guest reads the ToGuest frame and echoes it back, mirroring a
    /// `read X; echo "GOT:$X"` round-trip.
    #[tokio::test]
    async fn exec_over_stream_with_input_delivers_stdin() {
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
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
                        build_version: None,
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
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
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
                        build_version: None,
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
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
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
                        build_version: None,
                    },
                },
            )
            .await
            .unwrap();
            let _ = read_envelope(&mut guest).await.unwrap(); // PtyOpen

            // Helper: emit a ToHost prompt, then expect the next ToGuest response.
            async fn step(
                guest: &mut ExecFramed<tokio::io::DuplexStream>,
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
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
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
                        build_version: None,
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

    /// Drive the capability-gated exec against a peer that advertises
    /// `server_caps`, and report whether a `PtyOpen` was ever read off the
    /// wire. That last fact is the one worth measuring (795-zshi): a gate that
    /// merely returns an error AFTER sending the request has not gated
    /// anything — the guest already saw a shape it cannot serve.
    async fn gated_exec_against_caps(caps: Vec<String>) -> (Result<ExecOutput, String>, bool) {
        let (client, guest) = tokio::io::duplex(8192);
        let mut guest = frame_stream(guest);
        let saw_pty_open = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = saw_pty_open.clone();
        let guest_task = tokio::spawn(async move {
            let _ = read_envelope(&mut guest).await.unwrap(); // Hello
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 1,
                    body: ControlMessage::HelloAck {
                        wire_version: WIRE_VERSION,
                        server_caps: caps,
                        build_version: None,
                    },
                },
            )
            .await
            .unwrap();
            // A gated-off host hangs up here, so this read fails rather than
            // yielding a frame — which is exactly the assertion.
            if let Ok(env) = read_envelope(&mut guest).await
                && matches!(env.body, ControlMessage::PtyOpen { .. })
            {
                flag.store(true, std::sync::atomic::Ordering::SeqCst);
            }
            write_envelope(
                &mut guest,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 2,
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
            .ok();
        });
        let result = exec_over_stream_with_input_streaming_requiring(
            client,
            &["/usr/bin/tillandsias", "a'b"],
            b"",
            tillandsias_control_wire::CAP_EXEC_ARGV_VECTOR,
            |_| {},
        )
        .await;
        let _ = guest_task.await;
        let sent = saw_pty_open.load(std::sync::atomic::Ordering::SeqCst);
        (result, sent)
    }

    /// 795-zshi: a guest WITHOUT the capability gets a refusal that names the
    /// missing capability and what it did advertise — and never sees the
    /// PtyOpen at all.
    #[tokio::test]
    async fn a_guest_without_the_cap_is_refused_before_the_request_is_sent() {
        let (result, sent_pty_open) =
            gated_exec_against_caps(vec![CAP_PTY_HEARTBEAT_V1.to_string()]).await;
        let err = result.expect_err("an old guest must not receive the verbatim shape");
        assert!(
            err.contains(tillandsias_control_wire::CAP_EXEC_ARGV_VECTOR),
            "the refusal must name the MISSING capability: {err}"
        );
        assert!(
            err.contains(CAP_PTY_HEARTBEAT_V1),
            "and what the guest DID advertise, so the reader can tell an old \
             guest from a broken handshake: {err}"
        );
        assert!(
            !sent_pty_open,
            "the gate must fire BEFORE PtyOpen — a refusal after the send has \
             gated nothing"
        );
    }

    /// NEGATIVE CONTROL: with the capability advertised, the same call proceeds
    /// and the guest receives the request. Without this, deleting the gate
    /// entirely would still pass the test above.
    #[tokio::test]
    async fn a_guest_with_the_cap_proceeds_to_the_request() {
        let (result, sent_pty_open) = gated_exec_against_caps(vec![
            tillandsias_control_wire::CAP_EXEC_ARGV_VECTOR.to_string(),
        ])
        .await;
        assert!(
            result.is_ok(),
            "a capable guest must not be refused: {result:?}"
        );
        assert!(sent_pty_open, "the request must actually reach the guest");
    }

    /// An empty `server_caps` must read as "advertised nothing", not as an
    /// empty gap in the sentence. The message IS the value of this gate.
    #[test]
    fn the_refusal_names_an_empty_advertisement_explicitly() {
        let msg = missing_cap_message(tillandsias_control_wire::CAP_EXEC_ARGV_VECTOR, &[]);
        assert!(msg.contains("nothing"), "{msg}");
    }
}
