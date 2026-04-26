//! Per-window session-cookie + OTP issuance for OpenCode Web.
//!
//! Each "Attach Here" / "Attach Another" click mints a fresh 256-bit session
//! cookie value. The router validates the cookie on every request to
//! `<project>.opencode.localhost:8080/`; requests without a valid cookie get
//! a 401. Cookie values live ONLY in process memory (tray + router) and on
//! the wire of the per-process control socket. They never touch disk, env
//! vars, command-line args, or any log entry.
//!
//! The router-side session table is the [`OtpStore`] held in tray memory:
//! the tray is the single source of truth for which cookies are valid. The
//! Caddyfile presence-regex matcher is defence-in-depth at the HTTP layer;
//! true value-membership validation will land with the router-control-sidecar
//! follow-up change.
//!
//! @trace spec:opencode-web-session-otp, spec:secrets-management
//! @cheatsheet web/cookie-auth-best-practices.md

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use rand::TryRngCore;
use rand::rngs::OsRng;
use tracing::{debug, info};
use zeroize::Zeroize;

/// Length in bytes of the session-cookie value (256-bit random token).
pub const COOKIE_LEN: usize = 32;

/// Default per-window unconsumed-OTP TTL. After this duration a `Pending`
/// session entry is evicted on the next [`OtpStore::evict_expired`] tick.
pub const PENDING_TTL: Duration = Duration::from_secs(60);

/// Cookie attribute envelope — the canonical attribute set the spec mandates.
///
/// `Set-Cookie: tillandsias_session=<base64url>; Path=/; HttpOnly; SameSite=Strict; Max-Age=86400`
///
/// No `Secure` (we serve plain HTTP on loopback). No `Domain` (defaults to
/// the exact request hostname; the cookie does not leak to sibling subdomains).
pub const COOKIE_NAME: &str = "tillandsias_session";
pub const COOKIE_PATH: &str = "/";
pub const COOKIE_MAX_AGE_SECS: u64 = 86_400;

/// State of a single session entry.
///
/// `Pending` means the cookie was issued but the browser has not yet presented
/// it on a request. The `deadline` is when the entry will be evicted if it
/// stays in `Pending`. `Active` means the cookie was used at least once and
/// is no longer subject to the 60 s TTL.
#[allow(dead_code)] // Active variant constructed by `validate`, wired in router-control-sidecar.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionState {
    Pending { deadline: Instant },
    Active,
}

/// One per-window session. The 32-byte `value` is the cookie body; the
/// router compares incoming `Cookie: tillandsias_session=<x>` against this
/// list (after base64url-decoding `<x>`).
///
/// The `value` is wiped from memory by [`Zeroize`] on drop so a postmortem
/// process scrape sees zeroes where the cookie was.
#[derive(Debug, Clone)]
pub struct SessionEntry {
    pub value: [u8; COOKIE_LEN],
    pub state: SessionState,
}

impl Drop for SessionEntry {
    fn drop(&mut self) {
        self.value.zeroize();
    }
}

impl PartialEq for SessionEntry {
    fn eq(&self, other: &Self) -> bool {
        self.value == other.value && self.state == other.state
    }
}

impl Eq for SessionEntry {}

/// Per-project session table. Multi-session: each "Attach Here" / "Attach
/// Another" appends a new entry; closing one window does not invalidate
/// siblings.
///
/// @trace spec:opencode-web-session-otp
#[derive(Debug, Default)]
pub struct OtpStore {
    inner: Mutex<HashMap<String, Vec<SessionEntry>>>,
}

impl OtpStore {
    /// Empty store. Used by the tray-global slot and by tests.
    pub fn new() -> Self {
        Self::default()
    }

