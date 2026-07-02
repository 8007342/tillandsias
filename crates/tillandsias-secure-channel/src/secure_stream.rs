//! `EncryptedStream<S>`: a Noise-tunnelled `AsyncRead + AsyncWrite` wrapper.
//!
//! Slice 3 of the encrypted-control-channel impl packet. Wraps any byte stream
//! (`S: AsyncRead + AsyncWrite`) — vsock for the host↔guest hop, or a
//! `podman exec` pipe / Unix socket / vsock-in-vsock for the guest↔container
//! hop — so the same primitive secures both hops. Everything layered above
//! (the `[u32 length][postcard ControlEnvelope]` framing in
//! `tillandsias-control-wire`) runs unchanged inside the tunnel.
//!
//! Handshake: `Noise_NNpsk0_25519_ChaChaPoly_BLAKE2s`. The PSK is the
//! version-bound key from [`crate::channel_psk`] — a peer without the exact
//! matching-version PSK cannot complete the handshake (failure-closed version
//! binding). Ephemeral X25519 gives forward secrecy; ChaCha20-Poly1305 AEADs
//! every transport frame. `snow`'s default-resolver keeps this pure-Rust
//! (RustCrypto), so it stays musl-static friendly.
//!
//! @trace plan/issues/encrypted-control-channel-impl-2026-07-01.md (slice 3)
//! @trace plan/issues/security-audit-zero-trust-2026-07-01.md (P0-1)

use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};

/// Noise handshake pattern for the control channel. NNpsk0 mixes the PSK at the
/// first message, so possession of the version-bound PSK IS the authentication.
const NOISE_PARAMS: &str = "Noise_NNpsk0_25519_ChaChaPoly_BLAKE2s";

/// Max plaintext bytes per Noise transport frame. A Noise message is capped at
/// 65535 bytes including the 16-byte AEAD tag; stay well under so a single
/// `write_message` never overflows.
const MAX_PLAINTEXT_CHUNK: usize = 16384;

/// Largest ciphertext frame we will read. `MAX_PLAINTEXT_CHUNK` + AEAD tag, with
/// headroom; a peer advertising more is rejected (a malformed/hostile frame).
const MAX_CIPHERTEXT_FRAME: usize = MAX_PLAINTEXT_CHUNK + 256;

fn snow_err(e: snow::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("noise: {e}"))
}

async fn write_hs_frame<S: AsyncWrite + Unpin>(stream: &mut S, msg: &[u8]) -> io::Result<()> {
    let len = u16::try_from(msg.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "handshake frame too large"))?;
    stream.write_all(&len.to_be_bytes()).await?;
    stream.write_all(msg).await?;
    stream.flush().await
}

async fn read_hs_frame<S: AsyncRead + Unpin>(stream: &mut S) -> io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 2];
    stream.read_exact(&mut len_buf).await?;
    let len = u16::from_be_bytes(len_buf) as usize;
    if len > MAX_CIPHERTEXT_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "handshake frame exceeds maximum",
        ));
    }
    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf).await?;
    Ok(buf)
}

/// Run the NNpsk0 handshake as the **initiator** (host tray toward guest; guest
/// toward container). Returns the encrypted stream on success, or an error —
/// notably if the peer's PSK (version) does not match, the AEAD tag on the
/// responder's reply fails and the handshake errors closed.
pub async fn client_handshake<S>(mut stream: S, psk: &[u8; 32]) -> io::Result<EncryptedStream<S>>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let params = NOISE_PARAMS.parse().map_err(snow_err)?;
    let mut hs = snow::Builder::new(params)
        .psk(0, psk)
        .build_initiator()
        .map_err(snow_err)?;

    let mut buf = vec![0u8; 65535];
    // -> e, psk
    let n = hs.write_message(&[], &mut buf).map_err(snow_err)?;
    write_hs_frame(&mut stream, &buf[..n]).await?;
    // <- e, ee
    let msg = read_hs_frame(&mut stream).await?;
    hs.read_message(&msg, &mut buf).map_err(snow_err)?;

    let transport = hs.into_transport_mode().map_err(snow_err)?;
    Ok(EncryptedStream::new(stream, transport))
}

