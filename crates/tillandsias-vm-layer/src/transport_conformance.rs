//! Shared conformance fixtures for [`GuestTransport`] backends (order 128).
//!
//! One fixture set, every platform backend: a backend "conforms to the
//! host<->guest facade" exactly when `run_all` reports every fixture passing
//! against a REAL guest speaking the tillandsias control-wire exec protocol.
//! The fixtures are platform-agnostic (they only see `&dyn GuestTransport` +
//! a `GuestEndpoint`); each platform provides a live runner that boots its
//! substrate and calls [`run_all`]:
//!
//! - macOS: `tillandsias-tray --transport-conformance` (VZ main-thread boot)
//! - Windows: WSL tray equivalent against `WslGuestTransport`
//! - Linux: podman/native runner against the Linux backend (order 125)
//!
//! Contract notes (kept deliberately at the CURRENT cross-backend bar):
//! - stdout/stderr arrive MERGED through the PTY exec protocol; fixtures
//!   assert on combined output and never on a separate stderr channel.
//! - plain exit codes must propagate verbatim. Signal-exit normalization is
//!   NOT asserted here yet: the macOS backend maps signal death to 128+n
//!   while the Windows backend returns the raw protocol code — divergence
//!   filed 2026-07-14 (guest-transport-exit-signal-divergence); when the
//!   facade spec pins one mapping, add the fixture.
//! - stdin fixtures must not depend on EOF delivery (`head -c N` style
//!   consumers, never bare `cat`): the exec protocol delivers input frames
//!   but EOF semantics are backend-dependent today.
//! - every fixture argv uses the guest's SANCTIONED wrapper shape
//!   `["/bin/bash", "-lc", <script>]` — the guest pty handler enforces an
//!   exec allowlist (headless `pty_handler.rs`) and rejects raw `/bin/sh`
//!   or bare binaries; conformance runs against the guest as it ships,
//!   allowlist included (caught live 2026-07-14).
//!
//! @trace spec:host-guest-transport
//! @trace plan/issues/host-guest-transport-normalization-spec-2026-06-28.md

use tillandsias_control_wire::guest_transport::{
    ExecChunk, ExecRequest, GuestEndpoint, GuestTransport,
};

/// Outcome of one conformance fixture.
#[derive(Debug)]
pub struct FixtureResult {
    /// Stable fixture name (used in runner output and litmus greps).
    pub name: &'static str,
    /// `Ok(())` on pass; `Err(reason)` with a one-line diagnosis on fail.
    pub outcome: Result<(), String>,
}

impl FixtureResult {
    fn pass(name: &'static str) -> Self {
        Self {
            name,
            outcome: Ok(()),
        }
    }
    fn fail(name: &'static str, reason: impl Into<String>) -> Self {
        Self {
            name,
            outcome: Err(reason.into()),
        }
    }
}

/// True when every fixture in `results` passed.
pub fn all_passed(results: &[FixtureResult]) -> bool {
    results.iter().all(|r| r.outcome.is_ok())
}

/// Render one stable, greppable report line per fixture plus a final
/// verdict line. The verdict grammar is falsifiable:
/// `transport-conformance: PASS n=<N>` or `transport-conformance: FAIL <name>: <reason>`.
pub fn render_report(results: &[FixtureResult]) -> String {
    let mut out = String::new();
    for r in results {
        match &r.outcome {
            Ok(()) => out.push_str(&format!("fixture {} ok\n", r.name)),
            Err(e) => out.push_str(&format!("fixture {} FAIL: {e}\n", r.name)),
        }
    }
    match results.iter().find(|r| r.outcome.is_err()) {
        None => out.push_str(&format!(
            "transport-conformance: PASS n={}\n",
            results.len()
        )),
        Some(first) => out.push_str(&format!(
            "transport-conformance: FAIL {}: {}\n",
            first.name,
            first.outcome.as_ref().unwrap_err()
        )),
    }
    out
}

/// ExecOneShot: a trivial command round-trips with exit 0 and its marker
/// visible in the (PTY-merged) output.
pub async fn exec_echo_roundtrip(t: &dyn GuestTransport, ep: &GuestEndpoint) -> FixtureResult {
    const NAME: &str = "exec-echo-roundtrip";
    const MARKER: &str = "tillandsias-conformance-ping";
    let req = ExecRequest::new(&["/bin/bash", "-lc", "echo tillandsias-conformance-ping"]);
    match t.exec(ep, req).await {
        Ok(out) if out.exit_code == 0 && out.stdout_text().contains(MARKER) => {
            FixtureResult::pass(NAME)
        }
        Ok(out) => FixtureResult::fail(
            NAME,
            format!(
                "exit={} stdout={:?} (wanted exit 0 + marker)",
                out.exit_code,
                out.stdout_text()
            ),
        ),
        Err(e) => FixtureResult::fail(NAME, format!("exec error: {e}")),
    }
}

