//! Order 1794-rf3a (b): the host browser's way to a guest preview.
//!
//! The guest's router publishes its preview listener inside the VM only:
//! rootful podman does not forward a `-p` publish into the `--internal`
//! enclave, and the VM's NAT never reaches this Mac's loopback. So the tray
//! listens on `127.0.0.1` at the port every preview URL names
//! ([`VM_HOST_PREVIEW_TLS_PORT`]) and carries each connection over vsock to
//! the guest's preview relay ([`PREVIEW_RELAY_VSOCK_PORT`]), which runs the
//! control wire's handshake and forwards the bytes to the router. The bytes are
//! the browser's own TLS session with the router, verified against the
//! preview CA; nothing here terminates or inspects it.
//!
//! Loopback ONLY, never `0.0.0.0` and never a LAN address: a preview is for
//! this Mac's own browser.
//!
//! @trace spec:local-web-preview, spec:vsock-transport

use std::future::Future;
use std::io;
use std::net::{Ipv4Addr, SocketAddr};

use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpListener;

pub(crate) use tillandsias_control_wire::transport::{
    PREVIEW_RELAY_VSOCK_PORT, VM_HOST_PREVIEW_TLS_PORT,
};

/// The listener's address: this Mac's loopback at `port`.
pub(crate) fn listen_addr(port: u16) -> SocketAddr {
    SocketAddr::from((Ipv4Addr::LOCALHOST, port))
}

/// Bind the loopback listener and serve it for the life of the process,
/// opening one guest relay stream per accepted connection with `open`. A bind
/// failure (the port is taken on this Mac) is logged and leaves previews
/// reachable from inside the guest only.
pub(crate) fn spawn<O, F, S>(open: O)
where
    O: Fn() -> F + Clone + Send + 'static,
    F: Future<Output = Result<S, String>> + Send,
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        let addr = listen_addr(VM_HOST_PREVIEW_TLS_PORT);
        match TcpListener::bind(addr).await {
            Ok(listener) => {
                eprintln!("[preview-relay] listening on {addr}");
                serve(listener, open).await;
            }
            Err(e) => eprintln!(
                "[preview-relay] could not listen on {addr}: {e}; previews are not reachable from this Mac's browser"
            ),
        }
    });
}

/// Accept connections until the listener fails, relaying each to a stream
/// from `open`. A connection whose guest stream cannot be opened is closed.
pub(crate) async fn serve<O, F, S>(listener: TcpListener, open: O)
where
    O: Fn() -> F + Clone + Send + 'static,
    F: Future<Output = Result<S, String>> + Send,
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    loop {
        let (mut browser, _) = match listener.accept().await {
            Ok(accepted) => accepted,
            Err(e) => {
                eprintln!("[preview-relay] accept failed: {e}");
                return;
            }
        };
        let open = open.clone();
        tokio::spawn(async move {
            match open().await {
                Ok(mut guest) => {
                    let _ = tokio::io::copy_bidirectional(&mut browser, &mut guest).await;
                }
                Err(e) => eprintln!("[preview-relay] guest relay unavailable: {e}"),
            }
        });
    }
}

/// Bind at an ephemeral loopback port (tests).
#[cfg(test)]
async fn bind_ephemeral() -> io::Result<TcpListener> {
    TcpListener::bind(listen_addr(0)).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// Negative control (order 1794-rf3a (b) pin): the listener is loopback
    /// only, never every interface or a LAN address.
    #[tokio::test]
    async fn the_preview_listener_binds_loopback_only() {
        assert_eq!(
            listen_addr(VM_HOST_PREVIEW_TLS_PORT),
            "127.0.0.1:18443".parse::<SocketAddr>().unwrap()
        );
        let listener = bind_ephemeral().await.unwrap();
        let bound = listener.local_addr().unwrap();
        assert!(bound.ip().is_loopback(), "{bound}");
        assert!(!bound.ip().is_unspecified(), "{bound}");
    }

    /// Each browser connection gets its own guest stream, and bytes travel
    /// both ways.
    #[tokio::test]
    async fn each_browser_connection_is_relayed_to_its_own_guest_stream() {
        let listener = bind_ephemeral().await.unwrap();
        let addr = listener.local_addr().unwrap();
        let opened = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let count = opened.clone();
        tokio::spawn(serve(listener, move || {
            count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            async move {
                let (host, mut guest) = tokio::io::duplex(1024);
                // The guest end echoes, standing in for relay + router.
                tokio::spawn(async move {
                    let mut buf = [0u8; 64];
                    while let Ok(n) = guest.read(&mut buf).await {
                        if n == 0 || guest.write_all(&buf[..n]).await.is_err() {
                            break;
                        }
                    }
                });
                Ok::<_, String>(host)
            }
        }));
        for n in 0..2u8 {
            let mut browser = tokio::net::TcpStream::connect(addr).await.unwrap();
            browser.write_all(&[b'g', n]).await.unwrap();
            let mut back = [0u8; 2];
            tokio::time::timeout(Duration::from_secs(5), browser.read_exact(&mut back))
                .await
                .expect("relayed in time")
                .unwrap();
            assert_eq!(back, [b'g', n]);
        }
        assert_eq!(opened.load(std::sync::atomic::Ordering::SeqCst), 2);
    }

    /// A guest relay that cannot be opened closes the browser's connection
    /// instead of leaving it hanging.
    #[tokio::test]
    async fn an_unavailable_guest_relay_closes_the_browser_connection() {
        let listener = bind_ephemeral().await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(serve(listener, || async {
            Err::<tokio::io::DuplexStream, _>("vsock connect: refused".to_string())
        }));
        let mut browser = tokio::net::TcpStream::connect(addr).await.unwrap();
        let mut buf = [0u8; 1];
        let n = tokio::time::timeout(Duration::from_secs(5), browser.read(&mut buf))
            .await
            .expect("closed in time")
            .unwrap_or(0);
        assert_eq!(n, 0);
    }
}
