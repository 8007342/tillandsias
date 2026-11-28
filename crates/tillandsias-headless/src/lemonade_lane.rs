//! Guest half of the forge -> host Lemonade relay (order 2456-lrly).
//!
//! THE GUEST LISTENS, THE TRAY DIALS. The Windows tray opens outbound
//! connections to vsock `LEMONADE_RELAY_VSOCK_PORT` exactly as it opens the
//! control channel (no host listener, no HKLM, no admin). Each one runs the
//! control wire's handshake (`serve_preview_relay`'s shape), then PARKS here
//! until a forge opens a connection on its own lane. The two are paired: the
//! guest writes the lane preamble `LRLY1 <lane> <hex>\n`, then splices the
//! forge's raw HTTP bytes. The tray reads the preamble, checks it, and parses
//! the request with its one HTTP implementation. Nothing here parses HTTP.
//!
//! ONE FORWARDER PER FORGE, reachable only from that forge. On every forge
//! container `start` event (podman's event stream, not a poll) the guest:
//!   1. mints a fresh lane credential (memory only; a relaunch rotates it);
//!   2. binds a unix socket under /run/tillandsias/lemonade/<forge>/ (tmpfs,
//!      0700), which only this process accepts on;
//!   3. starts `tillandsias-lemonade-fwd-<forge>` with `--network
//!      container:<forge>`: socat on 127.0.0.1:13305 INSIDE the forge's own
//!      network namespace, relaying to that socket, which is mounted into this
//!      forwarder only.
//!
//! A sibling forge has its own loopback and never sees the socket, so it
//! cannot reach another forge's listener. The credential is held by neither
//! the forge nor the forwarder: this process attaches it at pairing time.
//! Forges address the relay as `http://127.0.0.1:13305` (already NO_PROXY).
//!
//! DORMANT until a tray has dialed: [`armed`] turns true on the first tray
//! connection that passes the handshake, which only a tray started with
//! `TILLANDSIAS_LEMONADE_RELAY=1` makes. Linux and macOS never dial, so they
//! never mint, bind or start anything.
//!
//! @trace order:2456-lrly, spec:vsock-transport

// The pure rules are exercised by tests on every build; only the listen-vsock
// unix runtime half calls them in production.
#![cfg_attr(not(all(feature = "listen-vsock", unix)), allow(dead_code))]

use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite};

/// Name prefix of the per-forge forwarder container.
pub(crate) const FORWARDER_PREFIX: &str = "tillandsias-lemonade-fwd-";
/// tmpfs root of the per-lane socket directories.
pub(crate) const LANE_ROOT: &str = "/run/tillandsias/lemonade";
/// Where a forwarder sees its lane directory.
const FORWARDER_MOUNT: &str = "/relay";
/// The port forges connect to, on their own loopback.
pub(crate) const FORGE_LOOPBACK_PORT: u16 = 13305;

static ARMED: AtomicBool = AtomicBool::new(false);

/// True once a tray has dialed the relay listener.
pub(crate) fn armed() -> bool {
    ARMED.load(Ordering::SeqCst)
}

/// Mark armed; true when this call made the transition.
pub(crate) fn arm() -> bool {
    !ARMED.swap(true, Ordering::SeqCst)
}

fn table() -> &'static Mutex<HashMap<String, [u8; 32]>> {
    static T: std::sync::OnceLock<Mutex<HashMap<String, [u8; 32]>>> = std::sync::OnceLock::new();
    T.get_or_init(|| Mutex::new(HashMap::new()))
}

