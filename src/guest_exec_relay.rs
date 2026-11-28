//! Order 1897-y7j2: run a guest command while the tray owns the VM.
//!
//! One VM can have one owner, so `--exec-guest` used to refuse whenever a tray
//! was running (order 277), and a read-only guest check meant quitting the
//! operator's tray. Now the tray listens on a Unix socket in a 0700 directory
//! of this user's `$TMPDIR` and carries each connection over a fresh
//! control-wire stream to the guest, exactly as [`crate::preview_relay`]
//! carries a browser's: the secure channel (vsock-transport) is the tray's own,
//! and the bytes inside it are the ordinary exec protocol, so the guest's
//! vsock-exec-authz allowlist decides what may run. Nothing here parses,
//! widens or narrows a request.
//!
//! The socket is the tray-host-control-socket's shape: 0600 in a 0700
//! directory owned by this user, a stale socket unlinked at start, and a peer
//! whose uid is not this process's is closed before any guest stream opens.
//!
//! @trace spec:tray-host-control-socket, spec:vsock-transport, spec:vsock-exec-authz

use std::future::Future;
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::UnixListener;

/// The relay socket: `<dir>/guest-exec.sock`, `dir` being [`socket_dir`].
pub(crate) fn socket_path_in(dir: &Path) -> PathBuf {
    dir.join("guest-exec.sock")
}

/// This user's `$TMPDIR/tillandsias` (macOS gives each user a private
/// `$TMPDIR`; the path stays well inside `sun_path`'s 104 bytes).
pub(crate) fn socket_dir() -> PathBuf {
    std::env::temp_dir().join("tillandsias")
}

/// Make `dir` a 0700 directory owned by this user, or refuse: a directory
/// someone else owns, or one others can enter, is never listened in.
pub(crate) fn prepare_dir(dir: &Path) -> io::Result<()> {
    match std::fs::create_dir(dir) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    let md = std::fs::symlink_metadata(dir)?;
    // SAFETY: getuid has no preconditions.
    let me = unsafe { libc::getuid() };
    if !md.is_dir() || md.uid() != me {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} is not a directory owned by uid {me}", dir.display()),
        ));
    }
    if md.mode() & 0o777 != 0o700 {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Bind the relay socket at `path`: a stale socket from a crashed tray is
/// unlinked first, and the new one is made 0600.
pub(crate) fn bind(path: &Path) -> io::Result<UnixListener> {
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

/// Listen for the life of the process, opening one guest stream per accepted
/// connection with `open`. A failure to listen is logged and leaves
/// `--exec-guest` refusing as before.
pub(crate) fn spawn<O, F, S>(open: O)
where
    O: Fn() -> F + Clone + Send + 'static,
    F: Future<Output = Result<S, String>> + Send,
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        let dir = socket_dir();
        let path = socket_path_in(&dir);
        match prepare_dir(&dir).and_then(|()| bind(&path)) {
            Ok(listener) => {
                eprintln!("[guest-exec-relay] listening on {}", path.display());
                // SAFETY: getuid has no preconditions.
                serve(listener, unsafe { libc::getuid() }, open).await;
            }
            Err(e) => eprintln!(
                "[guest-exec-relay] could not listen on {}: {e}; --exec-guest still needs the tray quit",
                path.display()
            ),
        }
    });
}

/// Remove the socket (tray quit). Best-effort: a leftover is unlinked by the
/// next tray's [`bind`].
pub(crate) fn remove() {
    let _ = std::fs::remove_file(socket_path_in(&socket_dir()));
}

