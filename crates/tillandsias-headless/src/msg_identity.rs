// @trace order:1506-32k5, openspec/changes/fleet-messaging-poc/design.md (Decision 4)
// @trace openspec/changes/fleet-messaging-poc/specs/fleet-messaging/spec.md
// @trace openspec/changes/fleet-wan-rendezvous/design.md (Decision 6 — the same peer record)
//
// msg_identity — the fleet message bus's HOST IDENTITY and the pinned Noise
// XX session the LAN rung (1506-7tq4) will carry envelopes over.
//
//   * ONE X25519 static key per host, minted by `tillandsias --msg-serve
//     --mint [--rotate]` into `secret/fleet/msg/static` of the host's OWN
//     Vault (vault_bootstrap::VaultMsgStaticKeyStore). No forge policy grants
//     anything under secret/data/fleet/msg/ (images/vault/policies; the
//     host-resident tray policy's `secret/*` is the only grant).
//   * The public half is published as `plan/fleet/peers/<host>.yaml` by a
//     normal landing: the TREE is the trust root — whoever can land on
//     linux-next already defines the fleet. There is no fleet CA.
//   * A session is `Noise_XX_25519_ChaChaPoly_BLAKE2s`
//     (tillandsias_secure_channel::{client,server}_handshake_xx). The remote
//     static is looked up in the directory INSIDE the handshake, before a
//     stream exists, so an unknown key is `refused:msg:unknown-peer:<fp>` and
//     not one tunnel byte is read from it. mDNS never adds a peer.
//   * The first in-tunnel frame is the hello `{"proto":"1.0"}`; an unknown
//     MAJOR is `refused:msg:proto-major:<n>`. Keys are NOT version-bound.
//
// THE PEER RECORD (`plan/fleet/peers/<host>.yaml`). This packet writes
// `host`, `noise_pub` (64 lowercase hex), `noise_fp` (32 lowercase hex,
// BLAKE2s-128 of the 32 key bytes) and `minted`; `lan_hints` and `mesh_ip`
// are optional and read by later rungs. 1548-cii8 owns the full schema
// (announce_pub, ssh CA pubs, class_declared, substrate, admitted) and
// `tillandsias fleet peers check`; so a rewrite here MERGES — it replaces
// only the four noise fields and keeps every other key. FIELD-NAME CONFLICT,
// recorded rather than silently resolved: 1506-32k5's title and the
// fleet-messaging design/spec delta call the fingerprint `fp`; 1548-cii8 and
// fleet-wan-rendezvous Decision 6 call it `noise_fp`. This module writes and
// reads `noise_fp` (the schema owner's name, and unambiguous beside
// announce_pub); the mDNS TXT key stays `fp=` as the design names it.
//
// FIXTURE SEAMS. An explicit TILLANDSIAS_MSG_ROOT is a LEGITIMATE production
// setting (the store-root override), so "explicit root" does not separate a
// fixture from a real host; each seam is therefore judged on what it can do
// in a shipped binary:
//   TILLANDSIAS_MSG_KEY_FILE=<path>     (explicit root required) the static
//                                       key lives in a 0600 JSON file instead
//                                       of Vault, so no fixture touches a real
//                                       Vault. Acceptable in release: it is
//                                       opt-in by the host's own operator,
//                                       chooses only where THIS host's own
//                                       key is kept, prints `store:file:<p>`
//                                       on --mint, and cannot admit a peer —
//                                       every remote key still goes through
//                                       the directory lookup.
//   TILLANDSIAS_MSG_PROTO=<maj.min>     (explicit root required) the dialer's
//                                       hello claims this proto (the
//                                       proto-major arm). Acceptable in
//                                       release: it changes only what this
//                                       host CLAIMS after both ends are
//                                       authenticated, and the acceptor
//                                       refuses an unknown major.
//   TILLANDSIAS_MSG_LOOKUP_AFTER_READ=1 the acceptor admits any static, reads
//                                       the hello and the first envelope,
//                                       THEN looks the key up — the mutation
//                                       control that must turn the zero-bytes
//                                       arm red. It weakens authentication,
//                                       so it is COMPILED ONLY under
//                                       cfg(debug_assertions): the release
//                                       profile build.sh ships (`--release`)
//                                       has neither the code path nor the
//                                       env read, and
//                                       `lookup_after_read_is_compiled_out_of_release`
//                                       pins which build honours it. The
//                                       fixture drives the debug build.

