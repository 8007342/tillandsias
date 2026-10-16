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

/// WHICH QUESTION a failed handshake is asking. Order 1084-x8ya: every
/// `snow::Error` used to collapse into one `InvalidData` carrying `noise: {e}`,
/// so `secure control wire handshake failed: noise: input error` was the whole
/// diagnosis on both macOS (vsock) and Windows (hvsocket) — and the three
/// causes below want three different investigations.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HandshakeFailure {
    /// The peer sent nothing we can read as a Noise message. It is not a
    /// crypto disagreement: the peer may be speaking PLAINTEXT, may have
    /// written an explicit refusal (the guest's order-137 `Unauthorized`
    /// notice is plaintext and lands here), or may not be serving the wire.
    /// Ask what the peer is speaking — see [`HandshakeError::peer_frame`],
    /// which carries the bytes so a caller that knows the plaintext framing
    /// can decode and report the peer's own words.
    PeerSentNoUsableFrame,
    /// The peer spoke Noise and we disagreed cryptographically. With NNpsk0
    /// the PSK is mixed at the first message, so this is the version-bound
    /// PSK failing to match: compare `build_version`, `wire_version` and the
    /// secure-wire MODE on both ends.
    CryptoDisagreement,
    /// This end could not start or finish its own handshake. Nothing was
    /// learned about the peer.
    LocalMisconfiguration,
}

impl HandshakeFailure {
    /// Stable token for logs and assertions. The three MUST be distinguishable
    /// in the reported text — that is this type's whole reason to exist.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PeerSentNoUsableFrame => "peer-sent-no-usable-frame",
            Self::CryptoDisagreement => "crypto-disagreement",
            Self::LocalMisconfiguration => "local-misconfiguration",
        }
    }

    fn classify(e: &snow::Error) -> Self {
        match e {
            // Malformed/absent input: says nothing about crypto.
            snow::Error::Input => Self::PeerSentNoUsableFrame,
            // The peer's key material did not agree with ours.
            snow::Error::Decrypt | snow::Error::Dh => Self::CryptoDisagreement,
            // Pattern/Init/Prereq/State (and Kem under `hfs`) are all this
            // end's own setup. Matched as a catch-all deliberately: a new
            // snow variant must read as "our problem" rather than silently
            // becoming a claim about the peer.
            _ => Self::LocalMisconfiguration,
        }
    }

    fn guidance(self) -> &'static str {
        match self {
            Self::PeerSentNoUsableFrame => {
                "the peer sent no readable Noise frame — it may be speaking plaintext, \
                 refusing us, or not serving the control wire at all; if it wrote a \
                 plaintext refusal, decode peer_frame and report the peer's own message"
            }
            Self::CryptoDisagreement => {
                "either the version-bound PSK does not match (compare \
                 build_version, wire_version and the secure-wire mode on both \
                 ends) or the peer sent a PLAINTEXT refusal long enough to \
                 fail the AEAD check — decode peer_frame first and report the \
                 peer's own message if it parses"
            }
            Self::LocalMisconfiguration => "this end could not run the handshake",
        }
    }
}

/// A classified handshake failure. Carried INSIDE an `io::Error` so no shared
/// signature changes (`client_handshake`/`server_handshake` still return
/// `io::Result`, and the linux/windows callers of `Client::handshake` are
/// untouched); a caller that wants the classification downcasts:
///
/// ```ignore
/// if let Some(h) = err.get_ref().and_then(|e| e.downcast_ref::<HandshakeError>()) {
///     match h.failure { /* ... */ }
/// }
/// ```
#[derive(Debug)]
pub struct HandshakeError {
    /// Which question to ask next.
    pub failure: HandshakeFailure,
    /// `snow`'s own Display text, preserved verbatim so nothing is lost.
    pub snow: String,
    /// The bytes the peer actually sent, when a frame was read and rejected.
    /// `None` when we never got one (or when the failure was ours). This is
    /// what lets a caller recognise a plaintext refusal that Noise cannot
    /// parse — `tillandsias-secure-channel` deliberately does not depend on
    /// `tillandsias-control-wire`, so the decode belongs to the caller.
    pub peer_frame: Option<Vec<u8>>,
}