/// Accept connections until the listener fails. A peer whose uid is not
/// `owner` is closed without opening a guest stream; every other connection
/// is relayed to its own stream from `open`.
pub(crate) async fn serve<O, F, S>(listener: UnixListener, owner: u32, open: O)
where
    O: Fn() -> F + Clone + Send + 'static,
    F: Future<Output = Result<S, String>> + Send,
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    loop {
        let (mut client, _) = match listener.accept().await {
            Ok(accepted) => accepted,
            Err(e) => {
                eprintln!("[guest-exec-relay] accept failed: {e}");
                return;
            }
        };
        match client.peer_cred() {
            Ok(cred) if cred.uid() == owner => {}
            Ok(cred) => {
                eprintln!(
                    "[guest-exec-relay] refused a peer with uid {} (owner {owner})",
                    cred.uid()
                );
                continue;
            }
            Err(e) => {
                eprintln!("[guest-exec-relay] refused a peer whose uid is unknown: {e}");
                continue;
            }
        }
        let open = open.clone();
        tokio::spawn(async move {
            match open().await {
                Ok(mut guest) => {
                    let _ = tokio::io::copy_bidirectional(&mut client, &mut guest).await;
                }
                Err(e) => eprintln!("[guest-exec-relay] guest stream unavailable: {e}"),
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn scratch() -> tempfile::TempDir {
        // A short root: sun_path is 104 bytes on macOS.
        tempfile::Builder::new()
            .prefix("gx")
            .tempdir_in("/tmp")
            .unwrap()
    }

    fn echo_open(
        count: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    ) -> impl Fn() -> std::pin::Pin<
        Box<dyn Future<Output = Result<tokio::io::DuplexStream, String>> + Send>,
    > + Clone
    + Send
    + 'static {
        move || {
            count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Box::pin(async move {
                let (host, mut guest) = tokio::io::duplex(1024);
                tokio::spawn(async move {
                    let mut buf = [0u8; 64];
                    while let Ok(n) = guest.read(&mut buf).await {
                        if n == 0 || guest.write_all(&buf[..n]).await.is_err() {
                            break;
                        }
                    }
                });
                Ok(host)
            })
        }
    }

    /// The directory is 0700 and the socket 0600, and a stale socket left by
    /// a crashed tray is replaced rather than failing the bind.
    #[tokio::test]
    async fn the_socket_is_private_and_a_stale_one_is_replaced() {
        let root = scratch();
        let dir = root.path().join("tillandsias");
        std::fs::create_dir(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        prepare_dir(&dir).unwrap();
        assert_eq!(std::fs::metadata(&dir).unwrap().mode() & 0o777, 0o700);
        let path = socket_path_in(&dir);
        drop(bind(&path).unwrap());
        assert!(path.exists(), "a dropped listener leaves its socket file");
        let _listener = bind(&path).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
    }

    /// A path that is not a directory is never listened in.
    #[test]
    fn a_non_directory_is_refused() {
        let root = scratch();
        let file = root.path().join("tillandsias");
        std::fs::write(&file, b"").unwrap();
        assert!(prepare_dir(&file).is_err());
    }

    /// Each connection from this user gets its own guest stream, and bytes
    /// travel both ways.
    #[tokio::test]
    async fn each_connection_is_relayed_to_its_own_guest_stream() {
        let root = scratch();
        let path = socket_path_in(root.path());
        let listener = bind(&path).unwrap();
        let opened = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        // SAFETY: getuid has no preconditions.
        let me = unsafe { libc::getuid() };
        tokio::spawn(serve(listener, me, echo_open(opened.clone())));
        for n in 0..2u8 {
            let mut c = tokio::net::UnixStream::connect(&path).await.unwrap();
            c.write_all(&[b'x', n]).await.unwrap();
            let mut back = [0u8; 2];
            tokio::time::timeout(Duration::from_secs(5), c.read_exact(&mut back))
                .await
                .expect("relayed in time")
                .unwrap();
            assert_eq!(back, [b'x', n]);
        }
        assert_eq!(opened.load(std::sync::atomic::Ordering::SeqCst), 2);
    }

    /// A peer that is not the owning user is closed and no guest stream is
    /// opened for it.
    #[tokio::test]
    async fn a_peer_of_another_uid_never_reaches_the_guest() {
        let root = scratch();
        let path = socket_path_in(root.path());
        let listener = bind(&path).unwrap();
        let opened = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        // SAFETY: getuid has no preconditions.
        let other = unsafe { libc::getuid() } + 1;
        tokio::spawn(serve(listener, other, echo_open(opened.clone())));
        let mut c = tokio::net::UnixStream::connect(&path).await.unwrap();
        let _ = c.write_all(b"x").await;
        let mut buf = [0u8; 1];
        let n = tokio::time::timeout(Duration::from_secs(5), c.read(&mut buf))
            .await
            .expect("closed in time")
            .unwrap_or(0);
        assert_eq!(n, 0);
        assert_eq!(opened.load(std::sync::atomic::Ordering::SeqCst), 0);
    }

    /// A guest stream that cannot be opened closes the client's connection
    /// instead of leaving it hanging.
    #[tokio::test]
    async fn an_unavailable_guest_closes_the_connection() {
        let root = scratch();
        let path = socket_path_in(root.path());
        let listener = bind(&path).unwrap();
        // SAFETY: getuid has no preconditions.
        let me = unsafe { libc::getuid() };
        tokio::spawn(serve(listener, me, || async {
            Err::<tokio::io::DuplexStream, _>("vsock connect: refused".to_string())
        }));
        let mut c = tokio::net::UnixStream::connect(&path).await.unwrap();
        let mut buf = [0u8; 1];
        let n = tokio::time::timeout(Duration::from_secs(5), c.read(&mut buf))
            .await
            .expect("closed in time")
            .unwrap_or(0);
        assert_eq!(n, 0);
    }
}