use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde_yaml::{Mapping, Value};
use tillandsias_msg::store;
use tillandsias_secure_channel::{
    PeerRefused, StaticKeypair, client_handshake_xx, parse_static_hex, server_handshake_xx,
    static_fingerprint,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Where the static key lives in the host's own Vault (KV v2 logical path).
pub const MSG_STATIC_PATH: &str = "secret/fleet/msg/static";

/// The protocol this binary speaks in the first in-tunnel frame.
pub const PROTO: &str = "1.0";
pub const PROTO_MAJOR: u64 = 1;

/// Largest in-tunnel frame this rung accepts (an envelope is budgeted far
/// below this by tillandsias_msg::shape).
const MAX_FRAME: usize = 256 * 1024;

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// ── the static key and where it is stored ────────────────────────────────────

/// The host's static key as its store holds it.
pub struct StoredStatic {
    pub keypair: StaticKeypair,
    pub minted: String,
}

impl StoredStatic {
    pub fn fingerprint(&self) -> String {
        self.keypair.fingerprint()
    }
}

/// The record at [`MSG_STATIC_PATH`]: the private half (hex), and — for a
/// reader's convenience only — the public half, its fingerprint and the mint
/// time. On read the public half is DERIVED again and a record whose stored
/// copy disagrees is refused.
pub fn static_record(s: &StoredStatic) -> serde_json::Value {
    serde_json::json!({
        "private": hex(s.keypair.private_bytes()),
        "noise_pub": hex(s.keypair.public()),
        "noise_fp": s.fingerprint(),
        "minted": s.minted,
    })
}

pub fn parse_static_record(v: &serde_json::Value) -> Result<StoredStatic, String> {
    let private = v["private"]
        .as_str()
        .and_then(parse_static_hex)
        .ok_or("key-record-malformed:private")?;
    let keypair = StaticKeypair::from_private(private);
    if v["noise_pub"].as_str() != Some(hex(keypair.public()).as_str()) {
        return Err("key-record-inconsistent:noise_pub".into());
    }
    Ok(StoredStatic {
        keypair,
        minted: v["minted"].as_str().unwrap_or("").to_string(),
    })
}

/// Where the static key is kept. The production implementation is
/// `vault_bootstrap::VaultMsgStaticKeyStore`; [`FileKeyStore`] exists only
/// behind the explicit-root seam. Errors are REASON TOKENS, never a record.
pub trait MsgStaticKeyStore {
    /// `vault:secret/fleet/msg/static` or `file:<path>` — printed by --mint so
    /// a seam-backed key can never be mistaken for a Vault one.
    fn describe(&self) -> String;
    /// `Ok(None)` ONLY when the store answered that no key exists.
    fn read(&self) -> Result<Option<StoredStatic>, String>;
    /// Write and CONFIRM (read back, compare).
    fn write(&self, s: &StoredStatic) -> Result<(), String>;
}

/// The fixture seam's store: one 0600 JSON file.
pub struct FileKeyStore(pub PathBuf);

impl MsgStaticKeyStore for FileKeyStore {
    fn describe(&self) -> String {
        format!("file:{}", self.0.display())
    }

    fn read(&self) -> Result<Option<StoredStatic>, String> {
        match std::fs::read(&self.0) {
            Ok(bytes) => {
                let v: serde_json::Value =
                    serde_json::from_slice(&bytes).map_err(|_| "key-record-malformed:json")?;
                parse_static_record(&v).map(Some)
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(format!("key-file-unreadable:{}", e.kind())),
        }
    }

    fn write(&self, s: &StoredStatic) -> Result<(), String> {
        let value = static_record(s);
        let body = serde_json::to_vec(&value).map_err(|_| "key-record-encode")?;
        if let Some(dir) = self.0.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("key-dir:{}", e.kind()))?;
        }
        let tmp = self.0.with_extension("tmp");
        {
            use std::io::Write as _;
            let mut opts = std::fs::OpenOptions::new();
            opts.write(true).create(true).truncate(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt as _;
                opts.mode(0o600);
            }
            let mut f = opts
                .open(&tmp)
                .map_err(|e| format!("key-file-write:{}", e.kind()))?;
            f.write_all(&body)
                .and_then(|_| f.sync_all())
                .map_err(|e| format!("key-file-write:{}", e.kind()))?;
        }
        std::fs::rename(&tmp, &self.0).map_err(|e| format!("key-file-rename:{}", e.kind()))?;
        match self.read()? {
            Some(back) if static_record(&back) == value => Ok(()),
            _ => Err("write-not-confirmed:mismatch".into()),
        }
    }
}

/// Which store a run uses. The file seam needs BOTH an explicit
/// TILLANDSIAS_MSG_ROOT and TILLANDSIAS_MSG_KEY_FILE; anything else is Vault,
/// and a build without Vault has no store at all (refused, never a fallback).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyStoreChoice {
    File(PathBuf),
    Vault,
    Unavailable,
}

pub fn key_store_choice(
    explicit_root: bool,
    key_file: Option<&str>,
    vault_built: bool,
) -> KeyStoreChoice {
    match key_file.filter(|k| !k.is_empty()) {
        Some(k) if explicit_root => KeyStoreChoice::File(PathBuf::from(k)),
        _ if vault_built => KeyStoreChoice::Vault,
        _ => KeyStoreChoice::Unavailable,
    }
}

// ── the peer directory (plan/fleet/peers/) ───────────────────────────────────

/// One trusted peer: a record whose `host` names its file and whose
/// `noise_fp` hashes its `noise_pub`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Peer {
    pub host: String,
    pub noise_pub: [u8; 32],
    pub noise_fp: String,
}

/// The peers a checkout trusts. A record that fails a check is NOT trusted
/// (its key reads as unknown) and the reason is kept in `refusals`;
/// `tillandsias fleet peers check` (1548-cii8) is the loud form of the same
/// checks.
#[derive(Debug, Default)]
pub struct PeerDirectory {
    pub peers: Vec<Peer>,
    pub refusals: Vec<String>,
}

impl PeerDirectory {
    pub fn load(dir: &Path) -> Result<Self, String> {
        let rd = std::fs::read_dir(dir)
            .map_err(|e| format!("refused:msg:peers-dir:{}:{}", dir.display(), e.kind()))?;
        let mut files: Vec<PathBuf> = rd
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "yaml"))
            .collect();
        files.sort();
        let mut out = Self::default();
        for f in files {
            let stem = f
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();
            match parse_peer(&stem, &f) {
                Ok(p) => {
                    if let Some(other) = out.peers.iter().find(|q| q.noise_pub == p.noise_pub) {
                        out.refusals.push(format!(
                            "refused:msg:peer-record:{stem}:duplicate-key-of:{}",
                            other.host
                        ));
                    } else {
                        out.peers.push(p);
                    }
                }
                Err(why) => out
                    .refusals
                    .push(format!("refused:msg:peer-record:{stem}:{why}")),
            }
        }
        Ok(out)
    }

    pub fn lookup(&self, key: &[u8; 32]) -> Option<&Peer> {
        self.peers.iter().find(|p| &p.noise_pub == key)
    }

    /// The `verify` a handshake runs: a known key is admitted, anything else
    /// is `refused:msg:unknown-peer:<fp>`.
    pub fn admit(&self, key: &[u8; 32]) -> Result<Peer, String> {
        self.lookup(key)
            .cloned()
            .ok_or_else(|| format!("refused:msg:unknown-peer:{}", static_fingerprint(key)))
    }
}