/// Run the NNpsk0 handshake as the **responder** (guest for the host hop;
/// container for the guest hop). Errors closed if the initiator's PSK (version)
/// does not match — `read_message` on the first frame fails the AEAD check.
pub async fn server_handshake<S>(mut stream: S, psk: &[u8; 32]) -> io::Result<EncryptedStream<S>>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let params = NOISE_PARAMS.parse().map_err(snow_err)?;
    let mut hs = snow::Builder::new(params)
        .psk(0, psk)
        .build_responder()
        .map_err(snow_err)?;

    let mut buf = vec![0u8; 65535];
    // <- e, psk
    let msg = read_hs_frame(&mut stream).await?;
    hs.read_message(&msg, &mut buf).map_err(snow_err)?;
    // -> e, ee
    let n = hs.write_message(&[], &mut buf).map_err(snow_err)?;
    write_hs_frame(&mut stream, &buf[..n]).await?;

    let transport = hs.into_transport_mode().map_err(snow_err)?;
    Ok(EncryptedStream::new(stream, transport))
}

/// Read-side frame reassembly state.
enum ReadState {
    /// Accumulating the 2-byte big-endian ciphertext-frame length prefix.
    Len { buf: [u8; 2], filled: usize },
    /// Accumulating `need` ciphertext bytes into `buf`.
    Body {
        buf: Vec<u8>,
        filled: usize,
        need: usize,
    },
}

/// A Noise-encrypted duplex stream. Reads decrypt inbound frames; writes encrypt
/// outbound data into length-prefixed AEAD frames. Implements `AsyncRead` +
/// `AsyncWrite` so the control-wire codec sits on top unchanged.
pub struct EncryptedStream<S> {
    inner: S,
    transport: snow::TransportState,
    read_state: ReadState,
    /// Decrypted plaintext not yet handed to the caller.
    plaintext: Vec<u8>,
    plaintext_pos: usize,
    /// Framed ciphertext staged for writing to `inner` but not yet flushed.
    out_buf: Vec<u8>,
    out_pos: usize,
    /// Scratch buffer reused for AEAD open/seal.
    scratch: Vec<u8>,
}

impl<S> EncryptedStream<S> {
    fn new(inner: S, transport: snow::TransportState) -> Self {
        EncryptedStream {
            inner,
            transport,
            read_state: ReadState::Len {
                buf: [0u8; 2],
                filled: 0,
            },
            plaintext: Vec::new(),
            plaintext_pos: 0,
            out_buf: Vec::new(),
            out_pos: 0,
            scratch: vec![0u8; 65535],
        }
    }
}

impl<S: AsyncRead + AsyncWrite + Unpin> EncryptedStream<S> {
    /// Encrypt one plaintext chunk into a length-prefixed frame appended to
    /// `out_buf`. Returns the number of plaintext bytes consumed.
    fn seal_chunk(&mut self, data: &[u8]) -> io::Result<usize> {
        let take = data.len().min(MAX_PLAINTEXT_CHUNK);
        let n = self
            .transport
            .write_message(&data[..take], &mut self.scratch)
            .map_err(snow_err)?;
        let len = u16::try_from(n).map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidData, "ciphertext frame too large")
        })?;
        self.out_buf.extend_from_slice(&len.to_be_bytes());
        self.out_buf.extend_from_slice(&self.scratch[..n]);
        Ok(take)
    }

    /// Drive `out_buf[out_pos..]` toward the inner stream. Returns `Ready(Ok(()))`
    /// only when fully drained.
    fn flush_out(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        while self.out_pos < self.out_buf.len() {
            match Pin::new(&mut self.inner).poll_write(cx, &self.out_buf[self.out_pos..]) {
                Poll::Ready(Ok(0)) => {
                    return Poll::Ready(Err(io::Error::new(
                        io::ErrorKind::WriteZero,
                        "inner stream closed while flushing ciphertext",
                    )));
                }
                Poll::Ready(Ok(n)) => self.out_pos += n,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending => return Poll::Pending,
            }
        }
        self.out_buf.clear();
        self.out_pos = 0;
        Poll::Ready(Ok(()))
    }
}

