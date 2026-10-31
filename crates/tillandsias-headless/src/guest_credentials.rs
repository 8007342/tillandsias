//! Order 1927-q6fk. The guest-local hand-off of the host's credential
//! delivery from the resident agent to the lane processes beside it.
//!
//! The host (Windows Credential Manager, the macOS keychain) delivers the
//! Vault unseal share and root token over the control wire into the MEMORY of
//! the resident in-guest agent (`run_vsock_listener`). Every forge lane is a
//! DIFFERENT process: on Windows `wsl.exe -d tillandsias -- tillandsias-headless
//! --cloud <p> --opencode`, on macOS a PTY child of the agent. Until 1909-aryk
//! those processes read the plaintext `fallback_vault-shamir-share-v1` file the
//! agent wrote; 1909-aryk removed the file (operator ruling: no plaintext
//! credentials at rest) and left the lanes with no source at all, so they fell
//! through to the Linux Secret Service over D-Bus — which a guest does not have
//! ("zbus error: ServiceUnknown ... not activatable"), reported as "keyring
//! locked".
//!
//! This module replaces the file with a socket: the agent answers on
//! [`SOCKET_PATH`] (tmpfs `/run`, directory 0700, socket 0600, peer uid must
//! equal the agent's own), and a lane asks it. Nothing is written to disk. A
//! lane that initialises or heals Vault pushes the new pair back, so the host's
//! next `GetVaultHandover` collects it into its secure storage.
//!
//! The wire is one request line and one reply line, all tokens whitespace-free:
//!   `get`                      -> `none` | `creds <share|-> <uuid|-> <token|->`
//!   `handover <share> <token>` -> `ok`
//!
//! @trace spec:tillandsias-vault, order:1927-q6fk

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use crate::vault_bootstrap::InVmCredentials;

/// Where the resident agent answers. `/run` is tmpfs in every guest.
pub(crate) const SOCKET_PATH: &str = "/run/tillandsias/guest-credentials.sock";

/// True in the process that serves the socket: it holds the delivery itself
/// and must never ask itself.
static SERVING: AtomicBool = AtomicBool::new(false);

pub(crate) fn is_serving() -> bool {
    SERVING.load(Ordering::SeqCst)
}

/// What a lane learned from the agent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum AgentAnswer {
    /// No agent socket, or it did not answer: the agent is not running (or is
    /// an older build). Treated exactly like "the host has not delivered".
    NoAgent(String),
    /// The agent is up but the host has not delivered anything yet.
    NotDelivered,
    /// The host's delivery, as the agent holds it.
    Delivered(WireCreds),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WireCreds {
    pub share: Option<String>,
    pub uuid: Option<String>,
    pub token: Option<String>,
}

impl WireCreds {
    pub(crate) fn into_in_vm(self) -> InVmCredentials {
        InVmCredentials {
            unseal_share_b64: self.share,
            installation_uuid: self.uuid.unwrap_or_default(),
            root_token: self.token,
        }
    }
}

fn field(v: Option<&str>) -> String {
    match v {
        Some(s) if !s.is_empty() && !s.chars().any(char::is_whitespace) => s.to_string(),
        _ => "-".to_string(),
    }
}

fn unfield(s: &str) -> Option<String> {
    (s != "-" && !s.is_empty()).then(|| s.to_string())
}

/// The reply line for `get`. Pure, so the encoding is tested without a socket.
pub(crate) fn encode_creds(creds: Option<&InVmCredentials>) -> String {
    match creds {
        None => "none".to_string(),
        Some(c) => format!(
            "creds {} {} {}",
            field(c.unseal_share_b64.as_deref()),
            field(Some(c.installation_uuid.as_str())),
            field(c.root_token.as_deref())
        ),
    }
}

pub(crate) fn decode_reply(line: &str) -> Result<AgentAnswer, String> {
    let mut it = line.split_whitespace();
    match it.next() {
        Some("none") => Ok(AgentAnswer::NotDelivered),
        Some("creds") => {
            let parts: Vec<&str> = it.collect();
            if parts.len() != 3 {
                return Err(format!("malformed creds reply ({} fields)", parts.len()));
            }
            Ok(AgentAnswer::Delivered(WireCreds {
                share: unfield(parts[0]),
                uuid: unfield(parts[1]),
                token: unfield(parts[2]),
            }))
        }
        other => Err(format!("unexpected reply {other:?}")),
    }
}

/// Answer one request line against the agent's state. `current` reads the
/// delivery; `stage` records a handover pushed by a lane. Pure over its
/// closures so the whole protocol is tested without the process globals.
pub(crate) fn answer(
    request: &str,
    current: impl FnOnce() -> Option<InVmCredentials>,
    stage: impl FnOnce(String, String),
) -> String {
    let mut it = request.split_whitespace();
    match it.next() {
        Some("get") => encode_creds(current().as_ref()),
        Some("handover") => match (it.next(), it.next()) {
            (Some(share), Some(token)) if share != "-" && token != "-" => {
                stage(share.to_string(), token.to_string());
                "ok".to_string()
            }
            _ => "error malformed handover".to_string(),
        },
        _ => "error unknown request".to_string(),
    }
}

fn peer_is_same_uid(stream: &UnixStream) -> bool {
    match nix::sys::socket::getsockopt(stream, nix::sys::socket::sockopt::PeerCredentials) {
        // SAFETY: geteuid has no preconditions.
        Ok(cred) => cred.uid() == unsafe { libc::geteuid() },
        Err(_) => false,
    }
}