fn parse_peer(stem: &str, f: &Path) -> Result<Peer, String> {
    if !store::valid_label(stem) {
        return Err("file-name-not-a-host-label".into());
    }
    let bytes = std::fs::read(f).map_err(|e| format!("unreadable:{}", e.kind()))?;
    let v: Value = serde_yaml::from_slice(&bytes).map_err(|_| "not-yaml".to_string())?;
    let field = |k: &str| -> Result<String, String> {
        v.get(k)
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| format!("missing:{k}"))
    };
    let host = field("host")?;
    if host != stem {
        return Err(format!("host-is-not-file-name:{host}"));
    }
    let pub_hex = field("noise_pub")?;
    let noise_pub = parse_static_hex(&pub_hex).ok_or("noise_pub-not-64-lowercase-hex")?;
    let noise_fp = field("noise_fp")?;
    if noise_fp != static_fingerprint(&noise_pub) {
        return Err("fp-mismatch".into());
    }
    Ok(Peer {
        host,
        noise_pub,
        noise_fp,
    })
}

pub fn peer_file(dir: &Path, host: &str) -> PathBuf {
    dir.join(format!("{host}.yaml"))
}

const PEER_FILE_HEADER: &str = "# Fleet peer record — see plan/fleet/peers/README.md. The noise_* fields are\n\
# written by `tillandsias --msg-serve --mint`; other fields are kept on rewrite.\n";

/// Write (or merge into) `<dir>/<host>.yaml`: the four noise fields are set,
/// every other key already in the file is kept (1548-cii8 extends this
/// record). Atomic: temp file then rename.
pub fn write_peer_file(dir: &Path, host: &str, s: &StoredStatic) -> Result<PathBuf, String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("peers-dir-create:{}", e.kind()))?;
    let path = peer_file(dir, host);
    let mut map = match std::fs::read(&path) {
        Ok(b) => match serde_yaml::from_slice::<Value>(&b) {
            Ok(Value::Mapping(m)) => m,
            _ => return Err(format!("peer-file-not-a-mapping:{}", path.display())),
        },
        Err(e) if e.kind() == io::ErrorKind::NotFound => Mapping::new(),
        Err(e) => return Err(format!("peer-file-unreadable:{}", e.kind())),
    };
    for (k, v) in [
        ("host", host.to_string()),
        ("noise_pub", hex(s.keypair.public())),
        ("noise_fp", s.fingerprint()),
        ("minted", s.minted.clone()),
    ] {
        map.insert(Value::from(k), Value::from(v));
    }
    let body = serde_yaml::to_string(&Value::Mapping(map)).map_err(|_| "peer-file-encode")?;
    let tmp = path.with_extension("yaml.tmp");
    std::fs::write(&tmp, format!("{PEER_FILE_HEADER}{body}"))
        .map_err(|e| format!("peer-file-write:{}", e.kind()))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("peer-file-rename:{}", e.kind()))?;
    Ok(path)
}

// ── --mint [--rotate] ────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MintOutcome {
    Minted {
        fp: String,
    },
    Rotated {
        old_fp: String,
        new_fp: String,
    },
    /// A key exists and --rotate was not given: nothing in the store changes.
    /// `peer_file_written` is true only when the record was ABSENT (a lost
    /// record is republished from the stored key, never re-keyed).
    Exists {
        fp: String,
        peer_file_written: bool,
    },
}

/// Mint (or rotate) the host's static key: the store write is confirmed
/// BEFORE the peer file is written, so a published key always has its private
/// half; a failed peer-file write is repaired by re-running without --rotate.
pub fn mint(
    keys: &dyn MsgStaticKeyStore,
    peers_dir: &Path,
    host: &str,
    rotate: bool,
    now: DateTime<Utc>,
) -> Result<(MintOutcome, Option<PathBuf>), String> {
    let existing = keys.read()?;
    if let Some(cur) = &existing
        && !rotate
    {
        let path = peer_file(peers_dir, host);
        let written = if path.exists() {
            None
        } else {
            Some(write_peer_file(peers_dir, host, cur)?)
        };
        return Ok((
            MintOutcome::Exists {
                fp: cur.fingerprint(),
                peer_file_written: written.is_some(),
            },
            written,
        ));
    }
    let fresh = StoredStatic {
        keypair: StaticKeypair::generate().map_err(|_| "keygen-failed")?,
        minted: store::fmt_ts(now),
    };
    keys.write(&fresh)?;
    let path = write_peer_file(peers_dir, host, &fresh)?;
    let outcome = match existing {
        Some(old) => MintOutcome::Rotated {
            old_fp: old.fingerprint(),
            new_fp: fresh.fingerprint(),
        },
        None => MintOutcome::Minted {
            fp: fresh.fingerprint(),
        },
    };
    Ok((outcome, Some(path)))
}

// ── the in-tunnel frames ─────────────────────────────────────────────────────

async fn write_frame<S: AsyncWrite + Unpin>(s: &mut S, body: &[u8]) -> io::Result<()> {
    let len = u32::try_from(body.len()).map_err(|_| io::Error::other("frame too large"))?;
    s.write_all(&len.to_be_bytes()).await?;
    s.write_all(body).await?;
    s.flush().await
}