impl<S: AsyncRead + AsyncWrite + Unpin> AsyncRead for EncryptedStream<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        out: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let me = self.get_mut();
        loop {
            // Hand out any buffered plaintext first.
            if me.plaintext_pos < me.plaintext.len() {
                let avail = &me.plaintext[me.plaintext_pos..];
                let n = avail.len().min(out.remaining());
                out.put_slice(&avail[..n]);
                me.plaintext_pos += n;
                if me.plaintext_pos == me.plaintext.len() {
                    me.plaintext.clear();
                    me.plaintext_pos = 0;
                }
                return Poll::Ready(Ok(()));
            }

            // Otherwise pull the next ciphertext frame from the inner stream.
            match &mut me.read_state {
                ReadState::Len { buf, filled } => {
                    let mut tmp = ReadBuf::new(&mut buf[*filled..]);
                    match Pin::new(&mut me.inner).poll_read(cx, &mut tmp) {
                        Poll::Ready(Ok(())) => {
                            let got = tmp.filled().len();
                            if got == 0 {
                                // Clean EOF only if we were at a frame boundary.
                                return if *filled == 0 {
                                    Poll::Ready(Ok(()))
                                } else {
                                    Poll::Ready(Err(io::Error::new(
                                        io::ErrorKind::UnexpectedEof,
                                        "eof mid length-prefix",
                                    )))
                                };
                            }
                            *filled += got;
                            if *filled == 2 {
                                let need = u16::from_be_bytes(*buf) as usize;
                                if need == 0 || need > MAX_CIPHERTEXT_FRAME {
                                    return Poll::Ready(Err(io::Error::new(
                                        io::ErrorKind::InvalidData,
                                        "ciphertext frame length out of range",
                                    )));
                                }
                                me.read_state = ReadState::Body {
                                    buf: vec![0u8; need],
                                    filled: 0,
                                    need,
                                };
                            }
                        }
                        Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                        Poll::Pending => return Poll::Pending,
                    }
                }
                ReadState::Body { buf, filled, need } => {
                    let mut tmp = ReadBuf::new(&mut buf[*filled..]);
                    match Pin::new(&mut me.inner).poll_read(cx, &mut tmp) {
                        Poll::Ready(Ok(())) => {
                            let got = tmp.filled().len();
                            if got == 0 {
                                return Poll::Ready(Err(io::Error::new(
                                    io::ErrorKind::UnexpectedEof,
                                    "eof mid ciphertext frame",
                                )));
                            }
                            *filled += got;
                            if *filled == *need {
                                // Full frame: decrypt into plaintext buffer.
                                let mut plain = vec![0u8; *need];
                                let n = me
                                    .transport
                                    .read_message(&buf[..*need], &mut plain)
                                    .map_err(snow_err)?;
                                plain.truncate(n);
                                me.plaintext = plain;
                                me.plaintext_pos = 0;
                                me.read_state = ReadState::Len {
                                    buf: [0u8; 2],
                                    filled: 0,
                                };
                                // Loop to hand out the freshly decrypted bytes.
                            }
                        }
                        Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                        Poll::Pending => return Poll::Pending,
                    }
                }
            }
        }
    }
}

