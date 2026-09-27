//! ORDER 1375-8g5t — hashing and the clock, answered by the binary every host
//! already has.
//!
//! WHY: after jq, the two portability forks in the scripts are the sha256 tool
//! (`sha256sum` on GNU, 143 sites; `shasum -a 256` on macOS, 62) and the
//! millisecond clock (`date +%s%3N`, 30 sites, which BSD date answers at ONE
//! SECOND resolution because it passes `%3N` through — 1279-a7b6). Every
//! script forks on `command -v` inline; these functions answer both on every
//! platform, and the SAME functions back Lua's `hash.*` and `time.*` tables
//! (1375-btuf) so the CLI and Lua can never disagree.

use sha2::{Digest, Sha256};
use std::io::Read;

/// Lowercase hex sha256 of `bytes`.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

/// Lowercase hex sha256 of everything `r` yields, streamed in 64 KiB blocks so
/// a large file is never held in memory.
pub fn sha256_hex_reader<R: Read>(mut r: R) -> std::io::Result<String> {
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = r.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(hex(&h.finalize()))
}

fn hex(d: &[u8]) -> String {
    d.iter().map(|b| format!("{b:02x}")).collect()
}

/// Milliseconds since the Unix epoch, at real millisecond resolution on every
/// platform (unlike BSD `date +%s%3N`).
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// The fragment-filename clock, UTC: `20260926t004655z`.
pub fn now_iso() -> String {
    chrono::Utc::now().format("%Y%m%dt%H%M%Sz").to_string()
}

/// RFC 3339 UTC with a `Z` suffix and whole seconds: `2026-09-26T00:46:55Z`.
pub fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex_reader(&b"abc"[..]).expect("read"),
            sha256_hex(b"abc")
        );
    }

    #[test]
    fn reader_matches_across_block_boundaries() {
        let big = vec![7u8; 200_000];
        assert_eq!(sha256_hex_reader(&big[..]).expect("read"), sha256_hex(&big));
    }

    #[test]
    fn clock_shapes() {
        assert_eq!(now_ms().to_string().len(), 13);
        let iso = now_iso();
        assert_eq!(iso.len(), 16, "{iso}");
        assert!(iso.as_bytes()[8] == b't' && iso.ends_with('z'), "{iso}");
        let r = now_rfc3339();
        assert!(r.ends_with('Z') && r.len() == 20, "{r}");
    }
}