/// Read one frame, adding every byte read to `counter` (the counting seam the
/// zero-bytes arm asserts on).
async fn read_frame<S: AsyncRead + Unpin>(s: &mut S, counter: &mut usize) -> io::Result<Vec<u8>> {
    let mut len = [0u8; 4];
    s.read_exact(&mut len).await?;
    *counter += 4;
    let n = u32::from_be_bytes(len) as usize;
    if n > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame exceeds maximum",
        ));
    }
    let mut buf = vec![0u8; n];
    s.read_exact(&mut buf).await?;
    *counter += n;
    Ok(buf)
}

/// The proto major of a hello frame, or the refusal naming why not.
pub fn hello_major(frame: &[u8]) -> Result<u64, String> {
    let v: serde_json::Value =
        serde_json::from_slice(frame).map_err(|_| "refused:msg:proto-malformed".to_string())?;
    let proto = v["proto"]
        .as_str()
        .ok_or_else(|| "refused:msg:proto-malformed".to_string())?;
    proto
        .split('.')
        .next()
        .and_then(|m| m.parse::<u64>().ok())
        .ok_or_else(|| "refused:msg:proto-malformed".to_string())
}

// ── one session each way (the LAN rung, 1506-7tq4, loops these) ─────────────

#[derive(Debug, Clone)]
pub struct SessionSeams {
    /// TILLANDSIAS_MSG_PROTO: the proto string the dialer's hello claims.
    pub proto: String,
    /// TILLANDSIAS_MSG_LOOKUP_AFTER_READ: the mutation control. The FIELD
    /// does not exist in a release build, so nothing can set it there.
    #[cfg(debug_assertions)]
    pub lookup_after_read: bool,
}

impl Default for SessionSeams {
    fn default() -> Self {
        Self {
            proto: PROTO.to_string(),
            #[cfg(debug_assertions)]
            lookup_after_read: false,
        }
    }
}

impl SessionSeams {
    /// Whether the acceptor runs the lookup-after-read MUTATION. The literal
    /// `false` in a release build: the authentication off-switch is not in
    /// any binary build.sh ships.
    #[cfg(debug_assertions)]
    fn late_lookup(&self) -> bool {
        self.lookup_after_read
    }
    #[cfg(not(debug_assertions))]
    fn late_lookup(&self) -> bool {
        false
    }
}

/// Whether this build honours TILLANDSIAS_MSG_LOOKUP_AFTER_READ at all
/// (debug builds only). Pinned by a test in both profiles.
pub const LOOKUP_AFTER_READ_COMPILED: bool = cfg!(debug_assertions);

/// What one accepted session ended as. `envelope_bytes_read` counts EVERY
/// plaintext byte read from the tunnel (hello included) — zero for any peer
/// refused at the handshake.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcceptReport {
    pub verdict: Result<Peer, String>,
    pub proto: Option<String>,
    pub envelope_bytes_read: usize,
}

impl AcceptReport {
    pub fn lines(&self) -> Vec<String> {
        let mut out = vec![match &self.verdict {
            Ok(p) => format!(
                "ok:msg:accept:peer={}:fp={}:proto={}",
                p.host,
                p.noise_fp,
                self.proto.as_deref().unwrap_or("-")
            ),
            Err(r) => r.clone(),
        }];
        out.push(format!("envelope_bytes_read={}", self.envelope_bytes_read));
        out
    }
}

fn refusal_of(e: &io::Error) -> Option<String> {
    e.get_ref()
        .and_then(|x| x.downcast_ref::<PeerRefused>())
        .map(|r| r.0.clone())
}

/// Accept ONE session on `stream`: XX with the directory lookup inside the
/// handshake, then the hello, then (for an admitted peer) one envelope frame,
/// whose bytes are counted and discarded — delivery is the LAN rung's.
pub async fn accept_session<S>(
    stream: S,
    local: &StaticKeypair,
    peers: &PeerDirectory,
    seams: &SessionSeams,
) -> AcceptReport
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut read = 0usize;
    let mut admitted: Option<Peer> = None;
    let late = seams.late_lookup();
    let hs = if late {
        // MUTATION CONTROL: admit anything now, look it up after reading.
        server_handshake_xx(stream, local, |_: &[u8; 32]| Ok(())).await
    } else {
        server_handshake_xx(stream, local, |k: &[u8; 32]| {
            admitted = Some(peers.admit(k)?);
            Ok(())
        })
        .await
    };
    let mut st = match hs {
        Ok(st) => st,
        Err(e) => {
            return AcceptReport {
                verdict: Err(refusal_of(&e).unwrap_or_else(|| format!("refused:msg:handshake:{e}"))),
                proto: None,
                envelope_bytes_read: read,
            };
        }
    };
    let hello = match read_frame(&mut st, &mut read).await {
        Ok(h) => h,
        Err(e) => {
            return AcceptReport {
                verdict: Err(format!("refused:msg:hello-unreadable:{}", e.kind())),
                proto: None,
                envelope_bytes_read: read,
            };
        }
    };
    let proto = serde_json::from_slice::<serde_json::Value>(&hello)
        .ok()
        .and_then(|v| v["proto"].as_str().map(str::to_string));
    let refuse = |why: String, read: usize, proto: Option<String>| AcceptReport {
        verdict: Err(why),
        proto,
        envelope_bytes_read: read,
    };
    match hello_major(&hello) {
        Ok(PROTO_MAJOR) => {}
        Ok(major) => {
            let why = format!("refused:msg:proto-major:{major}");
            let _ = write_frame(
                &mut st,
                serde_json::json!({ "refused": why }).to_string().as_bytes(),
            )
            .await;
            return refuse(why, read, proto);
        }
        Err(why) => {
            let _ = write_frame(
                &mut st,
                serde_json::json!({ "refused": why }).to_string().as_bytes(),
            )
            .await;
            return refuse(why, read, proto);
        }
    }
    if write_frame(
        &mut st,
        serde_json::json!({ "proto": PROTO }).to_string().as_bytes(),
    )
    .await
    .is_err()
    {
        return refuse("refused:msg:hello-reply-failed".into(), read, proto);
    }
    let envelope = read_frame(&mut st, &mut read).await;
    if late {
        let Some(remote) = st.remote_static() else {
            return refuse("refused:msg:no-remote-static".into(), read, proto);
        };
        match peers.admit(&remote) {
            Ok(p) => admitted = Some(p),
            Err(why) => return refuse(why, read, proto),
        }
    }
    if let Err(e) = envelope {
        return refuse(
            format!("refused:msg:envelope-unreadable:{}", e.kind()),
            read,
            proto,
        );
    }
    match admitted {
        Some(p) => AcceptReport {
            verdict: Ok(p),
            proto,
            envelope_bytes_read: read,
        },
        None => refuse("refused:msg:not-admitted".into(), read, proto),
    }
}