fn random_token() -> [u8; 32] {
    let mut out = [0u8; 32];
    getrandom::fill(&mut out).expect("lemonade lane: the OS random source is available");
    out
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Mint (or rotate) the lane's credential. Called on every forge start.
pub(crate) fn mint(lane: &str) -> [u8; 32] {
    let token = random_token();
    table()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .insert(lane.to_string(), token);
    token
}

/// Forget a lane (forge stopped or removed).
pub(crate) fn revoke(lane: &str) {
    table()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .remove(lane);
}

pub(crate) fn current_token(lane: &str) -> Option<[u8; 32]> {
    table()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .get(lane)
        .copied()
}

/// The live lanes, for `LemonadeLanesReply`.
pub(crate) fn snapshot() -> Vec<tillandsias_control_wire::LemonadeLane> {
    let mut v: Vec<_> = table()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .iter()
        .map(|(lane, t)| tillandsias_control_wire::LemonadeLane {
            lane: lane.clone(),
            token_hex: hex(t),
        })
        .collect();
    v.sort_by(|a, b| a.lane.cmp(&b.lane));
    v
}

/// The line written to the tray before a forge's bytes.
pub(crate) fn preamble(lane: &str, token: &[u8; 32]) -> String {
    format!("LRLY1 {lane} {}\n", hex(token))
}

/// Whether a container name is a forge that gets a lane. Forwarders (whose
/// names also contain "-forge") are excluded, or each would get a lane.
pub(crate) fn is_forge_container(name: &str) -> bool {
    name.starts_with("tillandsias-")
        && name.contains("-forge")
        && !name.starts_with(FORWARDER_PREFIX)
        && name.len() <= 64
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

pub(crate) fn forwarder_name(forge: &str) -> String {
    format!("{FORWARDER_PREFIX}{forge}")
}

pub(crate) fn lane_dir(forge: &str) -> std::path::PathBuf {
    std::path::Path::new(LANE_ROOT).join(forge)
}

/// `podman run` args for one forge's forwarder.
///
/// `--network container:<forge>` puts the listener in the forge's own netns,
/// bound to 127.0.0.1, so no other container can reach it. No alias, no
/// published port, no vsock (so no custom seccomp: the default profile and
/// the full hardening envelope apply).
pub(crate) fn build_forwarder_args(image: &str, forge: &str, dir: &std::path::Path) -> Vec<String> {
    vec![
        "--detach".into(),
        "--replace".into(),
        "--rm".into(),
        "--name".into(),
        forwarder_name(forge),
        "--network".into(),
        format!("container:{forge}"),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--mount".into(),
        format!(
            "type=bind,source={},target={FORWARDER_MOUNT}",
            dir.display()
        ),
        "--entrypoint".into(),
        "socat".into(),
        image.into(),
        format!("TCP-LISTEN:{FORGE_LOOPBACK_PORT},bind=127.0.0.1,fork,reuseaddr"),
        format!("UNIX-CONNECT:{FORWARDER_MOUNT}/relay.sock"),
    ]
}

/// A stream that yields `preamble` and then `inner`'s bytes; writes go to
/// `inner`. What the tray reads is preamble + the forge's own bytes, untouched.
pub(crate) fn with_preamble<S>(
    preamble: String,
    inner: S,
) -> impl AsyncRead + AsyncWrite + Unpin + Send + 'static
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (r, w) = tokio::io::split(inner);
    tokio::io::join(std::io::Cursor::new(preamble.into_bytes()).chain(r), w)
}

/// What a container event means for the lane table.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum LaneEvent {
    Arm,
    Disarm,
    Ignore,
}

pub(crate) fn classify_event(action: &str, name: &str, armed: bool) -> LaneEvent {
    if !is_forge_container(name) {
        return LaneEvent::Ignore;
    }
    match action {
        "start" if armed => LaneEvent::Arm,
        "died" | "die" | "stop" | "remove" | "cleanup" => LaneEvent::Disarm,
        _ => LaneEvent::Ignore,
    }
}

#[cfg(all(feature = "listen-vsock", unix))]
pub(crate) use runtime::*;

/// The IO half: socket binding, pairing, and the forwarder container.
#[cfg(all(feature = "listen-vsock", unix))]
mod runtime {
    use super::*;
    use std::io;
    use tokio::sync::mpsc;

    pub(crate) struct Pending {
        lane: String,
        stream: tokio::net::UnixStream,
    }