impl<S: AsyncRead + AsyncWrite + Unpin> AsyncWrite for EncryptedStream<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        let me = self.get_mut();
        // Drain any staged ciphertext before sealing more, to bound memory.
        match me.flush_out(cx) {
            Poll::Ready(Ok(())) => {}
            Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
            Poll::Pending => return Poll::Pending,
        }
        if data.is_empty() {
            return Poll::Ready(Ok(0));
        }
        let consumed = match me.seal_chunk(data) {
            Ok(n) => n,
            Err(e) => return Poll::Ready(Err(e)),
        };
        // Best-effort flush of what we just staged; remainder drains on the next
        // poll_write/poll_flush. We've already accepted `consumed` plaintext.
        match me.flush_out(cx) {
            Poll::Ready(Ok(())) | Poll::Pending => Poll::Ready(Ok(consumed)),
            Poll::Ready(Err(e)) => Poll::Ready(Err(e)),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let me = self.get_mut();
        match me.flush_out(cx) {
            Poll::Ready(Ok(())) => Pin::new(&mut me.inner).poll_flush(cx),
            other => other,
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let me = self.get_mut();
        match me.flush_out(cx) {
            Poll::Ready(Ok(())) => Pin::new(&mut me.inner).poll_shutdown(cx),
            other => other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{HopId, derive_psk};

    const ROOT: &[u8] = b"test-release-root-secret";

    fn psk(version: &str) -> [u8; 32] {
        *derive_psk(ROOT, version, 2, HopId::HostGuest)
    }

    /// Round-trip: matching PSKs handshake, then bytes flow encrypted both ways.
    #[tokio::test]
    async fn round_trip_with_matching_psk() {
        let (c, s) = tokio::io::duplex(64 * 1024);
        let k = psk("0.3.260701.1");
        let (cr, sr) = tokio::join!(client_handshake(c, &k), server_handshake(s, &k));
        let mut client = cr.expect("client handshake");
        let mut server = sr.expect("server handshake");

        // client -> server
        client.write_all(b"hello over the wire").await.unwrap();
        client.flush().await.unwrap();
        let mut buf = [0u8; 19];
        server.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"hello over the wire");

        // server -> client
        server.write_all(b"ack").await.unwrap();
        server.flush().await.unwrap();
        let mut buf2 = [0u8; 3];
        client.read_exact(&mut buf2).await.unwrap();
        assert_eq!(&buf2, b"ack");
    }

    /// A message larger than one Noise frame round-trips across many frames.
    #[tokio::test]
    async fn round_trip_multi_frame() {
        let (c, s) = tokio::io::duplex(1024 * 1024);
        let k = psk("0.3.260701.1");
        let (cr, sr) = tokio::join!(client_handshake(c, &k), server_handshake(s, &k));
        let mut client = cr.unwrap();
        let mut server = sr.unwrap();

        let payload = vec![0xABu8; MAX_PLAINTEXT_CHUNK * 3 + 7];
        let writer = tokio::spawn(async move {
            client.write_all(&payload).await.unwrap();
            client.flush().await.unwrap();
            payload
        });
        let mut got = vec![0u8; MAX_PLAINTEXT_CHUNK * 3 + 7];
        server.read_exact(&mut got).await.unwrap();
        let sent = writer.await.unwrap();
        assert_eq!(got, sent);
    }

    /// The core version-binding guarantee at the handshake level: mismatched
    /// PSKs (different build versions) cannot complete the handshake.
    #[tokio::test]
    async fn mismatched_psk_handshake_fails() {
        let (c, s) = tokio::io::duplex(64 * 1024);
        let kc = psk("0.3.260701.1");
        let ks = psk("0.3.260630.1"); // different version -> different PSK
        let (cr, sr) = tokio::join!(client_handshake(c, &kc), server_handshake(s, &ks));
        assert!(
            cr.is_err() || sr.is_err(),
            "a version/PSK mismatch MUST fail the handshake closed"
        );
    }

    /// A flipped ciphertext byte makes the AEAD open fail (integrity). Proven at
    /// the Noise transport level with a raw in-memory handshake so no custom
    /// async transport is needed; `EncryptedStream` seals/opens with these exact
    /// transport states, so this is the guarantee it inherits.
    #[test]
    fn tampered_ciphertext_is_rejected() {
        let k = psk("0.3.260701.1");
        let params: snow::params::NoiseParams = NOISE_PARAMS.parse().unwrap();
        let mut ini = snow::Builder::new(params.clone())
            .psk(0, &k)
            .build_initiator()
            .unwrap();
        let mut res = snow::Builder::new(params)
            .psk(0, &k)
            .build_responder()
            .unwrap();

        let mut b1 = vec![0u8; 65535];
        let mut b2 = vec![0u8; 65535];
        // -> e, psk ; <- e, ee
        let n = ini.write_message(&[], &mut b1).unwrap();
        res.read_message(&b1[..n], &mut b2).unwrap();
        let n = res.write_message(&[], &mut b1).unwrap();
        ini.read_message(&b1[..n], &mut b2).unwrap();

        let mut ini_t = ini.into_transport_mode().unwrap();
        let mut res_t = res.into_transport_mode().unwrap();

        // Seal a message on the initiator side.
        let mut ct = vec![0u8; 65535];
        let clen = ini_t.write_message(b"secret payload", &mut ct).unwrap();

        // Untampered opens cleanly.
        let mut pt = vec![0u8; 65535];
        let plen = res_t.read_message(&ct[..clen], &mut pt).unwrap();
        assert_eq!(&pt[..plen], b"secret payload");

        // Flip one ciphertext byte: the AEAD open MUST fail.
        // (Re-handshake to reset the responder nonce; a fresh responder opens
        // the same frame, so tampering is the only difference.)
        let params2: snow::params::NoiseParams = NOISE_PARAMS.parse().unwrap();
        let mut ini2 = snow::Builder::new(params2.clone())
            .psk(0, &k)
            .build_initiator()
            .unwrap();
        let mut res2 = snow::Builder::new(params2)
            .psk(0, &k)
            .build_responder()
            .unwrap();
        let n = ini2.write_message(&[], &mut b1).unwrap();
        res2.read_message(&b1[..n], &mut b2).unwrap();
        let n = res2.write_message(&[], &mut b1).unwrap();
        ini2.read_message(&b1[..n], &mut b2).unwrap();
        let mut ini2_t = ini2.into_transport_mode().unwrap();
        let mut res2_t = res2.into_transport_mode().unwrap();

        let clen2 = ini2_t.write_message(b"secret payload", &mut ct).unwrap();
        ct[clen2 / 2] ^= 0xFF; // corrupt
        assert!(
            res2_t.read_message(&ct[..clen2], &mut pt).is_err(),
            "a tampered ciphertext frame MUST fail the AEAD integrity check"
        );
    }
}