/// Dial ONE session: XX pinning the responder in the directory, the hello,
/// then — only after the peer answered the hello — one envelope frame.
/// Returns the line to print and whether the session succeeded.
pub async fn dial_session<S>(
    stream: S,
    local: &StaticKeypair,
    peers: &PeerDirectory,
    seams: &SessionSeams,
    envelope: &[u8],
) -> Result<String, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut admitted: Option<Peer> = None;
    let mut st = client_handshake_xx(stream, local, |k: &[u8; 32]| {
        admitted = Some(peers.admit(k)?);
        Ok(())
    })
    .await
    .map_err(|e| refusal_of(&e).unwrap_or_else(|| format!("refused:msg:handshake:{e}")))?;
    let peer = admitted.ok_or("refused:msg:not-admitted")?;
    write_frame(
        &mut st,
        serde_json::json!({ "proto": seams.proto })
            .to_string()
            .as_bytes(),
    )
    .await
    .map_err(|e| format!("refused:msg:hello-write:{}", e.kind()))?;
    let mut n = 0usize;
    let reply = match read_frame(&mut st, &mut n).await {
        Ok(r) => r,
        Err(_) => return Err(format!("refused:msg:peer-closed:{}", peer.host)),
    };
    let v: serde_json::Value = serde_json::from_slice(&reply).unwrap_or_default();
    if let Some(why) = v["refused"].as_str() {
        return Err(format!("refused:msg:peer-said:{why}"));
    }
    write_frame(&mut st, envelope)
        .await
        .map_err(|e| format!("refused:msg:envelope-write:{}", e.kind()))?;
    let _ = st.shutdown().await;
    Ok(format!(
        "ok:msg:dial:peer={}:fp={}:proto={}",
        peer.host,
        peer.noise_fp,
        v["proto"].as_str().unwrap_or("-")
    ))
}

// ── the CLI half (`tillandsias --msg-serve --mint|--accept-once|--dial-once`) ─

/// What run_cli parsed for an identity verb.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IdentityVerb {
    Mint { rotate: bool },
    AcceptOnce(String),
    DialOnce(String),
}

fn env_var(k: &str) -> Option<String> {
    std::env::var(k).ok().filter(|v| !v.is_empty())
}

/// The peers directory: `--peers`, else TILLANDSIAS_MSG_PEERS_DIR, else
/// `./plan/fleet/peers` when `./plan/fleet` exists (run from a checkout).
pub fn peers_dir(flag: Option<&str>) -> Result<PathBuf, String> {
    if let Some(d) = flag
        .map(str::to_string)
        .or_else(|| env_var("TILLANDSIAS_MSG_PEERS_DIR"))
    {
        return Ok(PathBuf::from(d));
    }
    let here = PathBuf::from("plan/fleet");
    if here.is_dir() {
        return Ok(here.join("peers"));
    }
    Err("refused:msg-serve:no-peers-dir".into())
}

fn open_key_store(debug: bool) -> Result<Box<dyn MsgStaticKeyStore>, String> {
    let explicit_root = env_var("TILLANDSIAS_MSG_ROOT").is_some();
    match key_store_choice(
        explicit_root,
        env_var("TILLANDSIAS_MSG_KEY_FILE").as_deref(),
        cfg!(feature = "vault"),
    ) {
        KeyStoreChoice::File(p) => Ok(Box::new(FileKeyStore(p))),
        #[cfg(feature = "vault")]
        KeyStoreChoice::Vault => Ok(Box::new(crate::vault_bootstrap::VaultMsgStaticKeyStore {
            debug,
        })),
        _ => {
            let _ = debug;
            Err("refused:msg:no-key-store:built-without-vault".into())
        }
    }
}

fn seams() -> SessionSeams {
    seams_from(env_var)
}

/// The session seams from an environment lookup. A release build never even
/// READS TILLANDSIAS_MSG_LOOKUP_AFTER_READ.
fn seams_from(get: impl Fn(&str) -> Option<String>) -> SessionSeams {
    let explicit_root = get("TILLANDSIAS_MSG_ROOT").is_some();
    let mut s = SessionSeams::default();
    if explicit_root {
        if let Some(p) = get("TILLANDSIAS_MSG_PROTO") {
            s.proto = p;
        }
        #[cfg(debug_assertions)]
        {
            s.lookup_after_read = get("TILLANDSIAS_MSG_LOOKUP_AFTER_READ").as_deref() == Some("1");
        }
    }
    s
}