impl std::fmt::Display for HandshakeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // `noise: {snow}` is kept as a SUBSTRING so existing greps still hit,
        // but it is no longer the whole message.
        write!(
            f,
            "[{}] noise: {} — {}",
            self.failure.as_str(),
            self.snow,
            self.failure.guidance()
        )?;
        if let Some(frame) = &self.peer_frame {
            write!(f, " (peer sent {} byte(s))", frame.len())?;
        }
        Ok(())
    }
}

impl std::error::Error for HandshakeError {}

fn snow_err(e: snow::Error) -> io::Error {
    snow_err_with_frame(e, None)
}

fn snow_err_with_frame(e: snow::Error, peer_frame: Option<Vec<u8>>) -> io::Error {
    let failure = HandshakeFailure::classify(&e);
    // The io::ErrorKind now discriminates too, for callers that never
    // downcast: InvalidData was applied to every variant before.
    let kind = match failure {
        HandshakeFailure::PeerSentNoUsableFrame => io::ErrorKind::InvalidData,
        HandshakeFailure::CryptoDisagreement => io::ErrorKind::PermissionDenied,
        HandshakeFailure::LocalMisconfiguration => io::ErrorKind::Other,
    };
    io::Error::new(
        kind,
        HandshakeError {
            failure,
            snow: e.to_string(),
            peer_frame,
        },
    )
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
    // Order 1084-x8ya: keep the bytes. When the responder refuses us it writes
    // a PLAINTEXT notice (vsock_server.rs order-137 contract) that lands here
    // and cannot parse as Noise; without the frame the caller can only report
    // "input error" and the peer's actual message is lost.
    hs.read_message(&msg, &mut buf)
        .map_err(|e| snow_err_with_frame(e, Some(msg.clone())))?;

    let transport = hs.into_transport_mode().map_err(snow_err)?;
    Ok(EncryptedStream::new(stream, transport))
}

/// Run the NNpsk0 handshake as the **responder** (guest for the host hop;
/// container for the guest hop). Errors closed if the initiator's PSK (version)
/// does not match — `read_message` on the first frame fails the AEAD check.
pub async fn server_handshake<S>(stream: S, psk: &[u8; 32]) -> io::Result<EncryptedStream<S>>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    server_handshake_or_reclaim(stream, psk)
        .await
        .map_err(|(_, err)| err)
}

/// Like [`server_handshake`], but a FAILED handshake returns the stream
/// alongside the error instead of dropping it. Order 137
/// (vsock-exec-chain-authn-authz): the guest responder's cutover contract is
/// "send Error{code: Unauthorized} and close" — the rejection notice needs
/// the still-plaintext connection a by-value failure would otherwise destroy.
pub async fn server_handshake_or_reclaim<S>(
    mut stream: S,
    psk: &[u8; 32],
) -> Result<EncryptedStream<S>, (S, io::Error)>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let params = match NOISE_PARAMS.parse().map_err(snow_err) {
        Ok(params) => params,
        Err(err) => return Err((stream, err)),
    };
    let mut hs = match snow::Builder::new(params)
        .psk(0, psk)
        .build_responder()
        .map_err(snow_err)
    {
        Ok(hs) => hs,
        Err(err) => return Err((stream, err)),
    };

    let mut buf = vec![0u8; 65535];
    // <- e, psk
    let msg = match read_hs_frame(&mut stream).await {
        Ok(msg) => msg,
        Err(err) => return Err((stream, err)),
    };
    if let Err(err) = hs
        .read_message(&msg, &mut buf)
        .map_err(|e| snow_err_with_frame(e, Some(msg.clone())))
    {
        return Err((stream, err));
    }
    // -> e, ee
    let n = match hs.write_message(&[], &mut buf).map_err(snow_err) {
        Ok(n) => n,
        Err(err) => return Err((stream, err)),
    };
    if let Err(err) = write_hs_frame(&mut stream, &buf[..n]).await {
        return Err((stream, err));
    }

    let transport = match hs.into_transport_mode().map_err(snow_err) {
        Ok(transport) => transport,
        Err(err) => return Err((stream, err)),
    };
    Ok(EncryptedStream::new(stream, transport))
}