    fn queue() -> &'static (
        mpsc::Sender<Pending>,
        tokio::sync::Mutex<mpsc::Receiver<Pending>>,
    ) {
        static Q: std::sync::OnceLock<(
            mpsc::Sender<Pending>,
            tokio::sync::Mutex<mpsc::Receiver<Pending>>,
        )> = std::sync::OnceLock::new();
        Q.get_or_init(|| {
            let (tx, rx) = mpsc::channel(64);
            (tx, tokio::sync::Mutex::new(rx))
        })
    }

    fn accept_tasks() -> &'static Mutex<HashMap<String, tokio::task::JoinHandle<()>>> {
        static A: std::sync::OnceLock<Mutex<HashMap<String, tokio::task::JoinHandle<()>>>> =
            std::sync::OnceLock::new();
        A.get_or_init(|| Mutex::new(HashMap::new()))
    }

    /// The relay listener's "upstream": the next forge connection on any live
    /// lane, carrying that lane's CURRENT preamble. Called once per tray
    /// connection after its handshake passed; the first call arms the guest.
    pub(crate) async fn next_forge_connection()
    -> io::Result<impl AsyncRead + AsyncWrite + Unpin + Send + 'static> {
        if arm() {
            eprintln!("[tillandsias] lemonade relay armed: a tray dialed; arming running forges");
            tokio::spawn(arm_running_forges());
        }
        loop {
            let next = queue().1.lock().await.recv().await;
            let Some(Pending { lane, stream }) = next else {
                return Err(io::Error::other("lemonade relay queue closed"));
            };
            // Rotated or revoked since the forge connected: drop, do not relay.
            let Some(token) = current_token(&lane) else {
                continue;
            };
            return Ok(with_preamble(preamble(&lane, &token), stream));
        }
    }

    async fn arm_running_forges() {
        let mut cmd = tillandsias_podman::podman_cmd();
        cmd.args(["ps", "--format", "{{.Names}}"]);
        let Ok(out) = cmd.output().await else {
            return;
        };
        for name in String::from_utf8_lossy(&out.stdout).lines() {
            if is_forge_container(name.trim()) {
                arm_lane(name.trim()).await;
            }
        }
    }

    /// Route one podman event (called from the events monitor).
    pub(crate) async fn on_container_event(action: &str, name: &str) {
        match classify_event(action, name, armed()) {
            LaneEvent::Arm => arm_lane(name).await,
            LaneEvent::Disarm => disarm_lane(name).await,
            LaneEvent::Ignore => {}
        }
    }

    async fn arm_lane(forge: &str) {
        use std::os::unix::fs::PermissionsExt;
        mint(forge);
        let dir = lane_dir(forge);
        if let Some(old) = accept_tasks()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(forge)
        {
            old.abort();
        }
        let sock = dir.join("relay.sock");
        let bound = std::fs::create_dir_all(&dir)
            .and_then(|()| std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)))
            .and_then(|()| {
                let _ = std::fs::remove_file(&sock);
                tokio::net::UnixListener::bind(&sock)
            });
        let listener = match bound {
            Ok(l) => l,
            Err(e) => {
                eprintln!("[tillandsias] lemonade lane {forge}: cannot bind its socket: {e}");
                revoke(forge);
                return;
            }
        };
        let lane = forge.to_string();
        let task = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let _ = queue()
                    .0
                    .send(Pending {
                        lane: lane.clone(),
                        stream,
                    })
                    .await;
            }
        });
        accept_tasks()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(forge.to_string(), task);
        let image = crate::versioned_image_tag("forge-base", crate::VERSION.trim());
        let args = build_forwarder_args(&image, forge, &dir);
        match tillandsias_podman::PodmanClient::new()
            .run_container_observed("lemonade-forwarder", &forwarder_name(forge), &args, false)
            .await
        {
            Ok(_) => eprintln!(
                "[tillandsias] lemonade lane armed for {forge}: 127.0.0.1:{FORGE_LOOPBACK_PORT} \
                 in its own netns, credential minted"
            ),
            Err(e) => eprintln!("[tillandsias] lemonade forwarder for {forge} failed: {e}"),
        }
    }

    async fn disarm_lane(forge: &str) {
        revoke(forge);
        if let Some(t) = accept_tasks()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(forge)
        {
            t.abort();
        }
        let _ = std::fs::remove_dir_all(lane_dir(forge));
        let _ = tillandsias_podman::PodmanClient::new()
            .remove_container(&forwarder_name(forge))
            .await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[test]
    fn forges_get_lanes_and_forwarders_do_not() {
        assert!(is_forge_container("tillandsias-doris-forge"));
        assert!(is_forge_container("tillandsias-doris-forge-w1"));
        assert!(!is_forge_container(&forwarder_name(
            "tillandsias-doris-forge"
        )));
        assert!(!is_forge_container("tillandsias-git-doris"));
        assert!(!is_forge_container("tillandsias-inference"));
        assert!(!is_forge_container("tillandsias-x-forge;rm"));
    }

    #[test]
    fn a_relaunch_rotates_the_credential_and_a_stop_revokes_it() {
        let lane = "tillandsias-rot-forge";
        let first = mint(lane);
        let second = mint(lane);
        assert_ne!(first, second, "every launch mints a fresh credential");
        assert_eq!(current_token(lane), Some(second));
        assert!(
            snapshot()
                .iter()
                .any(|l| l.lane == lane && l.token_hex == hex(&second))
        );
        revoke(lane);
        assert_eq!(current_token(lane), None);
        assert!(!snapshot().iter().any(|l| l.lane == lane));
    }

    #[test]
    fn the_forwarder_listens_only_on_the_forges_own_loopback() {
        let args = build_forwarder_args(
            "img:v1",
            "tillandsias-p-forge",
            std::path::Path::new("/run/tillandsias/lemonade/tillandsias-p-forge"),
        );
        let net = args.iter().position(|a| a == "--network").unwrap();
        assert_eq!(args[net + 1], "container:tillandsias-p-forge");
        assert!(!args.iter().any(|a| a == "--network-alias"), "{args:?}");
        assert!(!args.iter().any(|a| a.starts_with("-p") || a == "--publish"));
        assert!(args.contains(&"TCP-LISTEN:13305,bind=127.0.0.1,fork,reuseaddr".to_string()));
        assert!(args.contains(&"UNIX-CONNECT:/relay/relay.sock".to_string()));
        // No credential anywhere in the forwarder's argv or env.
        assert!(
            !args
                .iter()
                .any(|a| a.contains("LRLY1") || a.starts_with("--env"))
        );
        let mut argv = vec!["run".to_string()];
        argv.extend(args);
        tillandsias_podman::policy::validate_launch_argv(&argv)
            .expect("the forwarder carries the full hardening envelope");
    }

    #[test]
    fn container_events_arm_only_when_a_tray_has_dialed() {
        assert_eq!(
            classify_event("start", "tillandsias-p-forge", false),
            LaneEvent::Ignore
        );
        assert_eq!(
            classify_event("start", "tillandsias-p-forge", true),
            LaneEvent::Arm
        );
        assert_eq!(
            classify_event("died", "tillandsias-p-forge", false),
            LaneEvent::Disarm
        );
        assert_eq!(
            classify_event("start", "tillandsias-proxy", true),
            LaneEvent::Ignore
        );
        assert_eq!(
            classify_event("start", &forwarder_name("tillandsias-p-forge"), true),
            LaneEvent::Ignore
        );
    }

    #[tokio::test]
    async fn the_tray_reads_the_preamble_then_the_forges_bytes_untouched() {
        let (forge_side, relay_side) = tokio::io::duplex(4096);
        let token = [7u8; 32];
        let mut paired = with_preamble(preamble("tillandsias-p-forge", &token), relay_side);
        let mut forge = forge_side;
        forge
            .write_all(b"GET /api/v1/models HTTP/1.1\r\n\r\n")
            .await
            .unwrap();
        drop(forge);
        let mut got = Vec::new();
        paired.read_to_end(&mut got).await.unwrap();
        let text = String::from_utf8(got).unwrap();
        assert_eq!(
            text,
            format!(
                "LRLY1 tillandsias-p-forge {}\nGET /api/v1/models HTTP/1.1\r\n\r\n",
                "07".repeat(32)
            )
        );
    }
}