fn serve_one(
    stream: UnixStream,
    current: &dyn Fn() -> Option<InVmCredentials>,
    stage: &dyn Fn(String, String),
) {
    if !peer_is_same_uid(&stream) {
        return;
    }
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    let mut line = String::new();
    if BufReader::new(&stream).read_line(&mut line).is_err() {
        return;
    }
    let reply = answer(line.trim(), current, stage);
    let mut w = &stream;
    let _ = writeln!(w, "{reply}");
}

/// Bind `path` (parent 0700, socket 0600) and serve on a background thread.
pub(crate) fn serve_at(
    path: &Path,
    current: impl Fn() -> Option<InVmCredentials> + Send + 'static,
    stage: impl Fn(String, String) + Send + 'static,
) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    std::thread::Builder::new()
        .name("guest-credentials".into())
        .spawn(move || {
            for stream in listener.incoming().flatten() {
                serve_one(stream, &current, &stage);
            }
        })?;
    Ok(())
}

/// The agent's production server over the process globals.
pub(crate) fn serve() -> std::io::Result<()> {
    SERVING.store(true, Ordering::SeqCst);
    serve_at(
        Path::new(SOCKET_PATH),
        crate::vault_bootstrap::delivered_credentials_snapshot,
        crate::vault_bootstrap::stage_handover_from_lane,
    )
}

fn round_trip(path: &Path, request: &str) -> Result<String, String> {
    let stream = UnixStream::connect(path).map_err(|e| format!("{}: {e}", path.display()))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|e| e.to_string())?;
    let mut w = &stream;
    writeln!(w, "{request}").map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(&stream)
        .read_line(&mut line)
        .map_err(|e| e.to_string())?;
    Ok(line.trim().to_string())
}

pub(crate) fn fetch_at(path: &Path) -> AgentAnswer {
    match round_trip(path, "get") {
        Ok(line) => decode_reply(&line).unwrap_or_else(AgentAnswer::NoAgent),
        Err(e) => AgentAnswer::NoAgent(e),
    }
}

pub(crate) fn fetch() -> AgentAnswer {
    fetch_at(Path::new(SOCKET_PATH))
}

pub(crate) fn push_handover_at(path: &Path, share: &str, token: &str) -> Result<(), String> {
    let req = format!("handover {} {}", field(Some(share)), field(Some(token)));
    match round_trip(path, &req)?.as_str() {
        "ok" => Ok(()),
        other => Err(format!("agent refused the handover: {other}")),
    }
}

pub(crate) fn push_handover(share: &str, token: &str) -> Result<(), String> {
    push_handover_at(Path::new(SOCKET_PATH), share, token)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn creds(share: Option<&str>, token: Option<&str>) -> InVmCredentials {
        InVmCredentials {
            unseal_share_b64: share.map(str::to_string),
            installation_uuid: "u-1".to_string(),
            root_token: token.map(str::to_string),
        }
    }

    #[test]
    fn encoding_round_trips_every_shape() {
        assert_eq!(
            decode_reply(&encode_creds(None)),
            Ok(AgentAnswer::NotDelivered)
        );
        let full = encode_creds(Some(&creds(Some("c2hhcmU="), Some("tok-x"))));
        assert_eq!(
            decode_reply(&full),
            Ok(AgentAnswer::Delivered(WireCreds {
                share: Some("c2hhcmU=".into()),
                uuid: Some("u-1".into()),
                token: Some("tok-x".into()),
            }))
        );
        // A delivery WITHOUT a share must stay distinguishable from no
        // delivery: it is the state the ruling answers with a wipe + re-login.
        let no_share = encode_creds(Some(&creds(None, None)));
        assert_eq!(
            decode_reply(&no_share),
            Ok(AgentAnswer::Delivered(WireCreds {
                share: None,
                uuid: Some("u-1".into()),
                token: None,
            }))
        );
    }

    #[test]
    fn a_malformed_handover_is_not_staged() {
        let mut staged = false;
        let r = answer("handover onlyone", || None, |_, _| staged = true);
        assert!(r.starts_with("error"), "{r}");
        assert!(!staged);
    }

    /// The lane gets what the agent holds, over a real socket, and a pushed
    /// handover reaches the agent's state. No file other than the socket.
    #[test]
    fn a_lane_reads_the_agents_delivery_and_pushes_a_handover_back() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("sub/guest-credentials.sock");
        let held: Arc<Mutex<Option<InVmCredentials>>> =
            Arc::new(Mutex::new(Some(creds(Some("c2hhcmU="), Some("tok-x")))));
        let staged: Arc<Mutex<Vec<(String, String)>>> = Arc::default();
        let (h, s) = (held.clone(), staged.clone());
        serve_at(
            &sock,
            move || h.lock().unwrap().clone(),
            move |a, b| s.lock().unwrap().push((a, b)),
        )
        .unwrap();
        let mode = std::fs::metadata(&sock).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        match fetch_at(&sock) {
            AgentAnswer::Delivered(c) => {
                assert_eq!(c.share.as_deref(), Some("c2hhcmU="));
                assert_eq!(c.token.as_deref(), Some("tok-x"));
            }
            other => panic!("expected the delivery, got {other:?}"),
        }
        push_handover_at(&sock, "bmV3", "tok-new").unwrap();
        assert_eq!(
            staged.lock().unwrap().as_slice(),
            &[("bmV3".to_string(), "tok-new".to_string())]
        );
        *held.lock().unwrap() = None;
        assert_eq!(fetch_at(&sock), AgentAnswer::NotDelivered);
        let files: Vec<_> = std::fs::read_dir(sock.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(
            files,
            vec![std::ffi::OsString::from("guest-credentials.sock")]
        );
    }

    #[test]
    fn no_agent_is_its_own_answer() {
        let dir = tempfile::tempdir().unwrap();
        assert!(matches!(
            fetch_at(&dir.path().join("absent.sock")),
            AgentAnswer::NoAgent(_)
        ));
    }
}