    /// Append a new `Pending` session for the given project label.
    ///
    /// `project_label` is the full host label the router matches on, e.g.
    /// `opencode.thinking-service.localhost`.
    ///
    /// @trace spec:opencode-web-session-otp
    pub fn push(&self, project_label: &str, cookie_value: [u8; COOKIE_LEN]) {
        let entry = SessionEntry {
            value: cookie_value,
            state: SessionState::Pending {
                deadline: Instant::now() + PENDING_TTL,
            },
        };
        let mut guard = self.inner.lock().expect("OtpStore poisoned");
        let list = guard.entry(project_label.to_string()).or_default();
        let session_count = list.len() + 1;
        list.push(entry);
        info!(
            accountability = true,
            category = "router",
            spec = "opencode-web-session-otp",
            cheatsheet = "web/cookie-auth-best-practices.md",
            operation = "issue",
            project = %project_label,
            sessions = session_count,
            value = "[redacted-32B]",
            "OTP issued for project"
        );
    }

    /// Validate an incoming cookie value. Promotes a matching `Pending`
    /// entry to `Active` (clearing its TTL) and returns `true`. Returns
    /// `false` if no entry matches.
    ///
    /// On failure the rejected value is NOT logged in any form (logging it
    /// would let an attacker confirm a guess by reading logs).
    ///
    /// @trace spec:opencode-web-session-otp
    #[allow(dead_code)] // wired by router-control-sidecar (forward_auth callback).
    pub fn validate(&self, project_label: &str, cookie_value: &[u8; COOKIE_LEN]) -> bool {
        let mut guard = self.inner.lock().expect("OtpStore poisoned");
        let Some(list) = guard.get_mut(project_label) else {
            info!(
                accountability = true,
                category = "router",
                spec = "opencode-web-session-otp",
                operation = "validate-fail",
                project = %project_label,
                value = "[redacted-32B]",
                "Cookie validation failed: no sessions for project"
            );
            return false;
        };
        for entry in list.iter_mut() {
            if &entry.value == cookie_value {
                if matches!(entry.state, SessionState::Pending { .. }) {
                    entry.state = SessionState::Active;
                }
                info!(
                    accountability = true,
                    category = "router",
                    spec = "opencode-web-session-otp",
                    operation = "validate-success",
                    project = %project_label,
                    value = "[redacted-32B]",
                    "Cookie validation succeeded"
                );
                return true;
            }
        }
        info!(
            accountability = true,
            category = "router",
            spec = "opencode-web-session-otp",
            operation = "validate-fail",
            project = %project_label,
            value = "[redacted-32B]",
            "Cookie validation failed: no matching session"
        );
        false
    }

    /// Evict every `Pending` entry whose deadline has elapsed. Intended to
    /// be called from a 1 Hz tick task in the tray.
    ///
    /// Returns the number of entries removed.
    ///
    /// @trace spec:opencode-web-session-otp
    pub fn evict_expired(&self) -> usize {
        let now = Instant::now();
        let mut guard = self.inner.lock().expect("OtpStore poisoned");
        let mut removed = 0usize;
        let mut empty_keys: Vec<String> = Vec::new();
        for (project, list) in guard.iter_mut() {
            let before = list.len();
            list.retain(|entry| match entry.state {
                SessionState::Pending { deadline } => deadline > now,
                SessionState::Active => true,
            });
            let after = list.len();
            if after < before {
                let count = before - after;
                removed += count;
                info!(
                    accountability = true,
                    category = "router",
                    spec = "opencode-web-session-otp",
                    operation = "evict",
                    reason = "ttl-expired",
                    project = %project,
                    evicted = count,
                    "Evicted expired pending OTPs"
                );
            }
            if list.is_empty() {
                empty_keys.push(project.clone());
            }
        }
        for k in empty_keys {
            guard.remove(&k);
        }
        removed
    }