// ── Noise XX with pinned static keys (order 1506-32k5) ───────────────────────
//
// The fleet-messaging coordination channel (openspec/changes/fleet-messaging-poc
// design Decision 4). NNpsk0 above binds the key to the BUILD VERSION, which is
// right for the control channel and wrong for a channel that must survive a
// rollout; XX authenticates each end by a long-lived X25519 static key instead,
// and the caller decides whether that key is a peer. There is no PSK and no
// version binding here: protocol versioning is the caller's first in-tunnel
// frame.
//
// THE PROPERTY: the remote static key is handed to the caller's `verify`
// BEFORE the constructor returns a stream, so a caller cannot read a single
// transport byte from a peer it has not accepted. On the initiator `verify`
// runs after message 2 and BEFORE message 3 is written — a refused responder
// never learns the initiator's static key and never completes; on the
// responder it runs after message 3, before transport mode.

/// Handshake pattern for the fleet-messaging channel.
pub const NOISE_XX_PARAMS: &str = "Noise_XX_25519_ChaChaPoly_BLAKE2s";

/// Bytes in a fingerprint: BLAKE2s with a 16-byte digest (BLAKE2s-128, a
/// distinct parameterisation, NOT a truncated BLAKE2s-256).
pub const STATIC_FINGERPRINT_BYTES: usize = 16;

/// Lowercase hex of `bytes`.
pub fn hex_lower(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
}

/// Parse exactly 32 bytes of LOWERCASE hex (the one canonical spelling, so a
/// key has one textual form and a fingerprint compare is a string compare).
pub fn parse_static_hex(s: &str) -> Option<[u8; 32]> {
    let s = s.as_bytes();
    if s.len() != 64 {
        return None;
    }
    let nib = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None,
    };
    let mut out = [0u8; 32];
    for (i, pair) in s.chunks(2).enumerate() {
        out[i] = (nib(pair[0])? << 4) | nib(pair[1])?;
    }
    Some(out)
}

/// The fingerprint of a static public key: lowercase hex of BLAKE2s-128 over
/// the 32 raw key bytes. Shown in every refusal so the remedy (land the peer's
/// record) names the key it needs.
pub fn static_fingerprint(public: &[u8; 32]) -> String {
    use blake2::Blake2s;
    use blake2::digest::Digest;
    use blake2::digest::consts::U16;
    hex_lower(&Blake2s::<U16>::digest(public))
}

/// One X25519 static keypair. The private half is zeroized on drop and has no
/// `Debug`/`Display`; the public half is DERIVED from it, never trusted from a
/// stored copy.
pub struct StaticKeypair {
    private: zeroize::Zeroizing<[u8; 32]>,
    public: [u8; 32],
}

impl StaticKeypair {
    /// A fresh keypair from snow's resolver RNG (the OS CSPRNG).
    pub fn generate() -> io::Result<Self> {
        let params: snow::params::NoiseParams = NOISE_XX_PARAMS.parse().map_err(snow_err)?;
        let kp = snow::Builder::new(params)
            .generate_keypair()
            .map_err(snow_err)?;
        let mut private = zeroize::Zeroizing::new([0u8; 32]);
        if kp.private.len() != 32 {
            return Err(io::Error::other("x25519 private key is not 32 bytes"));
        }
        private.copy_from_slice(&kp.private);
        let mut raw = kp.private;
        zeroize::Zeroize::zeroize(&mut raw);
        Ok(Self::from_private(*private))
    }

    /// Rebuild a keypair from its private half (as Vault holds it).
    pub fn from_private(private: [u8; 32]) -> Self {
        let public =
            curve25519_dalek::montgomery::MontgomeryPoint::mul_base_clamped(private).to_bytes();
        Self {
            private: zeroize::Zeroizing::new(private),
            public,
        }
    }

    pub fn public(&self) -> &[u8; 32] {
        &self.public
    }

    /// The private half. Callers store it (Vault) and nothing else.
    pub fn private_bytes(&self) -> &[u8; 32] {
        &self.private
    }

    pub fn fingerprint(&self) -> String {
        static_fingerprint(&self.public)
    }
}

/// The caller's `verify` refused the remote static key. Carried inside an
/// `io::Error` of kind `PermissionDenied`; `Display` is exactly the caller's
/// refusal token (e.g. `refused:msg:unknown-peer:<fp>`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerRefused(pub String);