fn timeout_ms() -> Duration {
    Duration::from_millis(
        env_var("TILLANDSIAS_MSG_ACCEPT_TIMEOUT_MS")
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(30_000)
            .clamp(100, 600_000),
    )
}

/// Run one identity verb. Returns the exit code: 0 ok/skip, 1 refused, 2 usage.
pub fn run(verb: IdentityVerb, peers_flag: Option<&str>, debug: bool) -> i32 {
    let dir = match peers_dir(peers_flag) {
        Ok(d) => d,
        Err(why) => {
            eprintln!("{why}");
            eprintln!("  why: the peer directory is the trust root and none was named");
            eprintln!(
                "  remedy: run from a checkout (./plan/fleet exists), or pass --peers <dir> / TILLANDSIAS_MSG_PEERS_DIR"
            );
            return 1;
        }
    };
    let keys = match open_key_store(debug) {
        Ok(k) => k,
        Err(why) => {
            eprintln!("{why}");
            return 1;
        }
    };
    if let IdentityVerb::Mint { rotate } = verb {
        let host = store::local_host_label();
        return match mint(keys.as_ref(), &dir, &host, rotate, Utc::now()) {
            Ok((outcome, path)) => {
                match outcome {
                    MintOutcome::Minted { fp } => println!("ok:msg:minted:{host}:{fp}"),
                    MintOutcome::Rotated { old_fp, new_fp } => {
                        println!("ok:msg:rotated:{host}:{old_fp}->{new_fp}")
                    }
                    MintOutcome::Exists { fp, .. } => {
                        println!("skip:msg:key-exists:{host}:{fp}");
                        eprintln!(
                            "  why: this host already holds a static key; minting again would orphan every peer's pin"
                        );
                        eprintln!(
                            "  remedy: pass --rotate to replace it, then land the rewritten peer file"
                        );
                    }
                }
                println!("store:{}", keys.describe());
                if let Some(p) = path {
                    println!("ok:msg:peer-file:{}", p.display());
                }
                0
            }
            Err(why) => {
                println!("refused:msg:mint:{why}");
                1
            }
        };
    }
    // Load the key BEFORE entering the runtime: the Vault store blocks on its
    // own runtime and must not be nested inside this one.
    let local = match keys.read() {
        Ok(Some(s)) => s.keypair,
        Ok(None) => {
            println!("refused:msg:no-static-key");
            eprintln!("  remedy: tillandsias --msg-serve --mint, then land the peer file");
            return 1;
        }
        Err(why) => {
            println!("refused:msg:key-store:{why}");
            return 1;
        }
    };
    let peers = match PeerDirectory::load(&dir) {
        Ok(p) => p,
        Err(why) => {
            println!("{why}");
            return 1;
        }
    };
    for r in &peers.refusals {
        eprintln!("{r}");
    }
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            println!("refused:msg:runtime:{e}");
            return 1;
        }
    };
    let seams = seams();
    let limit = timeout_ms();
    rt.block_on(async move {
        match verb {
            IdentityVerb::AcceptOnce(addr) => {
                let listener = match tokio::net::TcpListener::bind(&addr).await {
                    Ok(l) => l,
                    Err(e) => {
                        println!("refused:msg:bind:{addr}:{}", e.kind());
                        return 1;
                    }
                };
                match listener.local_addr() {
                    Ok(a) => println!("listening:{a}"),
                    Err(_) => println!("listening:{addr}"),
                }
                use std::io::Write as _;
                let _ = std::io::stdout().flush();
                let (sock, _) = match tokio::time::timeout(limit, listener.accept()).await {
                    Ok(Ok(s)) => s,
                    Ok(Err(e)) => {
                        println!("refused:msg:accept:{}", e.kind());
                        return 1;
                    }
                    Err(_) => {
                        println!("refused:msg:accept-timeout");
                        return 1;
                    }
                };
                let report =
                    match tokio::time::timeout(limit, accept_session(sock, &local, &peers, &seams))
                        .await
                    {
                        Ok(r) => r,
                        Err(_) => {
                            println!("refused:msg:session-timeout");
                            return 1;
                        }
                    };
                for l in report.lines() {
                    println!("{l}");
                }
                i32::from(report.verdict.is_err())
            }
            IdentityVerb::DialOnce(addr) => {
                let sock = match tokio::time::timeout(limit, tokio::net::TcpStream::connect(&addr))
                    .await
                {
                    Ok(Ok(s)) => s,
                    Ok(Err(e)) => {
                        println!("refused:msg:connect:{addr}:{}", e.kind());
                        return 1;
                    }
                    Err(_) => {
                        println!("refused:msg:connect-timeout:{addr}");
                        return 1;
                    }
                };
                let probe = format!(
                    "{{\"probe\":\"1506-32k5\",\"from\":\"{}\"}}",
                    store::local_host_label()
                );
                match tokio::time::timeout(
                    limit,
                    dial_session(sock, &local, &peers, &seams, probe.as_bytes()),
                )
                .await
                {
                    Ok(Ok(line)) => {
                        println!("{line}");
                        0
                    }
                    Ok(Err(why)) => {
                        println!("{why}");
                        1
                    }
                    Err(_) => {
                        println!("refused:msg:session-timeout");
                        1
                    }
                }
            }
            IdentityVerb::Mint { .. } => unreachable!("mint returned above"),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[derive(Default)]
    struct MemStore(RefCell<Option<serde_json::Value>>);

    impl MsgStaticKeyStore for MemStore {
        fn describe(&self) -> String {
            "mem".into()
        }
        fn read(&self) -> Result<Option<StoredStatic>, String> {
            self.0
                .borrow()
                .as_ref()
                .map(parse_static_record)
                .transpose()
        }
        fn write(&self, s: &StoredStatic) -> Result<(), String> {
            *self.0.borrow_mut() = Some(static_record(s));
            Ok(())
        }
    }

    fn now() -> DateTime<Utc> {
        store::parse_ts("2026-10-03T12:00:00Z").unwrap()
    }

    fn minted(dir: &Path, host: &str) -> StoredStatic {
        let keys = MemStore::default();
        mint(&keys, dir, host, false, now()).unwrap();
        keys.read().unwrap().unwrap()
    }

    #[test]
    fn mint_twice_skips_and_rotate_rewrites_keeping_foreign_fields() {
        let t = tempfile::tempdir().unwrap();
        let keys = MemStore::default();
        let (o, p) = mint(&keys, t.path(), "alpha", false, now()).unwrap();
        let fp = match o {
            MintOutcome::Minted { fp } => fp,
            other => panic!("first mint: {other:?}"),
        };
        let path = p.unwrap();
        // 1548-cii8 extends the same record: a foreign field must survive.
        let mut body = std::fs::read_to_string(&path).unwrap();
        body.push_str("announce_pub: ed25519-placeholder\n");
        std::fs::write(&path, &body).unwrap();

        let (o, p) = mint(&keys, t.path(), "alpha", false, now()).unwrap();
        assert_eq!(
            o,
            MintOutcome::Exists {
                fp: fp.clone(),
                peer_file_written: false
            }
        );
        assert!(p.is_none());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), body);

        let (o, _) = mint(&keys, t.path(), "alpha", true, now()).unwrap();
        let new_fp = match o {
            MintOutcome::Rotated { old_fp, new_fp } => {
                assert_eq!(old_fp, fp);
                new_fp
            }
            other => panic!("rotate: {other:?}"),
        };
        assert_ne!(new_fp, fp);
        let after = std::fs::read_to_string(&path).unwrap();
        assert!(after.contains(&format!("noise_fp: {new_fp}")), "{after}");
        assert!(
            after.contains("announce_pub: ed25519-placeholder"),
            "{after}"
        );
        let dir = PeerDirectory::load(t.path()).unwrap();
        assert_eq!(dir.peers.len(), 1);
        assert_eq!(dir.peers[0].noise_fp, new_fp);
    }

    #[test]
    fn a_lost_peer_file_is_republished_from_the_stored_key_not_rekeyed() {
        let t = tempfile::tempdir().unwrap();
        let keys = MemStore::default();
        mint(&keys, t.path(), "alpha", false, now()).unwrap();
        let fp = keys.read().unwrap().unwrap().fingerprint();
        std::fs::remove_file(peer_file(t.path(), "alpha")).unwrap();
        let (o, p) = mint(&keys, t.path(), "alpha", false, now()).unwrap();
        assert_eq!(
            o,
            MintOutcome::Exists {
                fp: fp.clone(),
                peer_file_written: true
            }
        );
        assert!(p.unwrap().exists());
        assert_eq!(PeerDirectory::load(t.path()).unwrap().peers[0].noise_fp, fp);
    }

    #[test]
    fn a_record_whose_fp_does_not_hash_its_key_is_not_trusted() {
        let t = tempfile::tempdir().unwrap();
        let s = minted(t.path(), "gamma");
        let path = peer_file(t.path(), "gamma");
        let body = std::fs::read_to_string(&path).unwrap();
        let fp = s.fingerprint();
        let bad = format!("{}0", &fp[..31]);
        let bad = if bad == fp {
            format!("{}1", &fp[..31])
        } else {
            bad
        };
        std::fs::write(&path, body.replace(&fp, &bad)).unwrap();
        let dir = PeerDirectory::load(t.path()).unwrap();
        assert!(dir.peers.is_empty());
        assert_eq!(
            dir.refusals,
            vec!["refused:msg:peer-record:gamma:fp-mismatch".to_string()]
        );
        assert_eq!(
            dir.admit(s.keypair.public()),
            Err(format!("refused:msg:unknown-peer:{fp}"))
        );
    }

    #[test]
    fn a_record_filed_under_another_host_name_is_not_trusted() {
        let t = tempfile::tempdir().unwrap();
        minted(t.path(), "gamma");
        std::fs::rename(peer_file(t.path(), "gamma"), peer_file(t.path(), "alpha")).unwrap();
        let dir = PeerDirectory::load(t.path()).unwrap();
        assert!(dir.peers.is_empty());
        assert_eq!(
            dir.refusals,
            vec!["refused:msg:peer-record:alpha:host-is-not-file-name:gamma".to_string()]
        );
    }

    #[test]
    fn the_file_seam_needs_an_explicit_root() {
        assert_eq!(
            key_store_choice(true, Some("/k"), true),
            KeyStoreChoice::File("/k".into())
        );
        assert_eq!(
            key_store_choice(false, Some("/k"), true),
            KeyStoreChoice::Vault
        );
        assert_eq!(
            key_store_choice(false, Some("/k"), false),
            KeyStoreChoice::Unavailable
        );
        assert_eq!(key_store_choice(true, None, true), KeyStoreChoice::Vault);
    }

    #[test]
    fn a_static_record_whose_public_half_disagrees_is_refused() {
        let s = StoredStatic {
            keypair: StaticKeypair::generate().unwrap(),
            minted: "x".into(),
        };
        let mut v = static_record(&s);
        assert!(parse_static_record(&v).is_ok());
        v["noise_pub"] = serde_json::Value::from(hex(&[7u8; 32]));
        assert_eq!(
            parse_static_record(&v).err().as_deref(),
            Some("key-record-inconsistent:noise_pub")
        );
    }

    struct Pair {
        _t: tempfile::TempDir,
        a: StoredStatic,
        b: StoredStatic,
        dir: PeerDirectory,
    }

    fn pair() -> Pair {
        let t = tempfile::tempdir().unwrap();
        let a = minted(t.path(), "alpha");
        let b = minted(t.path(), "beta");
        let dir = PeerDirectory::load(t.path()).unwrap();
        assert_eq!(dir.peers.len(), 2);
        Pair { _t: t, a, b, dir }
    }

    #[tokio::test]
    async fn known_peers_complete_and_exchange_the_proto_frame() {
        let p = pair();
        let (c, s) = tokio::io::duplex(64 * 1024);
        let seams = SessionSeams::default();
        let (dial, acc) = tokio::join!(
            dial_session(c, &p.a.keypair, &p.dir, &seams, b"envelope"),
            accept_session(s, &p.b.keypair, &p.dir, &seams)
        );
        assert_eq!(
            dial.unwrap(),
            format!("ok:msg:dial:peer=beta:fp={}:proto=1.0", p.b.fingerprint())
        );
        let peer = acc.verdict.clone().unwrap();
        assert_eq!(peer.host, "alpha");
        assert_eq!(acc.proto.as_deref(), Some("1.0"));
        assert!(acc.envelope_bytes_read > 0);
    }

    /// THE ORDERING PROPERTY: an unknown key is refused and the acceptor has
    /// read zero tunnel bytes. The same arm under the LOOKUP_AFTER_READ
    /// mutation must read bytes (and still refuse) — proving the count can
    /// see a late lookup. Seams come from the env-reading path, so a release
    /// test build (`cargo test --release`) runs the same arm and must read
    /// ZERO bytes with the variable set: there it has no effect.
    #[tokio::test]
    async fn an_unknown_key_is_refused_before_any_envelope_byte_is_read() {
        let p = pair();
        let stranger = StaticKeypair::generate().unwrap();
        let fp = static_fingerprint(stranger.public());
        for asked in [false, true] {
            let (c, s) = tokio::io::duplex(64 * 1024);
            let seams = seams_from(fake_env(&[
                ("TILLANDSIAS_MSG_ROOT", "/fixture-root"),
                (
                    "TILLANDSIAS_MSG_LOOKUP_AFTER_READ",
                    if asked { "1" } else { "0" },
                ),
            ]));
            let late = asked && LOOKUP_AFTER_READ_COMPILED;
            let (_dial, acc) = tokio::join!(
                dial_session(c, &stranger, &p.dir, &seams, b"envelope"),
                accept_session(s, &p.b.keypair, &p.dir, &seams)
            );
            assert_eq!(acc.verdict, Err(format!("refused:msg:unknown-peer:{fp}")));
            if late {
                assert!(
                    acc.envelope_bytes_read > 0,
                    "the mutation control did not reach: {acc:?}"
                );
            } else {
                assert_eq!(acc.envelope_bytes_read, 0, "{acc:?}");
            }
        }
    }

    fn fake_env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let pairs: Vec<(String, String)> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        move |k: &str| pairs.iter().find(|(pk, _)| pk == k).map(|(_, v)| v.clone())
    }

    /// 1506-32k5 review: the authentication off-switch exists ONLY in debug
    /// builds. Under the release profile (what build.sh ships) the variable
    /// is not read and the session runs the in-handshake lookup even with an
    /// explicit store root — a legitimate production setting — set. Under the
    /// debug profile (what the fixture drives) it is honoured, but only with
    /// that explicit root. Run both: `cargo test` and `cargo test --release`.
    #[test]
    fn lookup_after_read_is_compiled_out_of_release() {
        let set = fake_env(&[
            ("TILLANDSIAS_MSG_ROOT", "/var/lib/real-store"),
            ("TILLANDSIAS_MSG_LOOKUP_AFTER_READ", "1"),
        ]);
        assert_eq!(seams_from(&set).late_lookup(), cfg!(debug_assertions));
        assert_eq!(LOOKUP_AFTER_READ_COMPILED, cfg!(debug_assertions));
        let no_root = fake_env(&[("TILLANDSIAS_MSG_LOOKUP_AFTER_READ", "1")]);
        assert!(!seams_from(&no_root).late_lookup());
        // PROTO and KEY_FILE stay available in release (they cannot admit a
        // peer); PROTO is honoured with an explicit root in both profiles.
        let proto = fake_env(&[
            ("TILLANDSIAS_MSG_ROOT", "/r"),
            ("TILLANDSIAS_MSG_PROTO", "2.0"),
        ]);
        assert_eq!(seams_from(&proto).proto, "2.0");
    }

    #[tokio::test]
    async fn an_unknown_proto_major_is_refused_naming_it() {
        let p = pair();
        let (c, s) = tokio::io::duplex(64 * 1024);
        let seams = SessionSeams {
            proto: "2.0".into(),
            ..SessionSeams::default()
        };
        let honest = SessionSeams::default();
        let (dial, acc) = tokio::join!(
            dial_session(c, &p.a.keypair, &p.dir, &seams, b"envelope"),
            accept_session(s, &p.b.keypair, &p.dir, &honest)
        );
        assert_eq!(acc.verdict, Err("refused:msg:proto-major:2".into()));
        assert_eq!(
            dial.unwrap_err(),
            "refused:msg:peer-said:refused:msg:proto-major:2"
        );
    }

    #[test]
    fn hello_major_parses_and_refuses_malformed() {
        assert_eq!(hello_major(br#"{"proto":"1.0"}"#), Ok(1));
        assert_eq!(hello_major(br#"{"proto":"2.7"}"#), Ok(2));
        assert!(hello_major(br#"{"proto":"x"}"#).is_err());
        assert!(hello_major(b"not json").is_err());
    }
}
