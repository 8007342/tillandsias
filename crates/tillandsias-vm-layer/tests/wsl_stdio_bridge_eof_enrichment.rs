//! Field fixture for order 620-cine: a bridge child that dies AFTER the 250 ms
//! startup grace must not collapse into a bare `early eof`.
//!
//! @trace spec:vsock-transport
//!
//! Why an `#[ignore]`d test rather than a unit test with a fake child: the
//! defect is entirely about REAL timing. July–August field logs on the N100
//! host carried hundreds of bare `handshake: early eof` lines, and the real
//! socat error surfaced only twice, when a race happened to catch the exit
//! inside the grace. A mock chooses its own timing and would prove nothing
//! about the window that actually matters.
//!
//! Measured on the Windows host 2026-08-12: `wsl.exe -d tillandsias -- socat
//! STDIO VSOCK-CONNECT:1:<dead port>` takes ~4.1 s to fail, i.e. ~16x the
//! grace. That is the condition the packet describes, and this drives the real
//! wsl.exe, the real socat and the real clock through it.
//!
//! Run explicitly (needs a Windows host with the `tillandsias` distro):
//!   cargo test -p tillandsias-vm-layer --test wsl_stdio_bridge_eof_enrichment \
//!       -- --ignored --nocapture

#![cfg(windows)]

use tokio::io::AsyncReadExt;

/// A vsock port nothing listens on. Any connect attempt is refused by the
/// guest, so socat exits non-zero — after the grace, which is the point.
const DEAD_PORT: u32 = 42999;

/// A failing bridge can report through EITHER of two doors, and which one it
/// takes is a race — that race IS the packet. When the child dies inside the
/// 250 ms startup grace, `open_wsl_stdio_bridge` returns the enriched error
/// itself; when it dies after (the common case on low-end hosts, and on any
/// host with a cold distro), the failure has to surface at EOF instead.
///
/// Both are correct. The defect is a bare EOF that names nothing, so assert
/// the PROPERTY — the cause is named — rather than the door it came through.
fn assert_names_the_cause(where_: &str, err: &str) {
    assert!(
        err.contains("exited"),
        "{where_}: must carry the child's exit, got: {err}"
    );
    assert!(
        err.contains("socat") || err.contains("connect"),
        "{where_}: must carry the child's captured stderr — an exit code alone is a \
         bare eof with extra words, got: {err}"
    );
}

#[tokio::test]
#[ignore = "field fixture: needs a Windows host with the tillandsias WSL distro"]
async fn eof_from_a_dead_child_names_the_real_cause() {
    let mut bridge =
        match tillandsias_vm_layer::transport_windows::open_wsl_stdio_bridge(DEAD_PORT).await {
            Ok(b) => b,
            Err(e) => {
                // Died inside the startup grace: the open path already named it.
                let err = e.to_string();
                eprintln!("[620-cine] enriched at OPEN (child died within the grace): {err}");
                assert_names_the_cause("open", &err);
                return;
            }
        };

    let started = std::time::Instant::now();
    let mut buf = [0u8; 1024];
    let outcome = bridge.read(&mut buf).await;
    let elapsed = started.elapsed();

    // The condition under test only exists past the startup grace. If the
    // child died inside it, this host is not reproducing the defect and the
    // assertion below would be measuring the OTHER code path — say so instead
    // of reporting a pass that means nothing.
    assert!(
        elapsed >= std::time::Duration::from_millis(250),
        "child died within the 250ms startup grace ({elapsed:?}) — this host is not \
         exercising the post-grace path this fixture exists for"
    );

    let err = match outcome {
        Ok(0) => panic!(
            "BARE EOF: the exact 620-cine defect — a dead non-zero child produced a clean \
             end-of-stream with no cause attached"
        ),
        Ok(n) => panic!("unexpected {n} bytes from a bridge whose connect was refused"),
        Err(e) => e.to_string(),
    };

    eprintln!("[620-cine] enriched at EOF after {elapsed:?}: {err}");
    assert_names_the_cause("eof", &err);
}

/// NEGATIVE CONTROL for the assertions above. They must not be satisfiable by
/// a bridge that simply always errors: pointed at the LIVE control-wire port,
/// the same call must connect and stay open rather than reporting a dead
/// child. Without this, an `open_wsl_stdio_bridge` that failed unconditionally
/// would make the fixture above pass while the transport was entirely broken.
#[tokio::test]
#[ignore = "field fixture: needs a Windows host with a PROVISIONED tillandsias guest"]
async fn a_live_port_does_not_report_a_dead_child() {
    const LIVE_PORT: u32 = 42420;
    let mut bridge = tillandsias_vm_layer::transport_windows::open_wsl_stdio_bridge(LIVE_PORT)
        .await
        .expect("bridge spawn");

    let mut buf = [0u8; 64];
    let outcome =
        tokio::time::timeout(std::time::Duration::from_secs(3), bridge.read(&mut buf)).await;

    match outcome {
        // Nothing to read from a wire nobody wrote to: the connection is open
        // and healthy, which is the state under test.
        Err(_elapsed) => {}
        Ok(Ok(_n)) => {}
        Ok(Err(e)) => panic!(
            "a live control-wire port must not report a dead bridge child — the enrichment \
             would then be firing on healthy connections too: {e}"
        ),
    }
}