impl std::fmt::Display for PeerRefused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for PeerRefused {}

fn remote_static_of(hs: &snow::HandshakeState) -> io::Result<[u8; 32]> {
    hs.get_remote_static()
        .and_then(|k| <[u8; 32]>::try_from(k).ok())
        .ok_or_else(|| io::Error::other("noise xx: no 32-byte remote static after its message"))
}

fn refuse(reason: String) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, PeerRefused(reason))
}

/// Noise XX as the **initiator** (the dialing daemon). `verify` receives the
/// responder's static public key after message 2; an `Err(reason)` aborts
/// before message 3 is written and surfaces as [`PeerRefused`]`(reason)`.
pub async fn client_handshake_xx<S, F>(
    mut stream: S,
    local: &StaticKeypair,
    verify: F,
) -> io::Result<EncryptedStream<S>>
where
    S: AsyncRead + AsyncWrite + Unpin,
    F: FnOnce(&[u8; 32]) -> Result<(), String>,
{
    let params = NOISE_XX_PARAMS.parse().map_err(snow_err)?;
    let mut hs = snow::Builder::new(params)
        .local_private_key(local.private_bytes())
        .build_initiator()
        .map_err(snow_err)?;
    let mut buf = vec![0u8; 65535];
    // -> e
    let n = hs.write_message(&[], &mut buf).map_err(snow_err)?;
    write_hs_frame(&mut stream, &buf[..n]).await?;
    // <- e, ee, s, es
    let msg = read_hs_frame(&mut stream).await?;
    hs.read_message(&msg, &mut buf)
        .map_err(|e| snow_err_with_frame(e, Some(msg.clone())))?;
    verify(&remote_static_of(&hs)?).map_err(refuse)?;
    // -> s, se
    let n = hs.write_message(&[], &mut buf).map_err(snow_err)?;
    write_hs_frame(&mut stream, &buf[..n]).await?;
    let transport = hs.into_transport_mode().map_err(snow_err)?;
    Ok(EncryptedStream::new(stream, transport))
}