/// ExecOneShot: a plain nonzero exit code propagates verbatim.
pub async fn exec_exit_code_propagation(
    t: &dyn GuestTransport,
    ep: &GuestEndpoint,
) -> FixtureResult {
    const NAME: &str = "exec-exit-code-propagation";
    let req = ExecRequest::new(&["/bin/bash", "-lc", "exit 42"]);
    match t.exec(ep, req).await {
        Ok(out) if out.exit_code == 42 => FixtureResult::pass(NAME),
        Ok(out) => FixtureResult::fail(NAME, format!("exit={} (wanted 42)", out.exit_code)),
        Err(e) => FixtureResult::fail(NAME, format!("exec error: {e}")),
    }
}

/// ExecOneShot: stdin bytes reach the guest process. Contract knowledge
/// this fixture codifies (caught live 2026-07-14): `ExecRequest::stdin`
/// lands on the guest child's PTY, which runs in CANONICAL (line-buffered)
/// mode — the tty releases input to the reader per NEWLINE. Payloads must
/// therefore be newline-terminated and consumers line-oriented (`head -n`);
/// a byte-count consumer (`head -c`) of an unterminated payload waits in
/// the tty line buffer forever. EOF delivery stays backend-dependent, so
/// the consumer must also exit after its line (never bare `cat`).
pub async fn exec_stdin_passthrough(t: &dyn GuestTransport, ep: &GuestEndpoint) -> FixtureResult {
    const NAME: &str = "exec-stdin-passthrough";
    const PAYLOAD: &str = "conformance-stdin-payload\n";
    let req = ExecRequest::new(&["/bin/bash", "-lc", "head -n 1 | tr a-z A-Z"])
        .with_stdin(PAYLOAD.as_bytes().to_vec());
    match t.exec(ep, req).await {
        Ok(out)
            if out.exit_code == 0 && out.stdout_text().contains("CONFORMANCE-STDIN-PAYLOAD") =>
        {
            FixtureResult::pass(NAME)
        }
        Ok(out) => FixtureResult::fail(
            NAME,
            format!(
                "exit={} stdout={:?} (wanted uppercased payload)",
                out.exit_code,
                out.stdout_text()
            ),
        ),
        Err(e) => FixtureResult::fail(NAME, format!("exec error: {e}")),
    }
}

/// ExecOneShot streaming: output separated by a genuine pause MUST arrive
/// incrementally (>= 2 chunk deliveries), and the concatenation carries
/// both markers. This is the primitive-level pin for the "silent long
/// operation looks like a dead wire" defect class (order 332).
pub async fn exec_streaming_incremental_chunks(
    t: &dyn GuestTransport,
    ep: &GuestEndpoint,
) -> FixtureResult {
    const NAME: &str = "exec-streaming-incremental-chunks";
    let req = ExecRequest::new(&[
        "/bin/bash",
        "-lc",
        "echo chunk-one; sleep 1; echo chunk-two",
    ]);
    let mut deliveries: usize = 0;
    let mut combined: Vec<u8> = Vec::new();
    let mut on_chunk = |c: ExecChunk| match c {
        ExecChunk::Stdout(b) | ExecChunk::Stderr(b) => {
            deliveries += 1;
            combined.extend_from_slice(&b);
        }
    };
    match t.exec_streaming(ep, req, &mut on_chunk).await {
        Ok(out) => {
            let text = String::from_utf8_lossy(&combined);
            if out.exit_code != 0 {
                FixtureResult::fail(NAME, format!("exit={} (wanted 0)", out.exit_code))
            } else if !(text.contains("chunk-one") && text.contains("chunk-two")) {
                FixtureResult::fail(NAME, format!("combined chunks missing markers: {text:?}"))
            } else if deliveries < 2 {
                FixtureResult::fail(
                    NAME,
                    format!(
                        "only {deliveries} chunk delivery(ies) across a 1s output gap — streaming is buffering"
                    ),
                )
            } else {
                FixtureResult::pass(NAME)
            }
        }
        Err(e) => FixtureResult::fail(NAME, format!("exec_streaming error: {e}")),
    }
}