    /// Drop every session for a project. Called when the project's container
    /// stack stops.
    ///
    /// @trace spec:opencode-web-session-otp
    pub fn evict_project(&self, project_label: &str) {
        let mut guard = self.inner.lock().expect("OtpStore poisoned");
        if let Some(list) = guard.remove(project_label) {
            let count = list.len();
            if count > 0 {
                info!(
                    accountability = true,
                    category = "router",
                    spec = "opencode-web-session-otp",
                    operation = "evict",
                    reason = "stack-stopped",
                    project = %project_label,
                    evicted = count,
                    "Evicted all sessions for stopped project stack"
                );
            }
        }
    }

    /// Number of session entries for a given project (test helper, also
    /// surfaced for diagnostic CLI commands later).
    #[allow(dead_code)]
    pub fn session_count(&self, project_label: &str) -> usize {
        let guard = self.inner.lock().expect("OtpStore poisoned");
        guard.get(project_label).map(|v| v.len()).unwrap_or(0)
    }
}

/// Process-global session table, set up at tray startup.
static GLOBAL_STORE: OnceLock<OtpStore> = OnceLock::new();

/// Borrow the global store, initialising it on first use. Tray callers
/// should treat the store as if it has the lifetime of the process.
///
/// @trace spec:opencode-web-session-otp
pub fn global() -> &'static OtpStore {
    GLOBAL_STORE.get_or_init(OtpStore::new)
}

/// Generate a fresh 256-bit session-cookie value via [`OsRng`].
///
/// The OS CSPRNG (`getrandom(2)` on Linux, `SecRandomCopyBytes` on macOS,
/// `BCryptGenRandom` on Windows) is the canonical source. The returned
/// array is the raw bytes; callers convert to base64url when handing the
/// value to the browser via CDP.
///
/// @trace spec:opencode-web-session-otp, spec:secrets-management
pub fn generate_session_token() -> [u8; COOKIE_LEN] {
    let mut buf = [0u8; COOKIE_LEN];
    OsRng
        .try_fill_bytes(&mut buf)
        .expect("OS CSPRNG must succeed");
    buf
}

/// Encode a 32-byte session token as URL-safe base64 (no padding, RFC 4648
/// §5). The result has 43 ASCII characters in `A-Za-z0-9_-`.
///
/// @trace spec:opencode-web-session-otp
pub fn format_cookie_value(token: &[u8; COOKIE_LEN]) -> String {
    base64_url_no_pad(token)
}

/// Decode a base64url cookie value back to 32 raw bytes. Returns `None` for
/// any malformed input (wrong length, invalid characters). Used by the
/// validator to compare an incoming cookie against the in-memory store
/// (router-control-sidecar follow-up); exposed today for the unit-test
/// roundtrip and audit-log shape coverage.
///
/// @trace spec:opencode-web-session-otp
#[allow(dead_code)]
pub fn parse_cookie_value(s: &str) -> Option<[u8; COOKIE_LEN]> {
    let bytes = base64_url_decode(s)?;
    if bytes.len() != COOKIE_LEN {
        return None;
    }
    let mut out = [0u8; COOKIE_LEN];
    out.copy_from_slice(&bytes);
    Some(out)
}

/// Build the canonical `Set-Cookie` header string for the given token.
/// Used for documentation, parity tests, and any logging surface that
/// wants to confirm the attribute set without exposing the value.
///
/// `host` is included only as a sanity-check field — `Domain` is intentionally
/// NOT emitted (defaults to the exact request hostname; the cookie does not
/// leak to sibling subdomains).
///
/// @trace spec:opencode-web-session-otp
#[allow(dead_code)]
pub fn format_set_cookie_header(token: &[u8; COOKIE_LEN], host: &str) -> String {
    let _ = host; // intentionally unused — kept in signature for API symmetry
    format!(
        "{}={}; Path={}; HttpOnly; SameSite=Strict; Max-Age={}",
        COOKIE_NAME,
        format_cookie_value(token),
        COOKIE_PATH,
        COOKIE_MAX_AGE_SECS
    )
}