/// Noise XX as the **responder** (the listening daemon). `verify` receives
/// the initiator's static public key after message 3 and BEFORE transport
/// mode: on `Err(reason)` no stream is returned, so not one byte the
/// initiator sent after its handshake can be read through this constructor.
pub async fn server_handshake_xx<S, F>(
    mut stream: S,
    local: &StaticKeypair,
    verify: F,
) -> io::Result<EncryptedStream<S>>
where
    S: AsyncRead + AsyncWrite + Unpin,
    F: FnOnce(&[u8; 32]) -> Result<(), String>,
{
    let params = NOISE_XX_PARAMS.parse().map_err(snow_err)?;
    let mut hs = snow::Builder::new(params)
        .local_private_key(local.private_bytes())
        .build_responder()
        .map_err(snow_err)?;
    let mut buf = vec![0u8; 65535];
    // <- e
    let msg = read_hs_frame(&mut stream).await?;
    hs.read_message(&msg, &mut buf)
        .map_err(|e| snow_err_with_frame(e, Some(msg.clone())))?;
    // -> e, ee, s, es
    let n = hs.write_message(&[], &mut buf).map_err(snow_err)?;
    write_hs_frame(&mut stream, &buf[..n]).await?;
    // <- s, se
    let msg = read_hs_frame(&mut stream).await?;
    hs.read_message(&msg, &mut buf)
        .map_err(|e| snow_err_with_frame(e, Some(msg.clone())))?;
    verify(&remote_static_of(&hs)?).map_err(refuse)?;
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

impl<S> EncryptedStream<S> {
    /// The remote static public key of an XX session (`None` for NNpsk0,
    /// which has no static keys).
    pub fn remote_static(&self) -> Option<[u8; 32]> {
        self.transport
            .get_remote_static()
            .and_then(|k| <[u8; 32]>::try_from(k).ok())
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
    ///
    /// SCOPE LIMIT, ORDER 1084-x8ya — READ BEFORE EXTENDING THIS TEST. This
    /// fixture pairs client and server IN ONE PROCESS over an in-memory duplex,
    /// and it is handed a PSK. It therefore proves the handshake and the frame
    /// codec, and it says NOTHING about whether the two ends DERIVE the same
    /// key — a single process has exactly one `current_exe`, so it cannot
    /// express a cross-binary ikm mismatch by construction. That is why this
    /// test stayed green through a release in which the host↔guest handshake
    /// failed on every macOS and Windows install.
    ///
    /// **Do not try to close that gap by running this under `--release`.**
    /// Under `--release` a one-process test still hashes the same file for
    /// both ends and passes whether or not the keying is correct: a harness
    /// that guarantees the invariant it is checking. The derivation is covered
    /// by `host_derives_the_guests_key_from_the_guest_binary_not_its_own` in
    /// lib.rs with explicit byte strings; the only INTEGRATION proof is two
    /// distinct binaries — a release tray and the release guest reaching Ready.
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

    /// Failure-closed rejection (order 137): a peer that sends plaintext instead
    /// of a Noise handshake — i.e. an unauthenticated/legacy client, or a probe —
    /// is rejected; the responder never reaches a served state. This is the
    /// primitive-level guarantee behind `litmus:vsock-unauthenticated-peer-rejected`
    /// (the vsock-integration form lands with the coordinated cutover, slice 4).
    #[tokio::test]
    async fn plaintext_peer_is_rejected() {
        let (mut client, server) = tokio::io::duplex(64 * 1024);
        let k = psk("0.3.260701.1");
        let server_task = tokio::spawn(async move { server_handshake(server, &k).await });

        // A non-handshake peer: send a plausible-looking framed plaintext blob
        // (what an old plaintext-Hello client would send) instead of a Noise msg.
        client.write_all(&[0x00, 0x08]).await.unwrap();
        client.write_all(b"HELLOxxx").await.unwrap();
        client.flush().await.unwrap();

        let res = server_task.await.unwrap();
        assert!(
            res.is_err(),
            "the responder MUST reject a peer that does not complete the Noise handshake"
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

    // ─── order 1084-x8ya: the handshake failure must say WHICH failure ──────
    //
    // Pre-fix, every arm below reported the same `noise: …` string, so a host
    // seeing `secure control wire handshake failed: noise: input error` could
    // not tell "the guest is refusing me" from "the guest disagrees about the
    // PSK" from "I am misconfigured". These three assert the arms are reported
    // DIFFERENTLY, which is the closure criterion.

    /// Pull the classification back out of the `io::Error`.
    fn classified(err: &io::Error) -> &HandshakeError {
        err.get_ref()
            .and_then(|e| e.downcast_ref::<HandshakeError>())
            .expect("handshake errors must carry a HandshakeError")
    }

    /// ARM 1 — the peer writes a well-framed but non-Noise blob. This is the
    /// shape of the guest's order-137 plaintext `Unauthorized` refusal, and
    /// the bytes MUST survive so the caller can decode and quote the peer.
    #[tokio::test]
    async fn peer_plaintext_refusal_is_reported_as_peer_frame_not_bare_noise_error() {
        let (c, mut s) = tokio::io::duplex(64 * 1024);
        // Stand in for a ControlEnvelope: this crate cannot depend on
        // tillandsias-control-wire, which is exactly why the caller needs the
        // raw bytes rather than a decoded message.
        let notice = b"secure control wire required: the version-bound \
                       secure-channel handshake failed";
        let server = tokio::spawn(async move {
            let mut len = [0u8; 2];
            s.read_exact(&mut len).await.unwrap();
            let n = u16::from_be_bytes(len) as usize;
            let mut first = vec![0u8; n];
            s.read_exact(&mut first).await.unwrap();
            write_hs_frame(&mut s, notice).await.unwrap();
            // Hold the stream so the client's read cannot fail as EOF instead.
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        });

        // `expect_err` would need `EncryptedStream: Debug`; match instead.
        let err = match client_handshake(c, &psk("0.3.260701.1")).await {
            Ok(_) => panic!("a plaintext notice is not a Noise frame and must not handshake"),
            Err(e) => e,
        };
        let h = classified(&err);
        // MEASURED, and it is the reason `peer_frame` is not optional polish:
        // a plaintext refusal of this length is long enough to reach the AEAD
        // check, so snow reports Decrypt and the CLASSIFICATION ALONE is
        // indistinguishable from a genuine PSK mismatch. (Only a very short
        // blob reads as Input.) So the class cannot be the discriminator —
        // the bytes are. A caller that can decode the plaintext framing must
        // try `peer_frame` FIRST and report the peer's own words; only if it
        // does not decode is this really a crypto disagreement.
        assert_eq!(
            h.failure,
            HandshakeFailure::CryptoDisagreement,
            "measured behaviour: a full-length plaintext frame fails the AEAD \
             check; got {h}"
        );
        assert_eq!(
            h.peer_frame.as_deref(),
            Some(&notice[..]),
            "the peer's bytes MUST survive — without them the caller cannot \
             tell a REFUSAL from a PSK mismatch, and the guest's own message \
             is lost behind a generic noise error"
        );
        server.await.unwrap();
    }

    /// ARM 2 — a real Noise peer whose version-bound PSK differs. The
    /// RESPONDER is where NNpsk0 detects this (the PSK is mixed at the first
    /// message), so this is asserted on the server side.
    #[tokio::test]
    async fn wrong_psk_is_reported_as_crypto_disagreement() {
        let (c, s) = tokio::io::duplex(64 * 1024);
        let client = tokio::spawn(async move {
            // A DIFFERENT build_version ⇒ a different PSK (see
            // psk_differs_across_build_version in lib.rs).
            let _ = client_handshake(c, &psk("0.3.260630.1")).await;
        });

        let err = match server_handshake(s, &psk("0.3.260701.1")).await {
            Ok(_) => panic!("a mismatched PSK must not complete the handshake"),
            Err(e) => e,
        };
        let h = classified(&err);
        assert_eq!(
            h.failure,
            HandshakeFailure::CryptoDisagreement,
            "a PSK mismatch is a version/mode question, not 'the peer sent \
             nothing usable'; got {h}"
        );
        let _ = client.await;
    }

    /// ARM 3 — the arms must not read alike. This is the assertion the packet
    /// actually asks for: pre-fix both printed `noise: …` and nothing else.
    #[tokio::test]
    async fn the_three_failures_are_reported_differently() {
        let short = snow_err_with_frame(snow::Error::Input, Some(vec![0u8; 3]));
        let crypto = snow_err_with_frame(snow::Error::Decrypt, None);
        let local = snow_err_with_frame(
            snow::Error::Prereq(snow::error::Prerequisite::LocalPrivateKey),
            None,
        );

        let (a, b, c) = (short.to_string(), crypto.to_string(), local.to_string());
        assert_ne!(a, b, "short-frame and crypto failures must not read alike");
        assert_ne!(b, c, "crypto and local failures must not read alike");
        assert_ne!(a, c, "short-frame and local failures must not read alike");

        assert!(a.contains("peer-sent-no-usable-frame"), "got {a}");
        assert!(b.contains("crypto-disagreement"), "got {b}");
        assert!(c.contains("local-misconfiguration"), "got {c}");

        // snow's own words are preserved rather than replaced.
        assert!(a.contains("noise:"), "the original text must survive: {a}");

        // The ErrorKind discriminates too, for callers that never downcast.
        assert_eq!(short.kind(), io::ErrorKind::InvalidData);
        assert_eq!(crypto.kind(), io::ErrorKind::PermissionDenied);
    }

    // ── Noise XX with pinned static keys (order 1506-32k5) ──────────────────

    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A byte stream that counts what passes through it in each direction, and
    /// optionally keeps a copy of what was written (the replay arm's capture).
    struct Counting<S> {
        inner: S,
        read: Arc<AtomicUsize>,
        written: Arc<AtomicUsize>,
        tap: Option<Arc<std::sync::Mutex<Vec<u8>>>>,
    }

    type Counters = (Arc<AtomicUsize>, Arc<AtomicUsize>);

    impl<S> Counting<S> {
        fn new(inner: S) -> (Self, Counters) {
            let read = Arc::new(AtomicUsize::new(0));
            let written = Arc::new(AtomicUsize::new(0));
            (
                Self {
                    inner,
                    read: read.clone(),
                    written: written.clone(),
                    tap: None,
                },
                (read, written),
            )
        }
    }

    impl<S: AsyncRead + Unpin> AsyncRead for Counting<S> {
        fn poll_read(
            self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            let me = self.get_mut();
            let before = buf.filled().len();
            let r = Pin::new(&mut me.inner).poll_read(cx, buf);
            me.read
                .fetch_add(buf.filled().len() - before, Ordering::SeqCst);
            r
        }
    }

    impl<S: AsyncWrite + Unpin> AsyncWrite for Counting<S> {
        fn poll_write(
            self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            data: &[u8],
        ) -> Poll<io::Result<usize>> {
            let me = self.get_mut();
            let r = Pin::new(&mut me.inner).poll_write(cx, data);
            if let Poll::Ready(Ok(n)) = &r {
                me.written.fetch_add(*n, Ordering::SeqCst);
                if let Some(tap) = &me.tap {
                    tap.lock().unwrap().extend_from_slice(&data[..*n]);
                }
            }
            r
        }
        fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.get_mut().inner).poll_flush(cx)
        }
        fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
        }
    }

    fn pin_to(want: [u8; 32]) -> impl FnOnce(&[u8; 32]) -> Result<(), String> {
        move |got: &[u8; 32]| {
            if *got == want {
                Ok(())
            } else {
                Err(format!(
                    "refused:msg:unknown-peer:{}",
                    static_fingerprint(got)
                ))
            }
        }
    }

    fn refusal(err: &io::Error) -> Option<String> {
        err.get_ref()
            .and_then(|e| e.downcast_ref::<PeerRefused>())
            .map(|r| r.0.clone())
    }

    /// Two pinned statics complete XX and bytes flow through the tunnel.
    #[tokio::test]
    async fn xx_pinned_peers_complete_and_exchange_bytes() {
        let (a, b) = (
            StaticKeypair::generate().unwrap(),
            StaticKeypair::generate().unwrap(),
        );
        let (c, s) = tokio::io::duplex(64 * 1024);
        let (cr, sr) = tokio::join!(
            client_handshake_xx(c, &a, pin_to(*b.public())),
            server_handshake_xx(s, &b, pin_to(*a.public()))
        );
        let mut client = cr.expect("client xx");
        let mut server = sr.expect("server xx");
        client.write_all(b"proto: 1.0").await.unwrap();
        client.flush().await.unwrap();
        let mut got = [0u8; 10];
        server.read_exact(&mut got).await.unwrap();
        assert_eq!(&got, b"proto: 1.0");
    }

    /// THE PROPERTY (1506-32k5): a responder that refuses the initiator's
    /// static reads NOT ONE byte beyond the handshake — the initiator's
    /// pipelined transport bytes stay unread in the pipe. Mutation control:
    /// moving `verify` after `into_transport_mode` plus a first read turns
    /// this red (`read` exceeds the handshake bytes).
    #[tokio::test]
    async fn xx_unknown_initiator_is_refused_before_any_transport_byte_is_read() {
        let (a, b, stranger) = (
            StaticKeypair::generate().unwrap(),
            StaticKeypair::generate().unwrap(),
            StaticKeypair::generate().unwrap(),
        );
        let (c, s) = tokio::io::duplex(64 * 1024);
        let (c, (_, c_written)) = Counting::new(c);
        let (s, (s_read, _)) = Counting::new(s);
        let b_pub = *b.public();
        let client = async {
            let mut st = client_handshake_xx(c, &stranger, pin_to(b_pub))
                .await
                .expect("the initiator completes: it does not wait for a verdict");
            let handshake_bytes = c_written.load(Ordering::SeqCst);
            st.write_all(&[0x42u8; 4096]).await.unwrap();
            st.flush().await.unwrap();
            (handshake_bytes, st)
        };
        let ((handshake_bytes, _keep_open), sr) =
            tokio::join!(client, server_handshake_xx(s, &b, pin_to(*a.public())));
        let err = sr.err().expect("an unknown initiator MUST be refused");
        let why = refusal(&err).expect("the refusal is a PeerRefused");
        assert_eq!(
            why,
            format!(
                "refused:msg:unknown-peer:{}",
                static_fingerprint(stranger.public())
            )
        );
        assert_eq!(err.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(
            s_read.load(Ordering::SeqCst),
            handshake_bytes,
            "the responder read past the handshake from a peer it refused"
        );
    }

    /// The initiator pins too: a responder whose static is not the expected
    /// one is refused after message 2 and message 3 is never written, so the
    /// responder never completes and never learns the initiator's static.
    #[tokio::test]
    async fn xx_unknown_responder_is_refused_and_message_3_is_never_sent() {
        let (a, b, stranger) = (
            StaticKeypair::generate().unwrap(),
            StaticKeypair::generate().unwrap(),
            StaticKeypair::generate().unwrap(),
        );
        let (c, s) = tokio::io::duplex(64 * 1024);
        let server = async move {
            server_handshake_xx(s, &stranger, |_: &[u8; 32]| Ok(()))
                .await
                .map(|_| ())
        };
        let b_pub = *b.public();
        let client = async move {
            // Dropping the stream on return closes the pipe: the responder
            // sees EOF where message 3 should be.
            client_handshake_xx(c, &a, pin_to(b_pub)).await.map(|_| ())
        };
        let (cr, sr) = tokio::join!(client, server);
        let cerr = cr.expect_err("the initiator MUST refuse an unpinned responder");
        assert!(
            refusal(&cerr).is_some_and(|r| r.starts_with("refused:msg:unknown-peer:")),
            "got {cerr}"
        );
        assert!(
            sr.is_err(),
            "the responder must not complete without message 3"
        );
    }

    /// A captured initiator transcript replayed to a fresh responder fails:
    /// message 3 is encrypted under the ORIGINAL responder ephemeral, so the
    /// replay dies in the AEAD and `verify` is never consulted.
    #[tokio::test]
    async fn xx_replayed_initiator_handshake_is_refused() {
        let (a, b) = (
            StaticKeypair::generate().unwrap(),
            StaticKeypair::generate().unwrap(),
        );
        let tap = Arc::new(std::sync::Mutex::new(Vec::new()));
        let (c, s) = tokio::io::duplex(64 * 1024);
        let (mut c, _) = Counting::new(c);
        c.tap = Some(tap.clone());
        let (cr, sr) = tokio::join!(
            client_handshake_xx(c, &a, pin_to(*b.public())),
            server_handshake_xx(s, &b, pin_to(*a.public()))
        );
        assert!(cr.is_ok() && sr.is_ok(), "the original session completes");
        let captured = tap.lock().unwrap().clone();

        let (mut attacker, s2) = tokio::io::duplex(64 * 1024);
        let consulted = Arc::new(AtomicUsize::new(0));
        let seen = consulted.clone();
        let server = tokio::spawn(async move {
            server_handshake_xx(s2, &b, move |_: &[u8; 32]| {
                seen.fetch_add(1, Ordering::SeqCst);
                Ok(())
            })
            .await
            .map(|_| ())
        });
        attacker.write_all(&captured).await.unwrap();
        attacker.flush().await.unwrap();
        let res = server.await.unwrap();
        assert!(res.is_err(), "a replayed handshake MUST NOT complete");
        assert_eq!(
            consulted.load(Ordering::SeqCst),
            0,
            "verify ran on a replay"
        );
    }

    /// The public half is derived from the private half and agrees with what
    /// snow itself generated; the fingerprint is BLAKE2s-128 (a 16-byte
    /// digest parameterisation), not a truncated BLAKE2s-256.
    #[test]
    fn static_public_is_derived_and_fingerprint_is_blake2s_128() {
        let params: snow::params::NoiseParams = NOISE_XX_PARAMS.parse().unwrap();
        let kp = snow::Builder::new(params).generate_keypair().unwrap();
        let private: [u8; 32] = kp.private.as_slice().try_into().unwrap();
        let derived = StaticKeypair::from_private(private);
        assert_eq!(derived.public().as_slice(), kp.public.as_slice());

        let fp = derived.fingerprint();
        assert_eq!(fp.len(), STATIC_FINGERPRINT_BYTES * 2);
        assert_eq!(fp, static_fingerprint(derived.public()));
        use blake2::Digest as _;
        let truncated = hex_lower(&blake2::Blake2s256::digest(derived.public())[..16]);
        assert_ne!(fp, truncated, "BLAKE2s-128 is its own parameterisation");

        let hex = hex_lower(derived.public());
        assert_eq!(parse_static_hex(&hex), Some(*derived.public()));
        assert_eq!(parse_static_hex(&hex.to_uppercase()), None);
        assert_eq!(parse_static_hex("00"), None);
    }
}