/// InteractiveStream: `open_stream` yields a raw byte stream on which the
/// shared control-wire exec protocol completes a full round-trip. This is
/// the same boxed-stream shape the tray's secure-channel wrap consumes.
pub async fn open_stream_exec_protocol_roundtrip(
    t: &dyn GuestTransport,
    ep: &GuestEndpoint,
) -> FixtureResult {
    const NAME: &str = "open-stream-exec-protocol-roundtrip";
    const MARKER: &str = "tillandsias-stream-fixture-ok";
    let stream = match t.open_stream(ep).await {
        Ok(s) => s,
        Err(e) => return FixtureResult::fail(NAME, format!("open_stream error: {e}")),
    };
    match crate::vsock_exec::exec_over_stream_with_input(
        stream,
        &["/bin/bash", "-lc", "echo tillandsias-stream-fixture-ok"],
        b"",
    )
    .await
    {
        Ok(out) if out.exit.code == 0 && String::from_utf8_lossy(&out.stdout).contains(MARKER) => {
            FixtureResult::pass(NAME)
        }
        Ok(out) => FixtureResult::fail(
            NAME,
            format!(
                "exit={:?} stdout={:?} (wanted exit 0 + marker)",
                out.exit,
                String::from_utf8_lossy(&out.stdout)
            ),
        ),
        Err(e) => FixtureResult::fail(NAME, format!("protocol round-trip error: {e}")),
    }
}

/// Per-fixture wall-clock budget. A conformance fixture that produces no
/// verdict inside this window IS a failing fixture (a hang is the worst
/// non-conformance); the budget guarantees the report always completes.
pub const FIXTURE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

