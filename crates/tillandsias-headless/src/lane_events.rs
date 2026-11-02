//! 1956-4pxj slice 2 — push events from a project's git mirror to every live
//! forge of that project, over the forge's own MCP lane connection.
//!
//! Operator ruling 2026-11-01: two concurrent forges of one project "should
//! both go through the same git-mirror and get notified when the other one
//! has pushed changes". No polling anywhere:
//!
//! 1. The mirror's post-receive hook (images/git/post-receive-hook.sh) sends
//!    one datagram per updated ref to every listener socket in the project's
//!    push-event directory, which is mounted into the git container.
//! 2. Every host process that serves lane connections for the project binds
//!    one datagram socket there ([`listen_for_project`]) and blocks in recv.
//! 3. An event is written as an MCP `notifications/message` to every live
//!    lane connection of that project ([`register`]) except the pusher's,
//!    when the pusher can be named.
//!
//! The wire line from the hook is `push <ref> <old> <new> <pusher-addr>`.

use std::collections::HashMap;
use std::io::Write;
use std::os::unix::net::{UnixDatagram, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

/// A lane connection's writer, shared by its request loop and this module so
/// a pushed notification never interleaves with a response line.
pub(crate) type SharedWriter = Arc<Mutex<UnixStream>>;

struct Registered {
    id: u64,
    instance: String,
    writer: SharedWriter,
}

static CONNECTIONS: OnceLock<Mutex<HashMap<String, Vec<Registered>>>> = OnceLock::new();
static NEXT_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

fn connections() -> &'static Mutex<HashMap<String, Vec<Registered>>> {
    CONNECTIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Removes its connection from the registry when dropped.
pub(crate) struct Registration {
    project: String,
    id: u64,
}

impl Drop for Registration {
    fn drop(&mut self) {
        let mut map = connections().lock().unwrap_or_else(|p| p.into_inner());
        if let Some(list) = map.get_mut(&self.project) {
            list.retain(|r| r.id != self.id);
        }
    }
}

/// Register a live lane connection of `project` / `instance`.
pub(crate) fn register(project: &str, instance: &str, writer: SharedWriter) -> Registration {
    let id = NEXT_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    connections()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .entry(project.to_string())
        .or_default()
        .push(Registered {
            id,
            instance: instance.to_string(),
            writer,
        });
    Registration {
        project: project.to_string(),
        id,
    }
}

/// One ref update the mirror accepted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PushEvent {
    pub reference: String,
    pub old: String,
    pub new: String,
    /// The pushing peer's address as git-daemon saw it, when known.
    pub from: Option<String>,
}

/// Parse the hook's wire line. Anything else is ignored, never guessed at.
pub(crate) fn parse(line: &str) -> Option<PushEvent> {
    let mut f = line.split_whitespace();
    if f.next()? != "push" {
        return None;
    }
    let reference = f.next()?.to_string();
    let old = f.next()?.to_string();
    let new = f.next()?.to_string();
    let hex = |s: &str| !s.is_empty() && s.len() <= 64 && s.chars().all(|c| c.is_ascii_hexdigit());
    if !reference.starts_with("refs/") || !hex(&old) || !hex(&new) {
        return None;
    }
    let from = f
        .next()
        .filter(|s| !s.is_empty() && *s != "-")
        .map(str::to_string);
    Some(PushEvent {
        reference,
        old,
        new,
        from,
    })
}

fn short(sha: &str) -> &str {
    &sha[..sha.len().min(9)]
}

/// The MCP notification a forge receives for one event.
pub(crate) fn notification(event: &PushEvent, pusher: Option<&str>) -> serde_json::Value {
    let who = pusher.map_or_else(|| "another forge".to_string(), |i| format!("instance {i}"));
    serde_json::json!({
        "jsonrpc": "2.0",
        "method": "notifications/message",
        "params": {
            "level": "info",
            "logger": "tillandsias-git-mirror",
            "data": {
                "message": format!(
                    "{who} pushed {} {}→{}; fetch from the mirror to see it",
                    event.reference,
                    short(&event.old),
                    short(&event.new)
                ),
                "ref": event.reference,
                "old": event.old,
                "new": event.new,
                "pusher_instance": pusher,
            }
        }
    })
}

/// Write `event` to every live lane connection of `project` except the
/// pusher's instance. Returns how many connections it reached.
pub(crate) fn fan_out(project: &str, event: &PushEvent, pusher: Option<&str>) -> usize {
    let line = format!("{}\n", notification(event, pusher));
    let targets: Vec<SharedWriter> = {
        let map = connections().lock().unwrap_or_else(|p| p.into_inner());
        map.get(project)
            .map(|list| {
                list.iter()
                    .filter(|r| pusher != Some(r.instance.as_str()))
                    .map(|r| r.writer.clone())
                    .collect()
            })
            .unwrap_or_default()
    };
    let mut reached = 0;
    for w in targets {
        let mut stream = w.lock().unwrap_or_else(|p| p.into_inner());
        if stream.write_all(line.as_bytes()).is_ok() {
            reached += 1;
        }
    }
    reached
}

/// The host directory a project's push-event sockets live in. Mounted into
/// that project's git container at [`MIRROR_EVENT_DIR`].
pub(crate) fn event_dir(project: &str) -> PathBuf {
    crate::control_socket_host_dir()
        .join("push-events")
        .join(project)
}