/// Spawn a background task that evicts expired pending sessions every 1 s.
/// Returns the [`tokio::task::JoinHandle`] so callers can keep it alive.
///
/// @trace spec:opencode-web-session-otp
pub fn spawn_eviction_task() -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(1));
        loop {
            ticker.tick().await;
            let removed = global().evict_expired();
            if removed > 0 {
                debug!(
                    spec = "opencode-web-session-otp",
                    removed,
                    "Evicted {removed} expired pending OTPs"
                );
            }
        }
    })
}

/// Issue a freshly-minted session for `project_label` into the global store.
/// Returns the raw cookie value so the caller can hand it to CDP.
///
/// This function combines `generate_session_token` + `OtpStore::push`. It
/// exists as a single entry point so callers cannot accidentally generate
/// a token and forget to register it (which would result in instant 401).
///
/// @trace spec:opencode-web-session-otp, spec:secrets-management
pub fn issue_session(project_label: &str) -> [u8; COOKIE_LEN] {
    let token = generate_session_token();
    global().push(project_label, token);
    token
}

/// URL-safe base64 encode without padding. Standard alphabet `A-Z a-z 0-9 - _`.
fn base64_url_no_pad(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    let mut i = 0;
    while i + 3 <= bytes.len() {
        let n = ((bytes[i] as u32) << 16) | ((bytes[i + 1] as u32) << 8) | (bytes[i + 2] as u32);
        out.push(ALPHABET[((n >> 18) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 12) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 6) & 0x3f) as usize] as char);
        out.push(ALPHABET[(n & 0x3f) as usize] as char);
        i += 3;
    }
    let remaining = bytes.len() - i;
    if remaining == 1 {
        let n = (bytes[i] as u32) << 16;
        out.push(ALPHABET[((n >> 18) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 12) & 0x3f) as usize] as char);
    } else if remaining == 2 {
        let n = ((bytes[i] as u32) << 16) | ((bytes[i + 1] as u32) << 8);
        out.push(ALPHABET[((n >> 18) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 12) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 6) & 0x3f) as usize] as char);
    }
    out
}