async fn with_budget<F>(name: &'static str, fut: F) -> FixtureResult
where
    F: std::future::Future<Output = FixtureResult>,
{
    match tokio::time::timeout(FIXTURE_TIMEOUT, fut).await {
        Ok(r) => r,
        Err(_) => FixtureResult::fail(
            name,
            format!(
                "no verdict within {}s — primitive hung (worst non-conformance)",
                FIXTURE_TIMEOUT.as_secs()
            ),
        ),
    }
}

/// Run the full conformance set against one backend + endpoint, reporting
/// each fixture through `on_result` AS IT COMPLETES so live runners stream
/// progress instead of buffering the whole report (loud-floor rule). Every
/// fixture carries [`FIXTURE_TIMEOUT`]; a hang becomes a failing verdict,
/// never a silent stall. Fixtures run sequentially (each opens its own
/// connection); a failure does not short-circuit the rest.
pub async fn run_all_with_progress(
    t: &dyn GuestTransport,
    ep: &GuestEndpoint,
    on_result: &mut (dyn FnMut(&FixtureResult) + Send),
) -> Vec<FixtureResult> {
    // open_stream first: it splits "connect layer broken" from "exec
    // protocol broken" in the report ordering.
    let mut results: Vec<FixtureResult> = Vec::with_capacity(5);
    let mut push = |r: FixtureResult, results: &mut Vec<FixtureResult>| {
        on_result(&r);
        results.push(r);
    };
    push(
        with_budget(
            "open-stream-exec-protocol-roundtrip",
            open_stream_exec_protocol_roundtrip(t, ep),
        )
        .await,
        &mut results,
    );
    push(
        with_budget("exec-echo-roundtrip", exec_echo_roundtrip(t, ep)).await,
        &mut results,
    );
    push(
        with_budget(
            "exec-exit-code-propagation",
            exec_exit_code_propagation(t, ep),
        )
        .await,
        &mut results,
    );
    push(
        with_budget("exec-stdin-passthrough", exec_stdin_passthrough(t, ep)).await,
        &mut results,
    );
    push(
        with_budget(
            "exec-streaming-incremental-chunks",
            exec_streaming_incremental_chunks(t, ep),
        )
        .await,
        &mut results,
    );
    results
}

/// Run the full conformance set against one backend + endpoint.
pub async fn run_all(t: &dyn GuestTransport, ep: &GuestEndpoint) -> Vec<FixtureResult> {
    run_all_with_progress(t, ep, &mut |_r| {}).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io;
    use tillandsias_control_wire::guest_transport::ExecOutput;
    use tillandsias_control_wire::transport::AsyncReadWrite;

    /// Mock backend that emulates a conforming guest for the exec-path
    /// fixtures and (configurably) fails `open_stream`, pinning the harness
    /// logic itself without a VM. The real-protocol proof runs live via the
    /// per-platform runners.
    struct MockTransport {
        break_streaming_into_one_chunk: bool,
    }

    fn canned_exec(req: &ExecRequest) -> ExecOutput {
        assert_eq!(
            &req.argv[..2],
            &["/bin/bash".to_string(), "-lc".to_string()],
            "every fixture must use the guest-allowlisted wrapper shape"
        );
        let joined = req.argv.join(" ");
        if joined.contains("echo tillandsias-conformance-ping") {
            ExecOutput {
                stdout: b"tillandsias-conformance-ping\n".to_vec(),
                stderr: vec![],
                exit_code: 0,
            }
        } else if joined.contains("exit 42") {
            ExecOutput {
                stdout: vec![],
                stderr: vec![],
                exit_code: 42,
            }
        } else if joined.contains("head -n 1") {
            ExecOutput {
                stdout: b"CONFORMANCE-STDIN-PAYLOAD".to_vec(),
                stderr: vec![],
                exit_code: 0,
            }
        } else {
            ExecOutput {
                stdout: vec![],
                stderr: vec![],
                exit_code: 127,
            }
        }
    }

    #[async_trait::async_trait]
    impl GuestTransport for MockTransport {
        async fn open_stream(
            &self,
            _ep: &GuestEndpoint,
        ) -> io::Result<Box<dyn AsyncReadWrite + Unpin + Send>> {
            Err(io::Error::other("mock has no live guest"))
        }

        async fn exec(&self, _ep: &GuestEndpoint, req: ExecRequest) -> io::Result<ExecOutput> {
            Ok(canned_exec(&req))
        }

        async fn exec_streaming(
            &self,
            _ep: &GuestEndpoint,
            _req: ExecRequest,
            on_chunk: &mut (dyn FnMut(ExecChunk) + Send),
        ) -> io::Result<ExecOutput> {
            if self.break_streaming_into_one_chunk {
                on_chunk(ExecChunk::Stdout(b"chunk-one\nchunk-two\n".to_vec()));
            } else {
                on_chunk(ExecChunk::Stdout(b"chunk-one\n".to_vec()));
                on_chunk(ExecChunk::Stdout(b"chunk-two\n".to_vec()));
            }
            Ok(ExecOutput {
                stdout: b"chunk-one\nchunk-two\n".to_vec(),
                stderr: vec![],
                exit_code: 0,
            })
        }
    }

    fn ep() -> GuestEndpoint {
        GuestEndpoint::MacVz { port: 7777 }
    }

    #[tokio::test]
    async fn conforming_mock_passes_exec_fixtures_and_reports_stream_failure() {
        let t = MockTransport {
            break_streaming_into_one_chunk: false,
        };
        let results = run_all(&t, &ep()).await;
        assert_eq!(results.len(), 5);
        // open_stream runs FIRST (connect-layer vs protocol split) and is
        // broken in the mock — the harness must report it, not panic or
        // short-circuit; the four exec fixtures after it must still run.
        assert!(results[0].outcome.is_err());
        for r in &results[1..] {
            assert!(
                r.outcome.is_ok(),
                "{} unexpectedly failed: {:?}",
                r.name,
                r.outcome
            );
        }
        assert!(!all_passed(&results));
        let report = render_report(&results);
        assert!(report.contains("fixture exec-echo-roundtrip ok"));
        assert!(
            report.contains("transport-conformance: FAIL open-stream-exec-protocol-roundtrip"),
            "report grammar drifted: {report}"
        );
    }

    #[tokio::test]
    async fn buffered_streaming_fails_the_incremental_fixture() {
        let t = MockTransport {
            break_streaming_into_one_chunk: true,
        };
        let r = exec_streaming_incremental_chunks(&t, &ep()).await;
        let err = r
            .outcome
            .expect_err("single-chunk delivery must fail the fixture");
        assert!(
            err.contains("streaming is buffering"),
            "wrong diagnosis: {err}"
        );
    }

    #[tokio::test]
    async fn all_pass_report_grammar() {
        let results = vec![FixtureResult::pass("a"), FixtureResult::pass("b")];
        assert!(all_passed(&results));
        assert!(render_report(&results).ends_with("transport-conformance: PASS n=2\n"));
    }
}