/// Where the git container sees [`event_dir`].
pub(crate) const MIRROR_EVENT_DIR: &str = "/run/tillandsias/push-events";

/// Bind this process's listener for `project` once, and serve it on a
/// background thread for the life of the process. `pusher_of` names the
/// instance behind a peer address (the forge container's IP), or `None`.
pub(crate) fn listen_for_project(project: &str, pusher_of: fn(&str, &str) -> Option<String>) {
    static STARTED: OnceLock<Mutex<std::collections::HashSet<String>>> = OnceLock::new();
    let started = STARTED.get_or_init(|| Mutex::new(Default::default()));
    if !started
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .insert(project.to_string())
    {
        return;
    }
    let dir = event_dir(project);
    let Some(socket) = bind(&dir) else {
        return;
    };
    let project = project.to_string();
    std::thread::spawn(move || serve(&project, &socket, pusher_of));
}

fn bind(dir: &Path) -> Option<UnixDatagram> {
    std::fs::create_dir_all(dir).ok()?;
    let path = dir.join(format!("{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let socket = UnixDatagram::bind(&path).ok()?;
    // The git container's uid sends to it.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666));
    }
    Some(socket)
}

fn serve(project: &str, socket: &UnixDatagram, pusher_of: fn(&str, &str) -> Option<String>) {
    let mut buf = [0u8; 1024];
    while let Ok(n) = socket.recv(&mut buf) {
        let Ok(text) = std::str::from_utf8(&buf[..n]) else {
            continue;
        };
        for line in text.lines() {
            if let Some(event) = parse(line) {
                let pusher = event.from.as_deref().and_then(|a| pusher_of(project, a));
                fan_out(project, &event, pusher.as_deref());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};

    #[test]
    fn the_hook_line_parses_and_anything_else_is_ignored() {
        let e = parse("push refs/heads/x abc123 def456 10.89.0.7").expect("parses");
        assert_eq!(e.reference, "refs/heads/x");
        assert_eq!(e.from.as_deref(), Some("10.89.0.7"));
        assert_eq!(
            parse("push refs/heads/x abc def -").expect("no peer").from,
            None
        );
        assert_eq!(
            parse("push heads/x abc def"),
            None,
            "a ref outside refs/ is refused"
        );
        assert_eq!(
            parse("push refs/heads/x zz def"),
            None,
            "a non-hex sha is refused"
        );
        assert_eq!(parse("pull refs/heads/x abc def"), None);
    }

    /// A push from instance 2 reaches the default instance's connection as
    /// one MCP notification line, and not the pusher's own connection.
    #[test]
    fn a_push_reaches_every_other_forge_of_the_project_and_not_the_pusher() {
        let project = format!("lane-events-{}", std::process::id());
        let (a_host, a_forge) = UnixStream::pair().expect("pair a");
        let (b_host, b_forge) = UnixStream::pair().expect("pair b");
        let _ra = register(&project, "default", Arc::new(Mutex::new(a_host)));
        let rb = register(&project, "2", Arc::new(Mutex::new(b_host)));
        let event = parse("push refs/heads/feature 1111111111 2222222222 10.0.0.2").unwrap();

        assert_eq!(
            fan_out(&project, &event, Some("2")),
            1,
            "only the other forge"
        );
        let mut line = String::new();
        BufReader::new(&a_forge).read_line(&mut line).expect("read");
        let v: serde_json::Value = serde_json::from_str(&line).expect("one JSON line");
        assert_eq!(v["method"], "notifications/message");
        let msg = v["params"]["data"]["message"].as_str().unwrap_or("");
        assert!(
            msg.starts_with("instance 2 pushed refs/heads/feature 111111111→222222222"),
            "{msg}"
        );

        b_forge.set_nonblocking(true).unwrap();
        let mut probe = [0u8; 1];
        assert!(
            std::io::Read::read(&mut &b_forge, &mut probe).is_err(),
            "the pusher's own connection got nothing"
        );

        drop(rb);
        assert_eq!(
            fan_out(&project, &event, None),
            1,
            "a dropped connection is gone"
        );
    }

    /// End to end on the host side: a datagram in the project's event
    /// directory becomes a notification on a registered connection.
    #[test]
    fn a_datagram_from_the_mirror_becomes_a_notification() {
        let dir = std::env::temp_dir().join(format!("lane-events-dg-{}", std::process::id()));
        let socket = bind(&dir).expect("bind");
        let project = format!("lane-events-dg-{}", std::process::id());
        let (host, forge) = UnixStream::pair().expect("pair");
        let _r = register(&project, "default", Arc::new(Mutex::new(host)));
        fn nobody(_: &str, _: &str) -> Option<String> {
            None
        }
        let p = project.clone();
        std::thread::spawn(move || serve(&p, &socket, nobody));

        let sender = UnixDatagram::unbound().expect("sender");
        let target = dir.join(format!("{}.sock", std::process::id()));
        sender
            .send_to(b"push refs/heads/main aaaaaaa bbbbbbb -\n", &target)
            .expect("send");
        forge
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        let mut line = String::new();
        BufReader::new(forge)
            .read_line(&mut line)
            .expect("notification within 5 s");
        assert!(
            line.contains("another forge pushed refs/heads/main aaaaaaa→bbbbbbb"),
            "{line}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
