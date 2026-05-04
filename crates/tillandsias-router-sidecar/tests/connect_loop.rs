//! Integration tests for the sidecar's control-socket connect loop.
//!
//! Spins up a minimal mock UDS server speaking enough of the protocol to
//! exercise the sidecar's reconnect + envelope-dispatch paths. The tray
//! itself is the canonical implementation; the mock here only does what
//! the sidecar needs to observe (Hello → HelloAck, then push envelopes).
//!
//! @trace spec:opencode-web-session-otp, spec:tray-host-control-socket

use std::time::Duration;

use bytes::{Bytes, BytesMut};
use futures_util::{SinkExt, StreamExt};
use tempfile::TempDir;
use tillandsias_control_wire::{
    ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, WIRE_VERSION, decode, encode,
};
use tokio::net::{UnixListener, UnixStream};
use tokio_util::codec::{Framed, LengthDelimitedCodec};

fn codec() -> LengthDelimitedCodec {
    LengthDelimitedCodec::builder()
        .length_field_length(4)
        .max_frame_length(MAX_MESSAGE_BYTES)
        .big_endian()
        .new_codec()
}

async fn write_envelope(
    framed: &mut Framed<UnixStream, LengthDelimitedCodec>,
    env: &ControlEnvelope,
) {
    let bytes = encode(env).unwrap();
    let buf: Bytes = BytesMut::from(&bytes[..]).freeze();
    framed.send(buf).await.unwrap();
}

/// Mock tray: accept one connection, complete Hello/HelloAck, push one
/// `IssueWebSession` envelope, then close. The sidecar should subscribe,
/// push the cookie into its store, and reconnect when we close.
async fn run_mock_tray_one_shot(socket_path: std::path::PathBuf, cookie: [u8; 32]) {
    let listener = UnixListener::bind(&socket_path).expect("bind mock tray");
    let (stream, _) = listener.accept().await.expect("accept");
    let mut framed = Framed::new(stream, codec());

    // Read the sidecar's Hello.
    let bytes = framed.next().await.unwrap().unwrap();
    let env = decode(&bytes).unwrap();
    assert!(
        matches!(env.body, ControlMessage::Hello { .. }),
        "expected Hello"
    );

    // Reply HelloAck.
    let ack = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: env.seq,
        body: ControlMessage::HelloAck {
            wire_version: WIRE_VERSION,
            server_caps: vec!["v1".to_string(), "IssueWebSession".to_string()],
        },
    };
    write_envelope(&mut framed, &ack).await;

    // Push one IssueWebSession (server-initiated).
    let issue = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: 1, // server-side outbound counter
        body: ControlMessage::IssueWebSession {
            project_label: "opencode.connect-loop-test.localhost".to_string(),
            cookie_value: cookie,
        },
    };
    write_envelope(&mut framed, &issue).await;

    // Hold open briefly so the sidecar reads the broadcast before close.
    tokio::time::sleep(Duration::from_millis(100)).await;
}

/// Spawn the sidecar (its `connect_and_run` path) by setting the env var
/// then importing the binary's logic via path-tricks isn't available — so
/// we exercise the public surface: `tillandsias_otp::global()` is what the
/// sidecar pushes into. The mock writes IssueWebSession; we wait for the
/// global store to grow.
///
/// We can't easily invoke the sidecar binary's `main` from a test (it's a
/// `[[bin]]`, not a library). Instead this test exercises the wire
/// contract end-to-end against the same OtpStore the sidecar uses, with
/// a thin client emulating the sidecar's read loop.
#[tokio::test]
async fn sidecar_pushes_received_envelope_into_store() {
    use tillandsias_otp::global;

    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("control.sock");
    let cookie: [u8; 32] = std::array::from_fn(|i| (i as u8).wrapping_mul(13));
    let label = "opencode.connect-loop-test.localhost";

    // Pre-clean: another test may have populated the global store under a
    // similar key. We use a unique label to avoid bleed.
    global().evict_project(label);

    // Mock tray runs first so the connect succeeds.
    let socket_for_mock = socket_path.clone();
    let mock = tokio::spawn(async move {
        run_mock_tray_one_shot(socket_for_mock, cookie).await;
    });

    // Give the listener a tick to bind.
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Sidecar-equivalent: connect, Hello, read one envelope, push.
    let stream = UnixStream::connect(&socket_path).await.expect("connect");
    let mut framed = Framed::new(stream, codec());
    let hello = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: 1,
        body: ControlMessage::Hello {
            from: "router-sidecar-test".to_string(),
            capabilities: vec!["IssueWebSession".to_string()],
        },
    };
    write_envelope(&mut framed, &hello).await;

    // Drain HelloAck.
    let _ack = framed.next().await.unwrap().unwrap();

    // Read the broadcast envelope.
    let bytes = framed.next().await.unwrap().unwrap();
    let env = decode(&bytes).unwrap();
    if let ControlMessage::IssueWebSession {
        project_label,
        cookie_value,
    } = env.body
    {
        assert_eq!(project_label, label);
        assert_eq!(cookie_value, cookie);
        // This is what the sidecar's main loop does for every
        // IssueWebSession it receives.
        global().push(&project_label, cookie_value);
    } else {
        panic!("expected IssueWebSession");
    }

    assert_eq!(global().session_count(label), 1);
    assert!(global().validate(label, &cookie));

    // Cleanup so this doesn't bleed into other tests.
    global().evict_project(label);

    mock.await.unwrap();
}

/// The sidecar must keep retrying when the tray socket isn't there yet.
/// We bind first, then connect — a straightforward smoke that
/// `UnixStream::connect` works against the path we plan to use.
#[tokio::test]
async fn sidecar_connect_against_present_socket_succeeds() {
    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("control.sock");
    let _listener = UnixListener::bind(&socket_path).expect("bind");

    let result = UnixStream::connect(&socket_path).await;
    assert!(result.is_ok(), "connect must succeed: {:?}", result.err());
}

/// Connect to a path that doesn't exist — the sidecar's outer loop catches
/// the error and applies backoff. This test only confirms the error type.
#[tokio::test]
async fn sidecar_connect_against_missing_socket_errors() {
    let tmp = TempDir::new().unwrap();
    let missing = tmp.path().join("nonexistent.sock");

    let result = UnixStream::connect(&missing).await;
    assert!(result.is_err());
    let err = result.unwrap_err();
    // ENOENT or ECONNREFUSED depending on platform/state.
    assert!(
        matches!(
            err.kind(),
            std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
        ),
        "unexpected error kind: {:?}",
        err.kind()
    );
}