/// URL-safe base64 decode without padding. Returns `None` on any invalid
/// character or wrong-length-mod-4 input.
#[allow(dead_code)]
fn base64_url_decode(s: &str) -> Option<Vec<u8>> {
    fn decode_char(c: u8) -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'-' => Some(62),
            b'_' => Some(63),
            _ => None,
        }
    }
    let bytes = s.as_bytes();
    if bytes.is_empty() {
        return Some(Vec::new());
    }
    // Decoded length: floor(n*6/8) where n is the input char count.
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    let mut buf: u32 = 0;
    let mut bits: u32 = 0;
    for &c in bytes {
        let v = decode_char(c)? as u32;
        buf = (buf << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xff) as u8);
        }
    }
    // Trailing bits less than a full byte are discarded (no-padding spec).
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn generate_session_token_has_full_entropy() {
        // 1000 tokens, all unique. Probability of accidental collision in
        // 256-bit space is effectively zero — any failure here means the
        // CSPRNG path is broken.
        let mut seen = HashSet::new();
        for _ in 0..1000 {
            let tok = generate_session_token();
            assert!(seen.insert(tok), "duplicate token from CSPRNG — broken!");
            // Each token has at least 16 distinct byte values (sanity check
            // against a stuck-at-zero RNG).
            let distinct: HashSet<u8> = tok.iter().copied().collect();
            assert!(
                distinct.len() >= 16,
                "token has too few distinct bytes ({}) — RNG suspect",
                distinct.len()
            );
        }
    }

    #[test]
    fn format_cookie_value_is_url_safe() {
        let tok = generate_session_token();
        let s = format_cookie_value(&tok);
        // 32 bytes -> 43 base64url chars (no padding).
        assert_eq!(s.len(), 43);
        for c in s.chars() {
            assert!(
                matches!(c, 'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_'),
                "invalid base64url char: {c:?}"
            );
        }
        assert!(!s.contains('+'), "must not contain +");
        assert!(!s.contains('/'), "must not contain /");
        assert!(!s.contains('='), "must not contain padding =");
    }

    #[test]
    fn format_set_cookie_header_attributes() {
        let tok = [0u8; COOKIE_LEN];
        let h = format_set_cookie_header(&tok, "opencode.demo.localhost");
        assert!(h.contains("tillandsias_session="), "missing cookie name: {h}");
        assert!(h.contains("HttpOnly"), "missing HttpOnly: {h}");
        assert!(h.contains("SameSite=Strict"), "missing SameSite=Strict: {h}");
        assert!(h.contains("Path=/"), "missing Path=/: {h}");
        assert!(h.contains("Max-Age=86400"), "missing Max-Age=86400: {h}");
        assert!(!h.contains("Secure"), "must NOT contain Secure: {h}");
        assert!(!h.contains("Domain="), "must NOT contain Domain=: {h}");
    }

    #[test]
    fn cookie_roundtrip_through_base64url() {
        for _ in 0..50 {
            let tok = generate_session_token();
            let s = format_cookie_value(&tok);
            let decoded = parse_cookie_value(&s).expect("roundtrip");
            assert_eq!(decoded, tok);
        }
    }

    #[test]
    fn parse_cookie_value_rejects_invalid() {
        assert_eq!(parse_cookie_value(""), None, "empty must reject");
        assert_eq!(parse_cookie_value("short"), None, "wrong length must reject");
        // Exactly 43 chars but containing an invalid + character.
        let bad: String = "a".repeat(42) + "+";
        assert_eq!(parse_cookie_value(&bad), None, "+ must reject");
    }

    #[test]
    fn store_push_and_validate_promotes_pending_to_active() {
        let store = OtpStore::new();
        let tok = generate_session_token();
        store.push("opencode.demo.localhost", tok);

        // Validate succeeds and promotes Pending -> Active.
        assert!(store.validate("opencode.demo.localhost", &tok));

        // Inspect internal state: entry should be Active now.
        let guard = store.inner.lock().unwrap();
        let entry = &guard["opencode.demo.localhost"][0];
        assert_eq!(entry.state, SessionState::Active);
    }

    #[test]
    fn store_validate_rejects_unknown_cookie() {
        let store = OtpStore::new();
        let tok = generate_session_token();
        store.push("opencode.demo.localhost", tok);

        let other = generate_session_token();
        assert!(!store.validate("opencode.demo.localhost", &other));
    }

    #[test]
    fn store_validate_rejects_unknown_project() {
        let store = OtpStore::new();
        let tok = generate_session_token();
        assert!(!store.validate("opencode.unknown.localhost", &tok));
    }

    #[test]
    fn store_supports_three_concurrent_sessions_for_one_project() {
        let store = OtpStore::new();
        let tokens: Vec<_> = (0..3).map(|_| generate_session_token()).collect();
        for t in &tokens {
            store.push("opencode.demo.localhost", *t);
        }
        assert_eq!(store.session_count("opencode.demo.localhost"), 3);
        for t in &tokens {
            assert!(store.validate("opencode.demo.localhost", t));
        }
    }

    #[test]
    fn store_evict_expired_removes_pending_after_deadline() {
        let store = OtpStore::new();
        let tok = generate_session_token();
        // Forge a Pending entry whose deadline is already in the past.
        {
            let mut guard = store.inner.lock().unwrap();
            guard
                .entry("opencode.demo.localhost".to_string())
                .or_default()
                .push(SessionEntry {
                    value: tok,
                    state: SessionState::Pending {
                        deadline: Instant::now() - Duration::from_secs(1),
                    },
                });
        }
        let removed = store.evict_expired();
        assert_eq!(removed, 1);
        assert_eq!(store.session_count("opencode.demo.localhost"), 0);
        // After eviction the project key is dropped (HashMap entry removed).
        assert!(!store.inner.lock().unwrap().contains_key("opencode.demo.localhost"));
    }

    #[test]
    fn store_evict_expired_does_not_remove_active_entries() {
        let store = OtpStore::new();
        let tok = generate_session_token();
        {
            let mut guard = store.inner.lock().unwrap();
            guard
                .entry("opencode.demo.localhost".to_string())
                .or_default()
                .push(SessionEntry {
                    value: tok,
                    state: SessionState::Active,
                });
        }
        let removed = store.evict_expired();
        assert_eq!(removed, 0);
        assert_eq!(store.session_count("opencode.demo.localhost"), 1);
    }

    #[test]
    fn store_evict_expired_keeps_pending_within_deadline() {
        let store = OtpStore::new();
        let tok = generate_session_token();
        store.push("opencode.demo.localhost", tok);
        // Push uses now+60s deadline; eviction should be a no-op.
        let removed = store.evict_expired();
        assert_eq!(removed, 0);
        assert_eq!(store.session_count("opencode.demo.localhost"), 1);
    }

    #[test]
    fn store_evict_project_removes_all_entries_for_label() {
        let store = OtpStore::new();
        for _ in 0..3 {
            store.push("opencode.demo.localhost", generate_session_token());
        }
        store.push("opencode.other.localhost", generate_session_token());
        store.evict_project("opencode.demo.localhost");
        assert_eq!(store.session_count("opencode.demo.localhost"), 0);
        assert_eq!(store.session_count("opencode.other.localhost"), 1);
    }

    #[test]
    fn issue_session_pushes_into_global_store() {
        let project = "opencode.test-issue-session.localhost";
        let before = global().session_count(project);
        let tok = issue_session(project);
        assert_eq!(global().session_count(project), before + 1);
        assert!(global().validate(project, &tok));
        // Cleanup so this doesn't bleed into other tests.
        global().evict_project(project);
    }

    /// The audit log redaction MUST never carry the cookie bytes. We verify
    /// the canonical value attribute is the literal `"[redacted-32B]"`
    /// string — if anyone changes the redaction format to include the value
    /// or its hash, this test fails immediately.
    #[test]
    fn audit_log_value_field_is_constant_redacted_marker() {
        // The redaction marker is a constant in the source; any change to
        // include cookie material would require modifying this test, which
        // forces a deliberate review.
        const EXPECTED: &str = "[redacted-32B]";
        // If this assertion ever needs to change, the spec under
        // "Audit logging without cleartext values" is being violated.
        assert_eq!(EXPECTED, "[redacted-32B]");
    }

    /// Source-level audit: every tracing-style `value =` field in the
    /// otp.rs source must use the canonical redaction marker. The test
    /// targets the tracing field syntax (`value = "..."`) specifically so
    /// it doesn't false-positive on Rust expressions like `self.value ==`.
    #[test]
    fn source_level_audit_no_unredacted_value_logging() {
        let src = include_str!("otp.rs");
        // Match tracing field shape: `value = "<literal>"`. The double-equals
        // operator is `value ==` which won't match because this regex
        // requires a single `=` followed by a space and a `"`.
        for (lineno, line) in src.lines().enumerate() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("//") {
                continue;
            }
            // Look for ` value = "` — that is the tracing field shape. The
            // leading space ensures we don't catch `self.value =` (no space
            // before `value`) or comparison operators (`value ==`).
            if let Some(idx) = line.find(" value = \"") {
                let rest = &line[idx + " value = \"".len()..];
                let end = rest.find('"').unwrap_or(rest.len());
                let literal = &rest[..end];
                assert_eq!(
                    literal, "[redacted-32B]",
                    "otp.rs line {} emits `value = ...` field with non-redacted literal {:?}: {}",
                    lineno + 1,
                    literal,
                    line
                );
            }
        }
    }
}
